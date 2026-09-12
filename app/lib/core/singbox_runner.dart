import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'auto_route.dart';
import 'cn_ip_index.dart';
import 'core_monitor.dart';
import 'dns_client.dart';
import 'port_allocator.dart';
import 'reconnect.dart';
import 'rulesets.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import 'tunnel_health.dart';
import 'vpn_core.dart';

/// 真实内核：以子进程方式运行随包分发的 sing-box。
///
/// 工作流程与「傻瓜式」的对应关系：
///   1. 把 .conf 翻译成 sing-box 配置（[SingBoxConfigBuilder]）；
///   2. 启动内核，内核按内置规则库 + 自动纠正表自行判定国内直连 / 国外走隧道；
///   3. 接管系统代理，让浏览器与绝大多数软件无需任何设置即可生效；
///   4. 从 Clash API 读取真实连接，界面上的「分流记录」由此而来——
///      不是模拟数据，而是内核实际做出的判定。
///
/// 观测部分（Clash API 轮询、速率、失败归因、DNS 监测、启动自检）全部在
/// [CoreMonitor] 里，与安卓端共用同一份实现，统计口径因此完全一致。
/// 内核运行时用到的一组位置。
///
/// 单列一个类型而不是就地返回一条记录：它需要能被注入——测试要用**真实的**
/// 随包内核跑一遍完整的连接与断开，而测试进程旁边没有 `sing-box.exe`
/// （生产路径是从 `Platform.resolvedExecutable` 旁边推导的）。有了这个注入点，
/// 「完整连接路径」才第一次有了自动化验证，而不只是靠读代码确认。
class CoreRuntime {
  const CoreRuntime({
    required this.singBoxExe,
    required this.ruleSetDir,
    required this.assetDir,
    required this.workDir,
  });

  /// 内核可执行文件。
  final File singBoxExe;

  /// 规则集所在目录，会写进生成的配置里。
  final Directory ruleSetDir;

  /// 随包分发的资源目录，用于加载中国 IP 索引。
  final Directory assetDir;

  /// 工作目录：生成的配置与内核 PID 都放这里。
  final Directory workDir;

  /// 需要存在的规则集文件。
  ///
  /// 按 [assetDir]（出厂副本）检查，而配置里引用的是 [ruleSetDir]（可写副本）：
  /// 两者内容一致，但检查出厂副本才查得出「安装包本身缺文件」。
  List<File> get ruleSets => <File>[
    File('${assetDir.path}${Platform.pathSeparator}geosite-cn.srs'),
    File('${assetDir.path}${Platform.pathSeparator}geoip-cn.srs'),
  ];

  /// 内核 PID 文件。正常关闭时内核已确认退出，这个文件只在「被强杀」的场景
  /// 有用：下次启动据此清掉残留实例，否则端口会被一直占着。
  File get pidFile => File('${workDir.path}${Platform.pathSeparator}core.pid');
}

class SingBoxRunner extends VpnCore {
  SingBoxRunner(
    super.listener, {
    super.probesEnabled,
    ReconnectPolicy? reconnectPolicy,
    this.dnsResolver,
    this.runtimeOverride,
    this.readyGateTimeout = tunnelReadyTimeout,
    this.proxy = const SystemProxy(),
  }) : _recovery = CrashRecovery(policy: reconnectPolicy);

  /// 系统代理的接管与还原。生产用真实实现；测试可注入替身。
  ///
  /// 为什么值得一个注入点：接管与还原必须成对，漏掉任何一半的后果都是「用户
  /// 关掉应用之后上不了网」。而这条路径依赖平台通道，此前只能靠读代码确认。
  final SystemProxyController proxy;

  /// 运行时位置的覆盖项。生产环境为 null，由安装位置推导。
  final CoreRuntime? runtimeOverride;

  /// 就绪门控的等待上限。生产用默认值（[tunnelReadyTimeout]，20 秒）。
  ///
  /// 抽成可注入项是为了让「连接 → 断开 → 收干净」这类用例不必真的干等 20 秒：
  /// 指向一个不可达节点时门控**必然**走满超时，于是每个用例都要 21 秒。这种
  /// 用例最后只会被人从测试列表里删掉——而它恰恰守着最要紧的那条路径。
  final Duration readyGateTimeout;

  /// 入站与 Clash API 的默认端口。与 [SingBoxConfigBuilder] 保持一致。
  static const int mixedPort = SingBoxConfigBuilder.defaultMixedPort;
  static const int clashApiPort = SingBoxConfigBuilder.defaultClashApiPort;

