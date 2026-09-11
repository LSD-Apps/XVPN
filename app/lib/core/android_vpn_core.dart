import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';
import 'auto_route.dart';
import 'core_monitor.dart';
import 'cn_ip_index.dart';
import 'singbox_config.dart';
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
  AndroidVpnCore(super.listener, {super.probesEnabled});

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

  CnIpIndex _cnIpIndex = CnIpIndex.empty;

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
      );

  // ---------------------------------------------------------------- 启动

  @override
  Future<void> connect(VpnProfile profile, AppSettings settings) async {
    await disconnect();
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
          detail == null || detail.isEmpty ? '内核启动超时，请查看系统日志' : '内核启动失败：$detail',
        );
        await disconnect();
        return;
      }

      listener.onStatusChanged(VpnStatus.connected);
      monitor.start();
    } on Object catch (e) {
      listener.onError('启动失败：$e');
      await disconnect();
    }
  }

  // ---------------------------------------------------------------- 停止

  @override
  Future<void> disconnect() async {
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
      final data = await rootBundle.load(asset);
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
