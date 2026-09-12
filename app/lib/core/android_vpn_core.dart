import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';
import 'auto_route.dart';
import 'core_monitor.dart';
import 'cn_ip_index.dart';
import 'dns_client.dart';
import 'singbox_config.dart';
import 'singbox_runner.dart';
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
  AndroidVpnCore(super.listener, {super.probesEnabled, this.dnsResolver});

  /// DNS 解析实现。为 null 时由观测引擎自建真实 UDP 解析器。
  ///
  /// 与 Windows 端保持同一个可注入点：两端观测逻辑共用，注入点也该一样。
  final DnsResolver? dnsResolver;

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

  /// 是否正在建立连接。
  ///
  /// 就绪门控会在这里干等最多 20 秒，而用户完全可能在这期间点断开。断开之后
  /// 若还继续探测、甚至宣布「已连接」，就会把一个已经拆掉的隧道说成可用。
  /// 桌面端靠 `_userDisconnect` 拦住这件事，安卓端此前没有对应的旗标。
  bool _connecting = false;

  @override
  CnIpIndex get cnIpIndex => _cnIpIndex;

  @override
  void initAutoRoute(Object? saved) => _autoRoute.loadFrom(saved);

  @override
  List<Map<String, Object?>> exportAutoRoute() => _autoRoute.toJson();

  @override
  CoreMonitorHooks monitorHooks() => CoreMonitorHooks(
    listener: listener,
    clashApiPort: SingBoxConfigBuilder.defaultClashApiPort,
    autoRoute: _autoRoute,
    cnIpIndex: _cnIpIndex,
    probesEnabled: probesEnabled,
    dnsResolver: dnsResolver,
    // MTU 校验在安卓端**不做**，这是能力差异而不是遗漏：
    // 校验要把包经本地混合入站送进隧道，而 TUN 模式没有这个端口——内核自己
    // 按 MTU 分片，用户侧没有可校验的入口。界面两端都会显示这一行，只是移动端
    // 说明「由内核自行处理」，而不是显示一个永远「无法校验」的占位。
    declaredMtu: null,
  );

  // ---------------------------------------------------------------- 启动

  @override
  Future<void> connect(VpnProfile profile, AppSettings settings) async {
    await disconnect();
    _connecting = true;
    listener.onStatusChanged(VpnStatus.connecting);

    try {
      // 1) 申请 VPN 授权。必须在 Activity 里弹系统对话框，因此走通道。
      final granted = await _channel.invokeMethod<bool>('prepareVpn') ?? false;
      if (!granted) {
        listener.onError('未获得 VPN 授权。请重新连接并在系统弹窗中选择「允许」');
        listener.onStatusChanged(VpnStatus.disconnected);
        return;
      }

      // 2) 资源解包。内核要的是真实文件路径，而 APK 里的资源读不到路径。
      final ruleSetDir = await _stageAssets();
      _cnIpIndex = await _loadCnIpIndex(ruleSetDir);

      // 3) 生成配置。分流与 DNS 策略与 Windows 端完全一致，
      //    自动纠正表也一并注入。
      final config = SingBoxConfigBuilder.build(
        profile: profile.parsed,
        splitMode: settings.splitMode,
        ruleSetDir: ruleSetDir,
        // 安卓只能走 TUN：VpnService 的 fd 必须在应用进程内创建。
        inboundMode: InboundMode.tun,
        logSplits: settings.logSplits,
        autoRoute: _autoRoute,
      );

      // 4) 接收内核日志，供失败归因与自动纠正使用。
      _channel.setMethodCallHandler(_onPlatformCall);

      // 5) 启动服务并等内核就绪。
      await _channel.invokeMethod<void>('connect', <String, Object?>{
        'config': SingBoxConfigBuilder.encode(config),
      });

      final ready = await monitor.waitForApi(const Duration(seconds: 25));
      if (!ready) {
        final status = await _status();
        final detail = status['error'] as String?;
        listener.onError(
          detail == null || detail.isEmpty
              ? '内核启动超时，请查看系统日志'
              : '内核启动失败：$detail',
        );
        await disconnect();
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
        isAborted: () => isDisposed || !_connecting,
      );
      if (isDisposed || !_connecting) return;

      listener.onStatusChanged(VpnStatus.connected);
      // 预热起点用隧道建立那一刻，这样门控已经花掉的时间不会被重复计算。
      monitor.start(since: _tunnelSince);
    } on Object catch (e) {
      listener.onError('启动失败：$e');
      await disconnect();
    } finally {
      _connecting = false;
    }
  }

  // ---------------------------------------------------------------- 停止

  @override
  Future<void> disconnect() async {
    // 先落旗标：就绪门控可能正在等待，旗标不到位它会把一个已经拆掉的隧道
    // 接着宣布成「已连接」。
    _connecting = false;
    monitor.stop();
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on Object {
      // 服务可能已经不在，忽略。
    }
    listener.onTraffic(downBps: 0, upBps: 0, totalBytes: 0);
    listener.onLatency(null);
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  @override
  Future<bool> resumeIfRunning() async {
    final status = await _status();
    if (status['running'] != true) return false;
    // 内核日志的转发回调在 connect() 里注册；接管路径也要注册，否则失败归因失效。
    _channel.setMethodCallHandler(_onPlatformCall);
    listener.onStatusChanged(VpnStatus.connected);
    // 接管后观测从零开始：这之前的连接属于上一个界面进程，不必补记。
    monitor.start();
    return true;
  }

  @override
  void dispose() {
    monitor.stop();
    super.dispose();
  }

  // ------------------------------------------------------------ 资源解包

  /// 把随包分发的资源写到应用私有目录，返回该目录路径。
  ///
  /// 只在文件缺失或内容不对时重写：解包不到 100 KB 不贵，但没必要每次连接都做。
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
        data = await rootBundle.load(asset);
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