  /// 本次连接实际使用的端口。
  ///
  /// 默认值被占用时会往后找一个可用的（见 [PortAllocator]），因此这里不能在
  /// 任何地方假设端口等于默认值——配置生成、系统代理、观测引擎三处必须用
  /// 同一个值，错一处就会表现为「连上了但什么都读不到」。
  int _mixedPort = mixedPort;
  int _clashApiPort = clashApiPort;

  /// 交给观测引擎的依赖。
  ///
  /// 刻意做成**同一个实例**并常驻：Clash API 端口在连接时才确定，而 hooks 在
  /// 构造期就交给观测引擎了，只有复用同一个对象，后面改端口才生效。
  late final CoreMonitorHooks _hooks = CoreMonitorHooks(
    listener: listener,
    clashApiPort: _clashApiPort,
    autoRoute: _autoRoute,
    cnIpIndex: _cnIpIndex,
    probesEnabled: probesEnabled,
    dnsResolver: dnsResolver,
    // MTU 校验要经混合入站把包送进隧道，端口在连接时才确定，因此这里给的是
    // 会被 `_startTunnel` 更新的那个字段（hooks 是可变对象）。
    mixedPort: _mixedPort,
    // 健康结论先回到内核自己：只有它能决定重启进程。
    onHealth: handleTunnelHealth,
  );

  Process? _process;

  /// 桌面端把系统代理指向本机这个地址。
  ///
  /// 必须把**实际**端口报给界面：默认 2080 被占用时会往后换一个（见
  /// [PortAllocator]），界面若照旧写死 2080，显示的就是用户抄不走、也用不上的
  /// 地址。连接之前返回的是准备值，连接后即为生效值。
  @override
  String get takeOverEndpoint => '127.0.0.1:$_mixedPort';

  /// 最近一行内核日志，用于拼错误信息。
  ///
  /// 曾经这里自己维护一个 40 行的滚动尾巴，而界面上完全看不到日志。现在日志
  /// 统一进 [VpnCore.kernelLog]，这里只从缓冲里取最后一行——不再各存一份。
  String? get _lastLogLine => kernelLog.lastLine;

  /// 崩溃自愈状态机：决定内核意外退出后要不要重连、等多久、何时放弃。
  final CrashRecovery _recovery;

  /// DNS 解析实现。为 null 时由观测引擎自建真实 UDP 解析器。
  ///
  /// 可注入是为了让「用户主动查证域名」这条链路能在不发真实 DNS 查询的前提下
  /// 被测到——否则那条链路只能靠肉眼确认。
  final DnsResolver? dnsResolver;

  /// 「隧道不通」触发重启的限流器。
  ///
  /// 与 [_recovery] 是两回事：那个管「内核没了」，这个管「内核还在但隧道不通」。
  final HealthRecoveryGuard _healthGuard = HealthRecoveryGuard();

  /// 最近一次连接使用的配置。自动重连要靠它重新生成配置并拉起内核。
  VpnProfile? _lastProfile;
  AppSettings? _lastSettings;

  /// 本次隧道开始建立的时刻，供观测引擎计算预热宽限期。
  ///
  /// 刻意不用「观测引擎启动时刻」：两者之间隔着起进程、等内核就绪、设系统代理
  /// 与就绪门控，可能已经过去好几秒。用后者会把这段等待清零，于是门控刚确认
  /// 隧道可用，紧接着一次探测失败就又被判成「隧道不通」。
  DateTime? _tunnelSince;

  /// 内核退出是不是用户要求的。
  ///
  /// 这是自动重连最容易出错的地方：用户点了断开、内核被我们 kill 掉，
  /// 如果不加区分，退出回调会把它当成崩溃并立刻重连——表现为「断开之后
  /// 自己又连上了」。
  bool _userDisconnect = false;

  /// 待执行的重连定时器。
  Timer? _reconnectTimer;

  bool _disposed = false;

  /// 本次内核进程已经活了多久。
  ///
  /// 它是 [CrashRecovery] 区分「刚起来就死」（多半是配置问题）与
  /// 「跑了一阵才死」（偶发）的唯一依据。
  final Stopwatch _uptime = Stopwatch();

  /// 自动纠正表。跨连接保留，因此用户不用每次重连都重新学习一遍。
  final AutoRouteTable _autoRoute = AutoRouteTable();

