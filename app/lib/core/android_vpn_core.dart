import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import 'auto_route.dart';
import 'core_monitor.dart';
import 'cn_ip_index.dart';
import 'dns_client.dart';
import 'rulesets.dart';
import 'route_rule_set_host.dart';
import 'singbox_config.dart';
import 'singbox_runner.dart';
import 'tunnel_health.dart';
import 'vpn_core.dart';

/// 安卓端内核：通过 VpnService + libbox 建立隧道。
///
/// 与 Windows 端的差别只有三处，其余全部共用：
///   * 内核形态：进程内的库（libbox）而非子进程；
///   * 流量接管：VpnService 的 TUN 而非系统代理；
///   * 规则集与索引：打包在 APK 里，需要先解包到可写目录再交给内核。
///
/// 观测部分（Clash API 轮询、速率、失败归因、DNS 监测、启动自检）由
/// [CoreMonitor] 提供，与 Windows 端是同一份代码——此前的实现是两端各写一份，
/// 结果一端修好的问题在另一端依旧存在。
class AndroidVpnCore extends VpnCore {
  AndroidVpnCore(
    super.listener, {
    super.probesEnabled,
    this.dnsResolver,
    HealthRecoveryGuard? healthGuard,
    this.recoveryRestart,
    this.assetLoader,
    this.readyTimeout = const Duration(seconds: 25),
  }) : _healthGuard = healthGuard ?? HealthRecoveryGuard();

  /// DNS 解析实现。为 null 时由观测引擎自建真实 UDP 解析器。
  ///
  /// 与 Windows 端保持同一个可注入点：两端观测逻辑共用，注入点也该一样。
  final DnsResolver? dnsResolver;

  /// 隧道不通时触发自愈的限流器。
  ///
  /// 与桌面端用的是**同一个** [HealthRecoveryGuard]：次数上限、冷却时间、
  /// 「恢复只归还次数不解除冷却」这些语义完全一致。两端各写一套策略迟早会
  /// 分叉，而分叉的表现是「同一个故障在一端会自愈、另一端不会」——正是本轮
  /// 要消掉的那类问题。
  final HealthRecoveryGuard _healthGuard;

  /// 自愈重启的执行动作。生产为 null，由 [restartTunnel] 走真实路径
  /// （拆掉 VpnService 再用最后一次的配置与设置重新建立）；测试注入以便在
  /// 不起真实 VpnService 的前提下断言「重启了几次、有没有被断开拦住」。
  @visibleForTesting
  final Future<void> Function()? recoveryRestart;

  /// 资源字节的读取实现。生产为 null，走 [rootBundle.load]；测试注入以便在
  /// 没有真实 APK 资源的情况下验证「更新目录 == 内核读取目录」这条不变量。
  @visibleForTesting
  final Future<ByteData> Function(String asset)? assetLoader;

  /// 等待内核 Clash API 就绪的上限。生产为 25 秒；测试压到 0 以跳过真实网络等待。
  @visibleForTesting
  final Duration readyTimeout;

  /// 仅用于测试：观测「本次连接真正交给内核的规则库目录」。
  ///
  /// 与桌面端同名成员同义：更新入口写到的目录必须与这里记下的目录相同，
  /// 否则界面会报告更新成功而内核一直用旧规则。
  @visibleForTesting
  void Function(String ruleSetDir)? debugRuleSetDirObserver;

  /// 与 MainActivity / XvpnVpnService 约定的通道名。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/vpn');

  /// 规则集在 APK 资源里的位置。
  static const List<String> _ruleSetAssets = <String>[
    'assets/rulesets/geosite-cn.srs',
    'assets/rulesets/geoip-cn.srs',
  ];

  /// 所有需要在连接前落到磁盘上的资源。
  ///
  /// 中国 IP 索引走同一条路径：内核不需要它，但 DNS 交叉校验需要，
  /// 而它同样只在 APK 资源里。
  static const List<String> _stagedAssets = <String>[
    ..._ruleSetAssets,
    CnIpIndex.assetPath,
  ];

