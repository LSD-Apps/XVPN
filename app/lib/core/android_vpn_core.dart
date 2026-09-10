import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models.dart';
import 'clash_api.dart';
import 'core_log.dart';
import 'singbox_config.dart';
import 'vpn_core.dart';

/// 安卓端内核：通过 VpnService + libbox 建立隧道。
///
/// 与 Windows 端的差别只有三处，其余全部共用：
///   * 内核形态：进程内的库（libbox）而非子进程；
///   * 流量接管：VpnService 的 TUN 而非系统代理；
///   * 规则集：打包在 APK 里，需要先解包到可写目录再交给内核。
///
/// 分流规则、DNS 策略、配置生成、以及连接观测（Clash API）都与平台无关。
class AndroidVpnCore extends VpnCore {
  AndroidVpnCore(super.listener);

  /// 与 MainActivity / XvpnVpnService 约定的通道名。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/vpn');

  /// 规则集在 APK 资源里的位置。
  static const List<String> _ruleSetAssets = <String>[
    'assets/rulesets/geosite-cn.srs',
    'assets/rulesets/geoip-cn.srs',
  ];

  @override
  String get name => 'sing-box（libbox）';

  /// VpnService 不需要 root，但需要用户在系统弹窗里授权。
  @override
  bool get requiresElevation => false;

  Timer? _pollTimer;
  final Set<String> _seenConnections = <String>{};
  final RateCalculator _rate = RateCalculator();
  DateTime? _lastLatencyProbe;
  int _latencyFailures = 0;

  /// 与 Windows 端保持一致的轮询与探测节奏。
  static const Duration latencyProbeInterval = Duration(seconds: 15);

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

      // 2) 规则集解包。内核要的是真实文件路径，而 APK 里的资源读不到路径。
      final ruleSetDir = await _stageRuleSets();

      // 3) 生成配置。分流与 DNS 策略与 Windows 端完全一致。
      final config = SingBoxConfigBuilder.build(
        profile: profile.parsed,
        splitMode: settings.splitMode,
        ruleSetDir: ruleSetDir,
        // 安卓只能走 TUN：VpnService 的 fd 必须在应用进程内创建。
        inboundMode: InboundMode.tun,
        logSplits: settings.logSplits,
      );

      // 4) 接收内核日志，供失败归因使用。
      _channel.setMethodCallHandler(_onPlatformCall);

      // 5) 启动服务并等内核就绪。
      _seenConnections.clear();
      _rate.reset();
      _lastLatencyProbe = null;
      _latencyFailures = 0;
      await _channel.invokeMethod<void>('connect', <String, Object?>{
        'config': SingBoxConfigBuilder.encode(config),
      });

      final ready = await _waitForApi(const Duration(seconds: 25));
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
      _startPolling();
    } on Object catch (e) {
      listener.onError('启动失败：$e');
      await disconnect();
    }
  }

  // ---------------------------------------------------------------- 停止

  @override
  Future<void> disconnect() async {
    _stopPolling();
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
    // 接管后观测从零开始：这之前的连接属于上一个界面进程，不必补记。
    _seenConnections.clear();
    _rate.reset();
    _lastLatencyProbe = null;
    _latencyFailures = 0;
    // 内核日志的转发回调在 connect() 里注册；接管路径也要注册，否则失败归因失效。
    _channel.setMethodCallHandler(_onPlatformCall);
    listener.onStatusChanged(VpnStatus.connected);
    _startPolling();
    return true;
  }

  @override
  void dispose() {
    _stopPolling();
  }

  // ------------------------------------------------------------ 规则集解包

  /// 把随包分发的规则集写到应用私有目录，返回该目录路径。
  ///
  /// 只在文件缺失或内容不对时重写：解包 90 KB 不贵，但没必要每次连接都做。
  Future<String> _stageRuleSets() async {
    final base = await _channel.invokeMethod<String>('filesDir');
    if (base == null || base.isEmpty) {
      throw StateError('无法获取应用目录');
    }
    final dir = Directory('$base${Platform.pathSeparator}rulesets');
    dir.createSync(recursive: true);

    for (final asset in _ruleSetAssets) {
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

  // ---------------------------------------------------------------- 轮询

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_poll()));
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    final body = await _apiGet('/connections');
    if (body == null) return;
    final snapshot = ClashSnapshot.parse(body);
    if (snapshot == null) return;

    final sample = _rate.sample(
      DateTime.now(),
      snapshot.downloadTotal,
      snapshot.uploadTotal,
    );
    if (sample != null) {
      listener.onTraffic(
        downBps: sample.downBps,
        upBps: sample.upBps,
        totalBytes: sample.totalBytes,
      );
    }

    for (final conn in snapshot.newSince(_seenConnections)) {
      _seenConnections.add(conn.id);
      listener.onSplitRecord(
        SplitRecord(
          time: DateTime.now(),
          target: conn.target,
          kind: conn.proxied ? RouteKind.proxy : RouteKind.direct,
          rule: conn.rule,
          outbound: conn.outbound,
        ),
      );
    }
    if (_seenConnections.length > 2000) _seenConnections.clear();

    await _probeLatency();
  }

  /// 经隧道实测一次延迟。失败本身也是信息：说明节点当前不可用。
  Future<void> _probeLatency() async {
    final now = DateTime.now();
    final last = _lastLatencyProbe;
    if (last != null && now.difference(last) < latencyProbeInterval) return;
    _lastLatencyProbe = now;

    final body = await _apiGet(
      '/proxies/${SingBoxConfigBuilder.vpnTag}/delay'
      // 用 https：不少网络封 80 端口但放行 443；超时给足，实测节点往返可能到数秒，
      // 卡在 4 秒会让界面频繁显示「无数据」而不是真实延迟。
      '?timeout=8000&url=https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 12),
    );
    if (body == null) return; // 接口不可用不算节点问题
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final delay = (json['delay'] as num?)?.toInt();
      if (delay != null && delay > 0) {
        listener.onLatency(delay);
        _latencyFailures = 0;
      } else {
        _latencyFailures++;
        listener.onLatency(null);
        if (_latencyFailures == 3) {
          listener.onError('连续 3 次延迟探测失败，节点可能不稳定');
        }
      }
    } on Object {
      // 解析失败按探测失败处理，但不额外报错。
      listener.onLatency(null);
    }
  }

  // ---------------------------------------------------------------- 平台交互

  /// 接收原生推来的内核日志。
  Future<void> _onPlatformCall(MethodCall call) async {
    if (call.method == 'coreLog') {
      final line = call.arguments;
      if (line is String) {
        final failure = parseConnectionFailure(line);
        if (failure != null) listener.onConnectionFailure(failure);
      }
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

  // ---------------------------------------------------------------- HTTP

  Future<String?> _apiGet(
    String path, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:${SingBoxConfigBuilder.defaultClashApiPort}$path'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      // join() 必须带超时：Clash API 里有流式接口，不设超时会把轮询卡死。
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 轮询 Clash API 直到它能应答，或超时。
  ///
  /// 顺带检查原生侧是否已经报了错——那样就没必要把 25 秒等满，
  /// 用户也能更快看到失败原因。
  Future<bool> _waitForApi(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _apiGet('/version') != null) return true;
      final status = await _status();
      final error = status['error'];
      if (error is String && error.isNotEmpty) return false;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }
}