  CnIpIndex _cnIpIndex = CnIpIndex.empty;
  bool _indexLoaded = false;

  bool _proxyTakenOver = false;

  @override
  String get name => 'sing-box 1.14.0';

  @override
  CnIpIndex get cnIpIndex => _cnIpIndex;

  @override
  void initAutoRoute(Object? saved) => _autoRoute.loadFrom(saved);

  @override
  List<Map<String, Object?>> exportAutoRoute() => _autoRoute.toJson();

  @override
  CoreMonitorHooks monitorHooks() => _hooks;

  // ---------------------------------------------------------------- 启动

  @override
  Future<void> connect(VpnProfile profile, AppSettings settings) async {
    // 用户主动连接 = 新的一轮：上一轮的重试与自愈额度全部清零。
    _userDisconnect = false;
    _cancelReconnect();
    _recovery.reset();
    _healthGuard.reset();
    _lastProfile = profile;
    _lastSettings = settings;
    // 先清理旧实例，但不广播「已断开」：否则自动重连时界面会先闪一下
    // 未连接再回到连接中，看起来像连接被打断了一次。
    await _stopCore(notifyStatus: false);
    await _startTunnel(profile, settings);
  }

  /// 启动过程中用户点了断开，或对象已经销毁。
  ///
  /// 必须在**每一次 await 之后**都查一遍。启动路径上有五处等待——读中国 IP
  /// 索引、探端口、起进程、等内核就绪、设系统代理——用户完全可能在其中任何
  /// 一处按下断开。不查的后果不是「晚一点断开」，而是把已经拆掉的内核与系统
  /// 代理重新装回来：界面显示已连接、系统代理指着一个用户以为已经关掉的隧道；
  /// 若在起进程之前断开，还会留下一个没人管的孤儿内核进程。
  bool get _aborted => _disposed || _userDisconnect;