  @override
  String get name => 'sing-box（libbox）';

  /// 自动纠正表。跨连接保留。
  final AutoRouteTable _autoRoute = AutoRouteTable();

  /// 热更新规则集的本地服务（与桌面端同一套实现）。
  ///
  /// 安卓端同样需要它：决策与执行的时间差在两个平台上一模一样，而这里是唯一
  /// 能取消这个时间差的机制。惰性初始化是因为它必须引用同一个表实例。
  late final AutoRouteRuleSetHost _ruleSetHost = AutoRouteRuleSetHost(_autoRoute);

  /// 安卓端与桌面端一样能报告握手状态。
  ///
  /// 这条路曾经是不通的：DEBUG 级日志经 `writeDebugMessage` 转发给 Dart 时，
  /// 直接在原生线程里调 MethodChannel，触发 JNI 校验失败并把进程 abort 掉。
  /// 根因已在原生侧修掉（改为 post 到主线程，见 [XvpnVpnService] 的
  /// `writeDebugMessage`），`SetupOptions.debug` 因此可以打开。
  ///
  /// 但光打开平台开关还不够：握手行是 DEBUG 级的，配置文件里的 `log.level`
  /// 必须是 debug（由 [ParsedProfile.wantsDebugLogs] 按协议下发）。两者缺一，
  /// 这里就会显示一个永远读不出来的占位。
  @override
  bool get supportsHandshakeState => true;

  CnIpIndex _cnIpIndex = CnIpIndex.empty;

  /// 本次隧道开始建立的时刻，供观测引擎计算预热宽限期。
  ///
  /// 与桌面端同义：刻意不用「观测引擎启动时刻」，否则门控已经花掉的那几秒
  /// 会被一笔勾销，紧接着一次探测失败就又被判成「隧道不通」。
  DateTime? _tunnelSince;

  /// 用户是否明确要求断开。
  ///
  /// 与桌面端同义：自愈重启必须尊重这个旗标。否则用户点了断开、健康判定恰好
  /// 在这一刻报「隧道不通」，内核会立刻把刚拆掉的隧道重新拉起来——表现为
  /// 「断开之后自己又连上了」。
  bool _userDisconnect = false;

  /// 第几轮连接尝试。理由与桌面端 `_attemptSeq` 相同：只看 `_userDisconnect`
  /// 会被新一轮连接重置，无法区分「本轮已被取消/取代」和「本轮正常继续」。
  int _attemptSeq = 0;

  /// 本次连接使用的配置与设置。自愈重启要用它们重新建立隧道。
  VpnProfile? _lastProfile;
  AppSettings? _lastSettings;

  @override
  CnIpIndex get cnIpIndex => _cnIpIndex;

  @override
  void initAutoRoute(Object? saved) => _autoRoute.loadFrom(saved);

  @override
  List<Map<String, Object?>> exportAutoRoute() => _autoRoute.toJson();

  /// 「检查更新」写入的目录 == 内核读取规则库的目录。
  ///
  /// 安卓内核读的是 [_stageAssets] 解包出来的应用私有目录。更新若按桌面端
  /// 那套路径规则写到别处，按钮会报告成功、界面日期也会变，而内核永远用旧
  /// 规则——用户被明确告知了一件没发生的事。这里把两者绑成同一个目录：更新
  /// 直接写进内核读的位置，随后的 `_stageAssets` 因为文件已存在且有效而跳过
  /// 复制，不会把新内容盖回出厂副本。
  @override
  Future<Directory?> ruleSetUpdateDir() async =>
      Directory(await _stageAssets());

