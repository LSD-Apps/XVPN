import 'dart:async';
import 'dart:math';

import '../models.dart';
import 'auto_route.dart';
import 'clash_api.dart';
import 'cn_ip_index.dart';
import 'core_log.dart';
import 'core_monitor.dart';
import 'dns_monitor.dart';
import 'singbox_config.dart';
import 'startup_self_check.dart';

/// 内核事件回调。UI 状态层实现它，内核只负责上报。
///
/// 关于「哪些方法是必需的」：观测相关的回调（DNS 报告、自检、自动纠正）
/// 都带默认实现。这样新增一种观测能力时，不会强迫所有实现立刻跟上——
/// 这正是此前复制两份观测代码的起因。
abstract class VpnCoreListener {
  void onStatusChanged(VpnStatus status);

  /// 流量统计。
  ///
  /// [directBytes] / [proxiedBytes] 是按出站聚合的已传输字节，
  /// [connectionCount] 是当前活连接数，[kernelMemory] 是内核报告的常驻内存。
  /// 三者都是可选上报：老实现可以只给总量。
  void onTraffic({
    required double downBps,
    required double upBps,
    required int totalBytes,
    int directBytes = 0,
    int proxiedBytes = 0,
    int connectionCount = 0,
    int kernelMemory = 0,
  });

  /// 到服务器的往返延迟（毫秒）。内核尚未测出时传 null。
  void onLatency(int? millis);

  void onSplitRecord(SplitRecord record);

  /// 一条连接失败。
  ///
  /// 这是「检测能力」的数据来源：失败本身用户看得见（网站打不开），
  /// 但**为什么失败**只有内核知道——判为直连却失败，和走了隧道却失败，
  /// 是两种截然不同的问题。见 [ConnectionFailure]。
  void onConnectionFailure(ConnectionFailure failure);

  void onError(String message);

  /// 一轮 DNS 监测的结果。
  void onDnsReport(DnsReport report) {}

  /// 一次启动自检的结果。
  void onSelfCheck(StartupSelfCheckReport report) {}

  /// 自动纠正表新增了一条规则。
  ///
  /// 上报它是为了让「程序自己学会了」这件事对用户可见——否则分流规则
  /// 在背后变化，用户只会觉得「有时候能连有时候不能」。
  void onAutoRouteLearned(AutoRouteDecision decision) {}

  /// 自动纠正表的整体变化（含用户手工增删）。
  void onAutoRouteChanged(AutoRouteTable table) {}
}

/// 隧道内核抽象。
///
/// 两个真实实现：
///   * Windows：[SingBoxRunner] 以子进程方式启动随附的 sing-box.exe，并接管系统代理；
///   * Android：[AndroidVpnCore] 通过 MethodChannel 调用 libbox，配合 VpnService 建立 TUN。
///
/// 两者的观测逻辑共用 [CoreMonitor]，因此统计口径完全一致。
abstract class VpnCore {
  VpnCore(this.listener, {this.probesEnabled = true}) {
    monitor = _createMonitor();
  }

  final VpnCoreListener listener;

  /// 是否允许内核层主动发起探测（DNS 监测、启动自检、直连连通性）。
  ///
  /// 关掉之后被动观测照常工作。测试与「只读模式」会把它设为 false；
  /// 见 [CoreMonitorHooks.probesEnabled]。
  final bool probesEnabled;

  /// 观测引擎。子类通过 [monitorHooks] 提供平台差异。
  late final CoreMonitor monitor;

  /// 内核名称，展示在诊断信息里。
  String get name;

  Future<void> connect(VpnProfile profile, AppSettings settings);

  Future<void> disconnect();

  /// 接管一个「界面进程没了、但内核还在跑」的隧道。
  ///
  /// 安卓的隧道跑在前台服务里，界面进程被系统回收后隧道不会停；此时重新打开
  /// 界面必须把状态接回来，否则会显示「未连接」而流量其实仍在走隧道——用户
  /// 要么以为没连上，要么以为断开失败了。
  ///
  /// 返回 true 表示确实接管了一个正在运行的内核。默认实现表示该平台没有这种
  /// 情况（内核与界面同生共死）。
  Future<bool> resumeIfRunning() async => false;

  /// 供观测引擎使用的东西。子类在构造时设置。
  ///
  /// 默认返回一个不做自动纠正的配置，让演示内核与测试不需要额外准备。
  CoreMonitorHooks monitorHooks() => CoreMonitorHooks(
        listener: listener,
        clashApiPort: SingBoxConfigBuilder.defaultClashApiPort,
        probesEnabled: probesEnabled,
      );

  /// 自动纠正表。为 null 表示本实现不做学习。
  AutoRouteTable? get autoRoute => monitor.autoRoute;

  CoreMonitor _createMonitor() => CoreMonitor(monitorHooks());

  /// 内核日志回调的统一入口。两端各自把日志行喂进来。
  void handleCoreLog(String line) => monitor.onCoreLogLine(line);

  /// 由界面主动触发一次 DNS 监测。
  Future<void> refreshDns() => monitor.refreshDns();

  /// 由界面主动触发一次自检。
  Future<void> runSelfCheck() => monitor.runSelfCheck();

  /// 中国 IP 索引，供界面展示地理判定。默认空表。
  CnIpIndex get cnIpIndex => CnIpIndex.empty;