  /// 拉起内核并等待它就绪。手动连接与自动重连共用这一条路径。
  Future<void> _startTunnel(VpnProfile profile, AppSettings settings) async {
    // 在广播「连接中」**之前**先查一次。
    //
    // 这一条是补上一个很窄但很难受的窗口：用户点了断开，而这条启动流程早已
    // 在队列里（例如自愈重启正在进行中，或 connect() 正卡在拆旧内核那一步），
    // 此时若先广播「连接中」再在后面的检查点悄悄 return，界面就会**永远停在
    // 连接中**——状态再也不会被谁改回来。
    if (_aborted) return;
    listener.onStatusChanged(VpnStatus.connecting);
    // 预热宽限期的起点：**从这里**算起，而不是从观测引擎启动时算起。
    // 中间隔着起进程、等内核就绪、设系统代理、就绪门控四步，可能已经花掉
    // 好几秒；以观测启动为起点等于把这段等待一笔勾销。
    _tunnelSince = DateTime.now();

    try {
      final runtime = _resolveRuntimePaths();
      if (!runtime.singBoxExe.existsSync()) {
        listener.onError(missingKernelMessage(runtime.singBoxExe.path));
        listener.onStatusChanged(VpnStatus.disconnected);
        return;
      }
      for (final ruleSet in runtime.ruleSets) {
        if (!ruleSet.existsSync()) {
          listener.onError(missingRuleSetMessage(ruleSet.path));
          listener.onStatusChanged(VpnStatus.disconnected);
          return;
        }
      }

      // 中国 IP 索引只在第一次连接时读一次，之后常驻。
      // 它是 DNS 交叉校验的地理判定依据，缺了只会让判定变保守，不影响连通性。
      if (!_indexLoaded) {
        _cnIpIndex = await CnIpIndex.load(assetsDir: runtime.assetDir);
        _indexLoaded = true;
        if (_aborted) return;
      }

      runtime.workDir.createSync(recursive: true);

      // 0) 先清掉上次被强杀后残留的内核，**再**挑端口。
      //
      // 顺序是实测出来的：界面进程被强杀时，内核不会被一起带走（Windows 上子
      // 进程不随父进程退出），它会继续占着 2080。若先挑端口，分配器就会看到
      // 自己的残留实例占着默认端口、从而换一个，并提示「默认端口被占用」——
      // 而占用者其实是自己上一次留下的。先清理，端口选择才是真实的。
      _killStaleCore(runtime.pidFile);

      // 1) 挑端口。默认的 2080 / 2081 被占着时内核会直接起不来，而报错是一句
      //    用户看不懂的绑定失败。改成往后找可用的，用户什么都不用做。
      //    必须在生成配置**之前**确定：配置、系统代理、观测引擎三处共用它。
      final ports = await PortAllocator.allocate(from: mixedPort, count: 2);
      if (_aborted) return;
      if (ports.length < 2) {
        listener.onError('本地端口 $mixedPort 起连续 50 个都被占用，无法启动内核');
        await _stopCore(notifyStatus: true);
        return;
      }
      _mixedPort = ports[0];
      _clashApiPort = ports[1];
      // 观测引擎是构造期建好的，这里把新端口同步过去，否则它会一直去问默认端口。
      _hooks.clashApiPort = _clashApiPort;
      // MTU 校验要从这个端口把包送进隧道，同理必须同步。
      _hooks.mixedPort = _mixedPort;
      // 配置里声明的 MTU：校验的是**用户写的那个值**，而不是回退后的默认值。
      _hooks.declaredMtu = profile.parsed.declaredMtu;
      if (_mixedPort != mixedPort) {
        listener.onError('默认端口 $mixedPort 被占用，本次改用 $_mixedPort');
      }

      // 1) 生成配置。规则集直接引用随包分发的文件，避免二次拷贝。
      //    每次都重新生成：这样自动纠正表里新学到的规则能在下次连接时生效。
      final config = SingBoxConfigBuilder.build(
        profile: profile.parsed,
        splitMode: settings.splitMode,
        ruleSetDir: runtime.ruleSetDir.path,
        mixedPort: _mixedPort,
        clashApiPort: _clashApiPort,
        logSplits: settings.logSplits,
        autoRoute: _autoRoute,
      );
      final configFile = File(
        '${runtime.workDir.path}${Platform.pathSeparator}config.json',
      );
      configFile.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      // 2) 启动内核。
      // 刻意**不清空**日志：内核崩了又自动重连时，「崩之前那几行」正是要看的
      // 东西。缓冲有容量上限，不会无限增长；界面上另有清空入口。
      _autoRoute.evictStale();
      final process = await Process.start(
        runtime.singBoxExe.path,
        <String>['run', '-c', configFile.path],
        workingDirectory: runtime.workDir.path,
        runInShell: false,
      );
      _process = process;
      _uptime
        ..reset()
        ..start();
      // 进程刚起来，用户可能正好在这一刻点了断开。**必须在这里查**：晚一步的
      // 话，进程已经起好了，而 disconnect() 早就执行完了——它会留下一个没人
      // 管的孤儿内核，界面却显示未连接。
      if (_aborted) {
        await _stopCore(notifyStatus: false);
        return;
      }
      runtime.pidFile.writeAsStringSync('${process.pid}');
      process.stdout.transform(utf8.decoder).listen(_appendLog);
      process.stderr.transform(utf8.decoder).listen(_appendLog);
      unawaited(
        process.exitCode.then((int code) async {
          if (_process != process) return;
          // 内核自己退出了：多半是配置或网络问题，把原因带出来。
          _process = null;
          _uptime.stop();
          monitor.stop();
          // 必须同时撤销系统代理。否则内核已经没了、代理还指着它，
          // 用户的所有网站都会打不开，而且完全看不出原因。
          if (_proxyTakenOver) {
            await proxy.clear();
            _proxyTakenOver = false;
          }
          _deletePidFile();

          // 把待续区那半行也收下：进程退出时最后一行往往没有换行符结尾，
          // 而它经常正是崩溃原因。
          kernelLog.flushPending();
          final last = _lastLogLine;
          final detail = last == null ? '' : '：$last';
          // 交给状态机裁决：用户主动断开时它绝不重连；刚起来就死时只给很少
          // 的次数；稳定跑过一阵再崩则算新事故。
          final decision = _recovery.onCoreExit(
            uptime: _uptime.elapsed,
            userInitiated: _userDisconnect,
          );
          if (!decision.shouldRetry) {
            final reason = _userDisconnect || decision.reason.isEmpty
                ? ''
                : '，${decision.reason}';
            listener.onError('内核已退出（代码 $code）$detail$reason');
            listener.onStatusChanged(VpnStatus.disconnected);
            return;
          }

          // 保持「连接中」而不是「已断开」：重连期间界面上不该出现未连接，
          // 那会让人以为隧道已经停了，而实际上它马上就会回来。
          listener.onError(
            '内核已退出（代码 $code）$detail，'
            '${decision.delay.inSeconds} 秒后自动重连（第 ${decision.attempt} 次）',
          );
          _scheduleReconnect(decision.delay);
        }),
      );

      // 3) 等内核就绪：Clash API 能应答就说明配置已经完整加载。
      final ready = await monitor.waitForApi(
        const Duration(seconds: 12),
        isAlive: () => _process != null,
      );
      if (_aborted) {
        await _stopCore(notifyStatus: false);
        return;
      }
      if (!ready) {
        // 内核在就绪之前就退出了：退出回调已经给出真正的原因（配置错、证书
        // 不对、端口被占……），这里再补一句「启动超时」会**把真实原因盖掉**，
        // 还会把人引向错误的排查方向。退出回调也已经做完了清理。
        if (_process == null) return;

        kernelLog.flushPending();
        final last = _lastLogLine;
        final detail = last == null ? '' : '：$last';
        listener.onError('内核启动超时$detail');
        // 启动超时不进重试循环：它意味着内核活着但始终没就绪，多半是配置
        // 或端口被占，反复重启只会重复同样的 12 秒等待。
        await _stopCore(notifyStatus: true);
        return;
      }

      // 4) 接管系统代理。
      //
      // 桌面端只有这一条可用路径。sing-box 的 tun 入站需要 wintun.dll 与管理员
      // 权限，两者都不具备，因此这里不再提供「TUN」选项（设置页已说明）；
      // 若历史设置里残留了 TUN，也在恢复时被忽略，不会出现「选了却不生效」
      // 的假象——那意味着界面上写着「接管全部程序」，实际只有认系统代理的
      // 程序走隧道，而用户完全看不出区别。
      _proxyTakenOver = await proxy.set(host: '127.0.0.1', port: _mixedPort);
      // 设代理是异步的，用户也可能正好在这一刻点了断开。不查这一步的后果
      // 比「晚一点断开」严重得多：系统代理会被**重新装上**，界面显示已连接，
      // 而用户以为隧道已经关了。
      if (_aborted) {
        await _stopCore(notifyStatus: false);
        return;
      }
      if (!_proxyTakenOver) {
        listener.onError('无法设置系统代理，请检查系统设置是否被策略锁定');
      }

      // 5) 就绪门控：等隧道真的能载一个来回，再宣布「已连接」。
      //
      // 不加这一步会有一段**用户实际能感觉到、但界面矢口否认**的窗口：内核
      // 报 Clash API 就绪时 WireGuard 握手往往还没完成，此后约 5 秒内经隧道的
      // 请求全部超时，而界面已经写着「已连接」——用户只能得出「这软件坏了」。
      //
      // 门控失败**不阻断连接**：超时后照旧宣布已连接，但明确说一句尚未就绪。
      // 直接卡在「连接中」更糟——那会把一个可能只是握手慢的节点显示成连不上，
      // 而用户连断开的机会都被含糊掉了。
      // 门控内部会先广播「建立隧道中」，因此这里不再重复广播。
      // 它超时也已经写好提示；桌面端到此为止不改变后续流程——门控失败**不阻断
      // 连接**，照旧宣布已连接，只是在界面上说清「尚未就绪」。
      await runTunnelReadyGate(
        listener: listener,
        probe: monitor.probeTunnelReadiness,
        isAborted: () => _aborted,
        timeout: readyGateTimeout,
      );
      if (_aborted) {
        await _stopCore(notifyStatus: false);
        return;
      }

      listener.onStatusChanged(VpnStatus.connected);
      // 观测引擎在状态变为已连接之后启动：
      // 它第一件事就是探测 DNS 与自检，界面此时已经有「已连接」这个前提了。
      // 预热起点用隧道建立那一刻，这样门控已经花掉的时间不会被重复计算。
      monitor.start(since: _tunnelSince);
      // MTU 校验放在最后、且**不等待**：它要往隧道里推一个接近 MTU 的包，
      // 慢的话会拖住「已连接」的宣布。结论稍后经 onMtuCheck 回来。
      if (probesEnabled) unawaited(monitor.checkMtu());
    } on Object catch (e) {
      listener.onError('启动失败：$e');
      // 走 _stopCore 而不是 disconnect：后者会把 _userDisconnect 置真，
      // 让紧随其后的「内核退出」回调被误判成用户主动断开。同一个错误在
      // 自动重连期间会重复出现，这个区分必须保持干净。
      await _stopCore(notifyStatus: true);
    }
  }