  @override
  CoreMonitorHooks monitorHooks() => CoreMonitorHooks(
    listener: listener,
    clashApiPort: SingBoxConfigBuilder.defaultClashApiPort,
    autoRoute: _autoRoute,
    cnIpIndex: _cnIpIndex,
    probesEnabled: probesEnabled,
    dnsResolver: dnsResolver,
    // 健康结论先回到内核自己：内地隧道不通时唯一能立刻恢复的手段是
    // 拆掉并重建 VpnService。此前这里没有这一项，安卓的判定只被**显示**、
    // 从不被**执行**——桌面能自愈的同一故障，在手机上是彻底断网直到手动重连。
    onHealth: handleTunnelHealth,
    // MTU 校验在安卓端**不做**，这是能力差异而不是遗漏：
    // 校验要把包经本地混合入站送进隧道，而 TUN 模式没有这个端口——内核自己
    // 按 MTU 分片，用户侧没有可校验的入口。界面两端都会显示这一行，只是移动端
    // 说明「由内核自行处理」，而不是显示一个永远「无法校验」的占位。
    declaredMtu: null,
  );

  // ---------------------------------------------------------------- 启动

  @override
  Future<void> connect(
    VpnProfile profile,
    AppSettings settings, {
    ConnectAttempt? attempt,
  }) async {
    // 用户主动连接 = 新的一轮：清掉「已断开」旗标与上一轮的自愈额度，
    // 并记下配置——自愈重启要用同一份配置与设置。
    _userDisconnect = false;
    _healthGuard.reset();
    _lastProfile = profile;
    _lastSettings = settings;
    // 拆旧实例但**不**广播「已断开」：否则每次连接界面都会先闪一下未连接
    // 再回到连接中，看起来像连接被打断了一次。
    await _teardown(notifyStatus: false);
    await _startTunnel(profile, settings, attempt);
  }

