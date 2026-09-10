import 'dart:async';
import 'dart:math';

import '../models.dart';
import 'core_log.dart';

/// 内核事件回调。UI 状态层实现它，内核只负责上报。
abstract class VpnCoreListener {
  void onStatusChanged(VpnStatus status);
  void onTraffic({required double downBps, required double upBps, required int totalBytes});

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
}

/// 隧道内核抽象。
///
/// 当前只有一个 [DemoVpnCore] 实现，用于在没有内核的情况下验证界面。
/// 后续会补上两个真实实现，接口保持不变：
///   * Windows：以子进程方式启动随附的 sing-box.exe，并接管系统代理；
///   * Android：通过 MethodChannel 调用 libbox，配合 VpnService 建立 TUN。
abstract class VpnCore {
  VpnCore(this.listener);

  final VpnCoreListener listener;

  /// 内核名称，展示在诊断信息里。
  String get name;

  /// 该平台上是否需要管理员权限才能接管全部流量。
  bool get requiresElevation;

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

  void dispose();
}

/// 演示内核：不建立任何真实隧道，只产生与设计稿一致的界面数据。
///
/// TODO(core): 接入真实内核后删除本文件。它的存在只为让界面可以在
/// 真机上被完整走查，不参与任何真实网络行为。
class DemoVpnCore extends VpnCore {
  DemoVpnCore(super.listener);

  final Random _random = Random(20260214);
  Timer? _trafficTimer;
  Timer? _recordTimer;
  Timer? _connectTimer;
  double _down = 0;
  double _up = 0;
  int _total = 0;
  int _hostIndex = 0;
  var _disposed = false;

  @override
  String get name => 'demo';

  @override
  bool get requiresElevation => false;

  /// 演示数据：域名与预期判定，覆盖两种分流路径与三种命中规则。
  static const _demoTargets = <(String, RouteKind, String)>[
    ('www.youtube.com', RouteKind.proxy, '默认规则'),
    ('www.baidu.com', RouteKind.direct, 'geosite-cn'),
    ('api.openai.com', RouteKind.proxy, '默认规则'),
    ('220.181.38.148', RouteKind.direct, 'geoip-cn'),
    ('github.com', RouteKind.proxy, '默认规则'),
    ('npmmirror.com', RouteKind.direct, 'geosite-cn'),
    ('192.168.1.1', RouteKind.direct, '局域网地址'),
    ('cdn.jsdelivr.net', RouteKind.proxy, '默认规则'),
    ('taobao.com', RouteKind.direct, 'geosite-cn'),
    ('x.com', RouteKind.proxy, '默认规则'),
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
      _total += (_down + _up).round();
      _emitTraffic();
    });
  }

  double _walk(double current, double min, double max) {
    final next = current + (_random.nextDouble() - 0.45) * (max - min) * 0.35;
    return next.clamp(min, max);
  }

  void _emitTraffic() {
    listener.onTraffic(downBps: _down, upBps: _up, totalBytes: _total);
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
          rule: rule,
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
  }
}