  // ---------------------------------------------------------------- 停止

  @override
  Future<void> disconnect() async {
    // 先立旗标再拆内核：拆的过程会触发「内核退出」回调，旗标不到位就会
    // 被当成崩溃并自动重连回来。
    _userDisconnect = true;
    _cancelReconnect();
    _recovery.reset();
    _healthGuard.reset();
    await _stopCore(notifyStatus: true);
  }

  /// 拆掉内核与系统代理。
  ///
  /// [notifyStatus] 为 false 时不广播「已断开」：连接与重连的过程中会先
  /// 拆旧实例，那一刻界面不该闪回未连接。
  Future<void> _stopCore({required bool notifyStatus}) async {
    monitor.stop();

    if (_proxyTakenOver) {
      // 还原失败**必须出声**。
      //
      // 这一步失败意味着系统代理仍指着即将（或已经）退出的内核：用户所有网站都
      // 打不开，而现象与隧道毫无关系——没有人会想到去代理设置里找原因。此前
      // 这里只看返回值、不报错，属于「安静地失败」，正是最该避免的一类。
      final restored = await proxy.clear();
      _proxyTakenOver = false;
      if (!restored) {
        listener.onError(
          '没能还原系统代理，浏览器可能无法上网。'
          '请在「设置 → 网络和 Internet → 代理」中关闭手动代理设置',
        );
      }
    }

    final process = _process;
    _process = null;
    _uptime.stop();
    // 把待续区那半行收下。
    //
    // 不做这一步会留下一个很难看的痕迹：内核在被杀掉前若正好写了一半日志
    // （输出没有以换行结尾），那半行会留在缓冲里，**粘到下一次连接的第一行
    // 前面**，于是日志里出现一条根本不存在的内容。退出回调那条路径已经做了
    // 这件事，而主动停止这条路径此前漏了。
    kernelLog.flushPending();
    if (process != null) {
      process.kill();
      // 给它一点时间做清理；超时就不再等。
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _deletePidFile();
    }

    listener.onTraffic(downBps: 0, upBps: 0, totalBytes: 0);
    listener.onLatency(null);
    if (notifyStatus) listener.onStatusChanged(VpnStatus.disconnected);
  }