  /// 拉起 VpnService 并等内核就绪。手动连接与自愈重启共用这一条路径。
  ///
  /// [attempt] 是用户这一轮的取消令牌，为 null 表示内部自愈重启。
  Future<void> _startTunnel(
    VpnProfile profile,
    AppSettings settings,
    ConnectAttempt? attempt,
  ) async {
    // 本轮的身份：见 [_attemptSeq] 的说明。
    final seq = ++_attemptSeq;

    /// 本轮是否应当收手。必须在每一次 await 之后都查。
    bool aborted() =>
        isDisposed ||
        _userDisconnect ||
        (attempt?.isCancelled ?? false) ||
        seq != _attemptSeq;

    if (aborted()) return;
    listener.onStatusChanged(VpnStatus.connecting);

    try {
      // 1) 申请 VPN 授权。必须在 Activity 里弹系统对话框，因此走通道。
      final granted = await _channel.invokeMethod<bool>('prepareVpn') ?? false;
      if (aborted()) return;
      if (!granted) {
        listener.onError('未获得 VPN 授权。请重新连接并在系统弹窗中选择「允许」');
        await _teardown(notifyStatus: true);
        return;
      }

      // 2) 资源解包。内核要的是真实文件路径，而 APK 里的资源读不到路径。
      final ruleSetDir = await _stageAssets();
      if (aborted()) return;
      // 自定义规则集由「分流规则」页下载到这个目录，不在 APK 资源里，
      // 因此 _stageAssets 不会带上它们。缺文件时明确报错，而不是让内核
      // 带着一个不存在的 path 启动。
      for (final entry in ruleSets) {
        if (!entry.enabled || entry.kind != RuleSetKind.custom) continue;
        final file = File(
          '$ruleSetDir${Platform.pathSeparator}${entry.fileName}',
        );
        if (!file.existsSync()) {
          listener.onError(missingRuleSetMessage(file.path));
          await _teardown(notifyStatus: true);
          return;
        }
      }
      _cnIpIndex = await _loadCnIpIndex(ruleSetDir);
      if (aborted()) return;

      // 热更新投递：先把本地规则集服务起好，再让内核去拉。
      //
      // 顺序不能颠倒：实测（sing-box 1.14.0）**首次**拉取失败会让内核直接起不来，
      // 之后的刷新失败才只是报错继续。拿不到就退回内联规则——两个平台在这一点上
      // 行为一致，因为用的是同一套实现与同一个退回路径。
      final hotRouteSets = settings.splitMode == SplitMode.smart
          ? await _ruleSetHost.start()
          : null;
      if (aborted()) return;

      // 3) 生成配置。分流与 DNS 策略与 Windows 端完全一致，
      //    自动纠正表也一并注入。
      //
      //    把目录记给测试观测点：「检查更新」写到的目录必须与这里交给内核的
      //    目录相同，否则界面报告成功而内核照旧用旧规则。
      debugRuleSetDirObserver?.call(ruleSetDir);
      final config = SingBoxConfigBuilder.build(
        profile: profile.parsed,
        splitMode: settings.splitMode,
        ruleSetDir: ruleSetDir,
        // 安卓只能走 TUN：VpnService 的 fd 必须在应用进程内创建。
        inboundMode: InboundMode.tun,
        logSplits: settings.logSplits,
        autoRoute: _autoRoute,
        ruleSets: enabledRuleSetSpecs,
        hotRouteSets: hotRouteSets,
      );

      // 4) 接收内核日志，供失败归因与自动纠正使用。
      _channel.setMethodCallHandler(_onPlatformCall);

      // 5) 启动服务并等内核就绪。
      await _channel.invokeMethod<void>('connect', <String, Object?>{
        'config': SingBoxConfigBuilder.encode(config),
      });
      // 服务可能已经被这一句拉起。取消时若直接 return，TUN 会一直接管流量而
      // 界面显示未连接——必须把刚起来的服务收掉。只有仍是最新的一轮才收，
      // 否则会把新一轮刚拉起的服务拆掉。
      if (aborted()) {
        if (seq == _attemptSeq) await _teardown(notifyStatus: false);
        return;
      }

      // 取消时立刻收手，不必把就绪超时等满。
      final ready = await monitor.waitForApi(
        readyTimeout,
        isCancelled: aborted,
      );
      if (aborted()) {
        if (seq == _attemptSeq) await _teardown(notifyStatus: false);
        return;
      }
      if (!ready) {
        final status = await _status();
        // 取详细错误期间用户可能点了取消：那是用户的选择，不该再报一句
        // 「启动超时」。这里不写错误，只收掉可能已经起来的服务。
        if (aborted()) {
          if (seq == _attemptSeq) await _teardown(notifyStatus: false);
          return;
        }
        final detail = status['error'] as String?;
        listener.onError(
          detail == null || detail.isEmpty
              ? '内核启动超时，请查看系统日志'
              : '内核启动失败：$detail',
        );
        await _teardown(notifyStatus: true);
        return;
      }

      // 6) 就绪门控：与桌面端同一套逻辑。
      //
      // 安卓这边同样存在「内核报就绪、隧道还不能载流量」的窗口，而它比桌面端
      // 更容易被误解：TUN 已经接管了全部流量，用户看到的是**整个网络都不通**，
      // 而不是某一个网站打不开。若此时界面写着「已连接」，用户会直接认为软件
      // 把网络弄坏了。
      //
      // 门控失败**不阻断连接**：超时后照旧宣布已连接，但明确说一句尚未就绪。
      // 两端连这条提示的措辞都取自同一个常量，避免同一个现象两种说法。
      _tunnelSince = DateTime.now();
      // 与桌面端调用的是**同一个**门控实现：预热态广播、等待、超时提示都在里面。
      // 两端各写一遍的话，迟早会出现「一端改了措辞、另一端还是老话」。
      await runTunnelReadyGate(
        listener: listener,
        probe: monitor.probeTunnelReadiness,
        isAborted: aborted,
      );
      if (aborted()) {
        if (seq == _attemptSeq) await _teardown(notifyStatus: false);
        return;
      }

      listener.onStatusChanged(VpnStatus.connected);
      // 预热起点用隧道建立那一刻，这样门控已经花掉的时间不会被重复计算。
      monitor.start(since: _tunnelSince);
    } on Object catch (e) {
      // 取消/被取代不算启动失败：那是用户的选择，不该弹一句红字。
      if (aborted()) {
        if (seq == _attemptSeq) await _teardown(notifyStatus: false);
        return;
      }
      listener.onError('启动失败：$e');
      // 走 _teardown 而不是 disconnect：后者会立「用户断开」旗标，让紧随其后的
      // 健康自愈被误判成用户主动断开。这个区分与桌面端 `_stopCore` 保持一致。
      await _teardown(notifyStatus: true);
    }
  }