  /// 用持久化的数据初始化自动纠正表。
  ///
  /// 由界面层在恢复设置后调用。做成独立方法而不是构造函数参数，
  /// 是为了让「内核」与「持久化」保持解耦——内核不认识 `AppStore`。
  ///
  /// 刻意声明为抽象而不是给一个空实现：不做学习的实现（演示内核）必须显式
  /// 写出来，否则「自动纠正在这个平台上悄悄失效」会变成一个看不出来的问题。
  void initAutoRoute(Object? saved);

  /// 导出自动纠正表，供界面层持久化。
  List<Map<String, Object?>> exportAutoRoute();

  void dispose() {
    monitor.dispose();
  }
}

/// 演示内核：不建立任何真实隧道，只产生与设计稿一致的界面数据。
///
/// 它的存在只为让界面可以在没有真实内核的情况下被完整走查，
/// 不参与任何真实网络行为。
class DemoVpnCore extends VpnCore {
  DemoVpnCore(super.listener);

  final Random _random = Random(20260214);
  Timer? _trafficTimer;
  Timer? _recordTimer;
  Timer? _connectTimer;
  double _down = 0;
  double _up = 0;
  int _total = 0;
  int _directTotal = 0;
  int _proxiedTotal = 0;
  int _hostIndex = 0;
  var _disposed = false;

  @override
  String get name => 'demo';

  /// 演示内核不参与自动纠正：它没有真实的连接失败，也就没有可学的证据。
  ///
  /// 显式写出来而不是继承一个默认空实现——自动纠正在这里「安静地不生效」
  /// 是预期行为，而不是一个看不出来的缺陷。
  @override
  void initAutoRoute(Object? saved) {}

  @override
  List<Map<String, Object?>> exportAutoRoute() => const <Map<String, Object?>>[];

  /// 演示数据：域名与预期判定，覆盖两种分流路径与三种命中规则。
  ///
  /// 规则名刻意写成**内核真实的原始描述文本**（`rule_set=[...] => route`），
  /// 并经过与真实链路完全相同的归一化函数，这样界面上走的代码路径与接上真实
  /// 内核时一模一样。此前这里直接给的是 `geosite-cn` 这种成品名，于是
  /// 「界面显示内核术语」的问题在演示数据上永远暴露不出来。
  static const _demoTargets = <(String, RouteKind, String)>[
    ('www.youtube.com', RouteKind.proxy, 'final'),
    ('www.baidu.com', RouteKind.direct, 'rule_set=[geosite-cn geoip-cn] => route'),
    ('api.openai.com', RouteKind.proxy, 'final'),
    ('220.181.38.148', RouteKind.direct, 'rule_set=[geosite-cn geoip-cn] => route'),
    ('github.com', RouteKind.proxy, 'final'),
    ('npmmirror.com', RouteKind.direct, 'rule_set=[geosite-cn geoip-cn] => route'),
    ('192.168.1.1', RouteKind.direct, 'ip_is_private=true => route'),
    ('cdn.jsdelivr.net', RouteKind.proxy, 'final'),
    ('taobao.com', RouteKind.direct, 'rule_set=[geosite-cn geoip-cn] => route'),
    ('x.com', RouteKind.proxy, 'final'),
  ];

  @override
  Future<void> connect(VpnProfile profile, AppSettings settings) async {
    listener.onStatusChanged(VpnStatus.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_disposed) return;
    listener.onStatusChanged(VpnStatus.connected);
    listener.onLatency(38 + _random.nextInt(20));
    _startTraffic();
    if (settings.logSplits) _startRecords();
  }

  @override
  Future<void> disconnect() async {
    _trafficTimer?.cancel();
    _recordTimer?.cancel();
    _connectTimer?.cancel();
    _trafficTimer = null;
    _recordTimer = null;
    _down = 0;
    _up = 0;
    listener.onTraffic(downBps: 0, upBps: 0, totalBytes: _total);
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  void _startTraffic() {
    // 首帧立即给一个非零值，避免界面出现 0.00 MB/s 的空白感。
    _down = 1.1 * 1024 * 1024;
    _up = 300 * 1024;
    _emitTraffic();
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _down = _walk(_down, 220 * 1024, 2.4 * 1024 * 1024);
      _up = _walk(_up, 60 * 1024, 900 * 1024);
      final delta = (_down + _up).round();
      _total += delta;
      // 演示内核也把总量拆成两条路径，界面上的分流占比才有数据。
      if (_hostIndex.isEven) {
        _proxiedTotal += delta;
      } else {
        _directTotal += delta;
      }
      _emitTraffic();
    });
  }

  double _walk(double current, double min, double max) {
    final next = current + (_random.nextDouble() - 0.45) * (max - min) * 0.35;
    return next.clamp(min, max);
  }

  void _emitTraffic() {
    listener.onTraffic(
      downBps: _down,
      upBps: _up,
      totalBytes: _total,
      directBytes: _directTotal,
      proxiedBytes: _proxiedTotal,
      connectionCount: 6 + _hostIndex % 5,
    );
  }
  void _startRecords() {
    _recordTimer = Timer.periodic(const Duration(milliseconds: 2600), (_) {
      final (target, kind, rule) = _demoTargets[_hostIndex % _demoTargets.length];
      _hostIndex++;
      listener.onSplitRecord(
        SplitRecord(
          time: DateTime.now(),
          target: target,
          kind: kind,
          // 走与真实内核相同的归一化路径，保证演示数据不会掩盖界面问题。
          rule: normalizeRuleDescription(rule),
          outbound: kind == RouteKind.proxy ? 'vpn' : 'direct',
        ),
      );
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _trafficTimer?.cancel();
    _recordTimer?.cancel();
    _connectTimer?.cancel();
    super.dispose();
  }
}