  // ------------------------------------------------------------ 自动重连

  /// 安排一次重连。
  void _scheduleReconnect(Duration delay) {
    _cancelReconnect();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      final profile = _lastProfile;
      final settings = _lastSettings;
      if (_disposed || _userDisconnect || profile == null || settings == null) {
        return;
      }
      // 不在这里做重试计数：重连若再次失败，内核的退出回调会带着新的
      // 存活时长回到同一个状态机，由它统一裁决。
      unawaited(_startTunnel(profile, settings));
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// 隧道健康判定结果。断线自愈的第二条路径：内核还活着，但隧道已经不通。
  ///
  /// 与「内核崩溃」相比，这种情况更隐蔽——界面上速率、连接数都还在动，
  /// 用户却打不开任何国外网站。内核的 WireGuard 会话可能卡在一条早已失效的
  /// UDP 映射上，重启内核是唯一能立刻恢复的手段。
  void handleTunnelHealth(TunnelHealth health) {
    if (!health.isProblem) {
      // 恢复正常：本轮事故结束。注意只归还次数、不清除冷却时间戳，
      // 否则「断了又通、通了又断」会把额度反复重置成无限重连。
      _healthGuard.noteHealthy();
      return;
    }
    if (!health.shouldRecover) return; // 本地网络问题：重连没有意义
    if (_disposed || _userDisconnect) return;

    final now = DateTime.now();
    if (!_healthGuard.shouldRestart(now)) {
      // 被拦下来时必须出声。此前只有「额度用尽」会提示，而「还在冷却期内」
      // 是**静默**的：用户看到诊断结论说隧道异常，却什么也没发生，也没有
      // 任何解释。结论只在变化时上报，因此这里不会刷屏。
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
    unawaited(_restartCore());
  }

  /// 因健康问题重启内核：复用同一条启动路径，但保留自愈与重试计数。
  Future<void> _restartCore() async {
    final profile = _lastProfile;
    final settings = _lastSettings;
    if (_disposed || _userDisconnect || profile == null || settings == null) {
      return;
    }
    // 顺手取消待执行的重连：正常情况下此刻不该有（观测引擎在崩溃时就已停掉，
    // 不会有健康结论产生），但两条路径都通向「把内核拉起来」，同时发生就会
    // 起两个实例、后一个因端口被占而失败。一行保险，成本为零。
    _cancelReconnect();
    await _stopCore(notifyStatus: false);
    await _startTunnel(profile, settings);
  }

  @override
  void dispose() {
    _disposed = true;
    _userDisconnect = true;
    _cancelReconnect();
    monitor.stop();
    _process?.kill();
    _process = null;
    // 兜底还原系统代理。
    //
    // 正常退出由原生侧在 WM_DESTROY / WM_QUERYENDSESSION 里完成，这里再补一次，
    // 覆盖「原生还没收到退出消息、Dart 先被释放」的路径（开发时的热重启、引擎
    // 重建）。clear 是幂等的，且只在**确实由我们接管过**时才调用——不会去动
    // 用户自己的代理设置。
    if (_proxyTakenOver) {
      _proxyTakenOver = false;
      unawaited(proxy.clear());
    }
    super.dispose();
  }

  // ------------------------------------------------------------ 运行时路径

  /// 随包分发的内核与规则库所在位置。
  ///
  /// 内核是可执行文件，由 Windows 构建脚本直接放在 xvpn.exe 旁边（见
  /// windows/CMakeLists.txt），不走 Flutter 资源体系；规则集体积很小，
  /// 作为资源分发，两端共用。
  CoreRuntime _resolveRuntimePaths() {
    final override = runtimeOverride;
    if (override != null) return override;

    final exeDir = File(Platform.resolvedExecutable).parent;
    final assetDir = Directory(
      '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets'
      '${Platform.pathSeparator}assets${Platform.pathSeparator}rulesets',
    );
    final ruleDir = assetDir;

    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final workDir = Directory(
      '$localAppData${Platform.pathSeparator}XVPN${Platform.pathSeparator}runtime',
    );

    return CoreRuntime(
      singBoxExe: File('${exeDir.path}${Platform.pathSeparator}sing-box.exe'),
      // 规则库用可写目录里的副本：出厂副本首次运行时复制过去，之后可由
      // 「检查更新」覆盖，既保证离线可用，又不依赖安装目录的写权限。
      ruleSetDir: RuleSetStore.ensure(ruleDir),
      assetDir: assetDir,
      workDir: workDir,
    );
  }

  /// 删除 PID 文件。正常断开时内核已确认退出，这个文件就失去意义了。
  void _deletePidFile() {
    try {
      final pid = _resolveRuntimePaths().pidFile;
      if (pid.existsSync()) pid.deleteSync();
    } on Object {
      // 删不掉也不影响功能。
    }
  }

  /// 清理上次被强杀后残留的内核进程。
  ///
  /// 必须校验进程名：PID 会被系统复用，只按数字杀进程可能误伤别的程序。
  void _killStaleCore(File pidFile) {
    try {
      if (!pidFile.existsSync()) return;
      final pid = int.tryParse(pidFile.readAsStringSync().trim());
      pidFile.deleteSync();
      if (pid == null || pid <= 0) return;

      final probe = Process.runSync('tasklist', <String>[
        '/FI',
        'PID eq $pid',
        '/NH',
        '/FO',
        'CSV',
      ]);
      if (!probe.stdout.toString().toLowerCase().contains('sing-box.exe')) {
        return;
      }
      Process.runSync('taskkill', <String>['/F', '/PID', '$pid']);
      listener.onError('已清理上次残留的内核进程（PID $pid）');
    } on Object {
      // 清理失败不阻断连接：端口若真被占用，内核启动时会自己报错。
    }
  }

  // ---------------------------------------------------------------- 日志

  /// 内核输出到达。按块处理，由 [VpnCore.handleCoreLogChunk] 负责拼接完整行。
  ///
  /// 拼接这件事比看上去重要：stdout 的分块是任意的，一段日志行完全可能被切成
  /// 两块。原实现直接按 `\n` 切分，于是会产出半截行——而崩溃前的那一行，
  /// 恰恰经常就是被切断的那一行。
  void _appendLog(String chunk) {
    // 顺路做失败归因与自动纠正：内核在失败日志里写明了走的哪个出站，
    // 这正是区分「规则判错」与「节点不通」所需要的唯一信息。
    handleCoreLogChunk(chunk);
  }
}

/// 找不到内核文件时给用户的提示。
///
/// 只报路径是不够的——用户看到一条自己机器上的路径，既不知道它为什么会不见，
/// 也不知道能做什么。而这件事在真实环境里**最常见的原因是被杀毒软件隔离**：
/// `sing-box.exe` 是代理内核，误报率很高。因此提示要把这个可能性与动作一起给出。
String missingKernelMessage(String path) =>
    '缺少内核文件 sing-box.exe——它可能被杀毒软件隔离或删除了。'
    '请在杀毒软件的隔离区里恢复它并加入白名单，或重新安装 XVPN。'
    '（应有位置：$path）';

/// 找不到规则库文件时给用户的提示。
///
/// 规则库决定「哪些域名与 IP 走直连」，缺了它分流就无从谈起。它随安装包分发，
/// 用户侧没有可操作的地方，因此只需说清「重新安装」这一条路，外加位置便于排查。
String missingRuleSetMessage(String path) =>
    '缺少内置规则库，国内直连与分流无法工作。请重新安装 XVPN 以恢复。'
    '（缺失文件：$path）';

/// 连接流程最多为「隧道就绪」等多久。
///
/// 取 20 秒：实测同一可用节点上首次握手约 5 秒，留出几次尝试的余量；再长就
/// 变成了让用户干等一个大概率连不上的节点。
const Duration tunnelReadyTimeout = Duration(seconds: 20);

/// 就绪门控超时后给用户的提示。
///
/// 提成常量而不是就地写字符串：界面需要在隧道**随后恢复**时把这句撤掉。
/// 它是「连接过程」的临时说明，不是持续状态——留着会让用户拿一句过期的
/// 结论排查一个已经好了的隧道。
const String tunnelNotReadyNotice = '隧道建立用时较长，尚未能通过隧道访问网络；若持续打不开，请检查节点或服务端配置';

/// 两次就绪探测之间的间隔。
const Duration tunnelReadyProbeInterval = Duration(milliseconds: 1200);

/// 等隧道真的能载一个来回。
///
/// 返回 true 表示**已经确认**隧道可用（探测拿到端到端耗时）；false 表示等到
/// 超时仍未确认——调用方据此决定怎么措辞，而不是据此拒绝连接。
///
/// [isAborted] 在每次探测前后都会查：用户可能就在这几秒里点了断开，不查的话
/// 会把一个已经拆掉的内核重新宣布成已连接。
Future<bool> waitForTunnelReady({
  required Future<int?> Function() probe,
  required bool Function() isAborted,
  Duration timeout = tunnelReadyTimeout,
  Duration interval = tunnelReadyProbeInterval,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (isAborted()) return false;
    final delay = await probe();
    if (isAborted()) return false;
    if (delay != null) return true;
    // 等满了就别再多睡一觉：睡眠本身也要计入上限，否则实际等待会超出 timeout
    // 一个 interval，用户感觉到的上限就比写着的那个数大。
    if (!DateTime.now().add(interval).isBefore(deadline)) break;
    await Future<void>.delayed(interval);
  }
  return false;
}

/// 就绪门控的**完整流程**：广播预热态、等隧道通、超时给出提示。
///
/// 抽成一个函数而不是让两端各写一遍，理由是这里每一步都有语义：
/// 顺序错了（先广播 connected 再等）、漏了预热态、忘了超时提示，都会让用户看到
/// 「已连接却打不开」。两端各写一遍就迟早会分叉——这个项目已经有过一次教训
/// （观测能力两端各写一份，结果一端修好的问题在另一端依旧存在）。
///
/// 返回 true 表示**已经确认**隧道可用。返回 false 既可能是超时，也可能是中途
/// 被取消（[isAborted]）——调用方一律按「不要继续宣布已连接」处理：
/// 门控超时不阻断连接由调用方自己决定，但被取消时必须收手。
///
/// 门控超时不阻断连接这件事由调用方实现（照旧宣布已连接，但说一句尚未就绪），
/// 因为「怎么收尾」两端不同：桌面端要拆系统代理，安卓端要拆 VpnService。
Future<bool> runTunnelReadyGate({
  required VpnCoreListener listener,
  required Future<int?> Function() probe,
  required bool Function() isAborted,
  Duration timeout = tunnelReadyTimeout,
  Duration interval = tunnelReadyProbeInterval,
}) async {
  listener.onStatusChanged(VpnStatus.warmingUp);
  final ready = await waitForTunnelReady(
    probe: probe,
    isAborted: isAborted,
    timeout: timeout,
    interval: interval,
  );
  if (isAborted()) return false;
  if (!ready) listener.onError(tunnelNotReadyNotice);
  return ready;
}