  // ---------------------------------------------------------------- 停止

  @override
  Future<void> disconnect() async {
    // 先立旗标：健康判定与就绪门控都会查它。旗标不到位时，用户刚点下的断开
    // 会被一次恰好到来的「隧道不通」判定重新拉起来——表现为「断开之后自己
    // 又连上了」。
    _userDisconnect = true;
    _healthGuard.reset();
    await _teardown(notifyStatus: true);
  }

  /// 拆掉内核与 TUN。
  ///
  /// [notifyStatus] 为 false 时不广播「已断开」：连接与自愈重启的过程中会先
  /// 拆旧实例，那一刻界面不该闪回未连接。
  Future<void> _teardown({required bool notifyStatus}) async {
    // 就绪门控靠 _userDisconnect / 取消令牌 / 尝试代际号判断「要不要收手」，
    // 这三者都由调用方（disconnect、取消、新一轮 _startTunnel）先立好，
    // 因此这里只负责拆服务本身。
    monitor.stop();
    // 内核即将消失，指向本机服务的规则集也就没有使用者了。与桌面端一致：
    // 断开就把一切都收干净，下一次连接重新起（端口会变，配置也是重新生成的）。
    await _ruleSetHost.stop();
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on Object {
      // 服务可能已经不在，忽略。
    }
    listener.onTraffic(downBps: 0, upBps: 0, totalBytes: 0);
    listener.onLatency(null);
    if (notifyStatus) listener.onStatusChanged(VpnStatus.disconnected);
  }

  // ------------------------------------------------------------ 断线自愈

  /// 隧道健康判定结果。断线自愈的第二条路径：内核还活着，但隧道已经不通。
  ///
  /// 与桌面端 `SingBoxRunner.handleTunnelHealth` **同一套语义**，连被限流拦下
  /// 时的措辞都逐字一致：健康就归还额度、只有 `shouldRecover` 才行动、本地
  /// 网络问题绝不重连、额度用尽或仍在冷却期时必须出声说明为什么没有动作。
  /// 两端各写一套策略迟早会分叉，而分叉的表现是「同一故障一端自愈、另一端
  /// 彻底断网直到手动重连」。
  void handleTunnelHealth(TunnelHealth health) {
    if (!health.isProblem) {
      // 恢复正常：本轮事故结束。只归还次数、不清除冷却时间戳，
      // 否则「断了又通、通了又断」会把额度反复重置成无限重连。
      _healthGuard.noteHealthy();
      return;
    }
    if (!health.shouldRecover) return; // 本地网络问题：重连没有意义
    if (isDisposed || _userDisconnect) return;

    final now = DateTime.now();
    if (!_healthGuard.shouldRestart(now)) {
      listener.onError(
        _healthGuard.exhausted
            ? '${health.summary}；本次连接内的自动恢复次数已用尽，'
                  '请手动重连或更换节点'
            : '${health.summary}；距上次自动恢复不足 '
                  '${_healthGuard.cooldown.inMinutes} 分钟，暂不重复重启',
      );
      return;
    }

    _healthGuard.noteRestart(now);
    listener.onError('${health.summary}（第 ${_healthGuard.restarts} 次自动恢复）');
    unawaited(_restartTunnel());
  }

  /// 因健康问题重启隧道：拆掉 VpnService，再用**最后一次的配置与设置**重建。
  ///
  /// 与桌面端 `_restartCore` 的差别只有「怎么拆怎么建」：桌面是杀子进程再起
  /// 一个，安卓是把 TUN 与服务收掉再走一遍 [connect] 的启动路径。额度与冷却
  /// 语义完全共享——这里刻意不重置 [_healthGuard]，否则自愈会退化成无限重启。
  Future<void> _restartTunnel() async {
    if (isDisposed || _userDisconnect) return;
    // 注入的重启动作优先：测试用它计数，无需真实 VpnService 参与。
    final override = recoveryRestart;
    if (override != null) {
      await override();
      return;
    }
    final profile = _lastProfile;
    final settings = _lastSettings;
    if (profile == null || settings == null) return;
    await _teardown(notifyStatus: false);
    // 内部自愈重启没有用户令牌，取消由 _userDisconnect 表达。
    await _startTunnel(profile, settings, null);
  }

  @override
  Future<bool> resumeIfRunning() async {
    final status = await _status();
    if (status['running'] != true) return false;
    // 内核日志的转发回调在 connect() 里注册；接管路径也要注册，否则失败归因失效。
    _channel.setMethodCallHandler(_onPlatformCall);
    // 接管的是一个仍在跑的隧道：用户并没有要求断开，自愈应当可用。
    _userDisconnect = false;
    _healthGuard.reset();
    listener.onStatusChanged(VpnStatus.connected);
    // 接管后观测从零开始：这之前的连接属于上一个界面进程，不必补记。
    monitor.start();
    return true;
  }

  @override
  void dispose() {
    monitor.stop();
    unawaited(_ruleSetHost.stop());
    super.dispose();
  }

  // ------------------------------------------------------------ 资源解包

  /// 把随包分发的资源写到应用私有目录，返回该目录路径。
  ///
  /// 只在文件缺失或内容不对时重写：解包不到 100 KB 不贵，但没必要每次连接都做。
  ///
  /// 「已存在且大于 64 字节就跳过」这一条是有意保留的：现在「检查更新」直接写
  /// 进这个目录（见 [ruleSetUpdateDir]），因此被跳过的是**用户刚更新过的文件**，
  /// 这正是它不该被出厂副本盖回去的理由。更新后无需任何失效处理——下一次连接
  /// 拿到的就是同一目录里的新内容，内核立刻用上。
  Future<String> _stageAssets() async {
    final base = await _channel.invokeMethod<String>('filesDir');
    if (base == null || base.isEmpty) {
      throw StateError('无法获取应用目录');
    }
    final dir = Directory('$base${Platform.pathSeparator}rulesets');
    dir.createSync(recursive: true);

    for (final asset in _stagedAssets) {
      final name = asset.split('/').last;
      final target = File('${dir.path}${Platform.pathSeparator}$name');
      if (target.existsSync() && target.lengthSync() > 64) continue;
      final ByteData data;
      try {
        data = await (assetLoader?.call(asset) ?? rootBundle.load(asset));
      } on Object {
        // 资源缺失只可能是安装包损坏或被裁剪（应用商店重新打包、增量更新出错）。
        // 原先它会以「启动失败：Unable to load asset: ...」的样子冒到界面上——
        // 用户看到的是一条英文的构建产物路径。这里换成与桌面端同一句可操作的话。
        throw StateError(missingRuleSetMessage(asset));
      }
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return dir.path;
  }

  /// 从刚解包的目录里读中国 IP 索引。缺失时返回空表（判定会变保守）。
  Future<CnIpIndex> _loadCnIpIndex(String dir) async {
    final file = File('$dir${Platform.pathSeparator}cn-ip.bin');
    if (!file.existsSync()) return CnIpIndex.empty;
    try {
      return CnIpIndex.parse(file.readAsBytesSync()) ?? CnIpIndex.empty;
    } on Object {
      return CnIpIndex.empty;
    }
  }

  // ---------------------------------------------------------------- 平台交互

  /// 接收原生推来的内核日志。
  Future<void> _onPlatformCall(MethodCall call) async {
    if (call.method == 'coreLog') {
      final line = call.arguments;
      if (line is String) handleCoreLog(line);
    }
  }

  Future<Map<String, Object?>> _status() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      return raw?.cast<String, Object?>() ?? const <String, Object?>{};
    } on Object {
      return const <String, Object?>{};
    }
  }
}
