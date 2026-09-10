import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'clash_api.dart';
import 'core_log.dart';
import 'rulesets.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import 'vpn_core.dart';

/// 真实内核：以子进程方式运行随包分发的 sing-box。
///
/// 工作流程与「傻瓜式」的对应关系：
///   1. 把 .conf 翻译成 sing-box 配置（[SingBoxConfigBuilder]）；
///   2. 启动内核，内核按内置规则库自行判定国内直连 / 国外走隧道；
///   3. 接管系统代理，让浏览器与绝大多数软件无需任何设置即可生效；
///   4. 从 Clash API 读取真实连接，界面上的「分流记录」由此而来——
///      不是模拟数据，而是内核实际做出的判定。
class SingBoxRunner extends VpnCore {
  SingBoxRunner(super.listener);

  /// 混合入站端口。与 [SingBoxConfigBuilder.defaultMixedPort] 保持一致。
  static const int mixedPort = SingBoxConfigBuilder.defaultMixedPort;
  static const int clashApiPort = SingBoxConfigBuilder.defaultClashApiPort;

  Process? _process;
  Timer? _pollTimer;
  final Set<String> _seenConnections = <String>{};
  final List<String> _logTail = <String>[];
  /// 累计字节数 → 瞬时速率的换算器。首次采样只建立基准。
  final RateCalculator _rate = RateCalculator();

  /// 上一次延迟探测的时间。延迟不必每秒测，否则会额外占用隧道带宽。
  DateTime? _lastLatencyProbe;

  /// 连续延迟探测失败次数。用于区分「偶发抖动」与「节点真的挂了」。
  int _latencyFailures = 0;

  /// 延迟探测的间隔。
  static const Duration latencyProbeInterval = Duration(seconds: 15);
  bool _proxyTakenOver = false;

  @override
  String get name => 'sing-box 1.14.0';

  /// 系统代理模式不需要管理员权限，这是它相对 TUN 的最大优势。
  @override
  bool get requiresElevation => false;

  /// 内核最近若干行日志，供诊断展示。
  List<String> get logTail => List<String>.unmodifiable(_logTail);

  // ---------------------------------------------------------------- 启动

  @override
  Future<void> connect(VpnProfile profile, AppSettings settings) async {
    await disconnect();
    listener.onStatusChanged(VpnStatus.connecting);

    try {
      final runtime = _resolveRuntimePaths();
      if (!runtime.singBoxExe.existsSync()) {
        listener.onError('未找到内核文件：${runtime.singBoxExe.path}');
        listener.onStatusChanged(VpnStatus.disconnected);
        return;
      }
      for (final ruleSet in runtime.ruleSets) {
        if (!ruleSet.existsSync()) {
          listener.onError('缺少规则库文件：${ruleSet.path}');
          listener.onStatusChanged(VpnStatus.disconnected);
          return;
        }
      }

      runtime.workDir.createSync(recursive: true);
      // 1) 生成配置。规则集直接引用随包分发的文件，避免二次拷贝。
      final config = SingBoxConfigBuilder.build(
        profile: profile.parsed,
        splitMode: settings.splitMode,
        ruleSetDir: runtime.ruleSetDir.path,
        logSplits: settings.logSplits,
      );
      final configFile = File('${runtime.workDir.path}${Platform.pathSeparator}config.json');
      configFile.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      // 2) 启动内核。先清掉上次可能残留的实例，否则端口会被占用。
      _killStaleCore(runtime.pidFile);
      _logTail.clear();
      _seenConnections.clear();
      _rate.reset();
      _lastLatencyProbe = null;
      final process = await Process.start(
        runtime.singBoxExe.path,
        <String>['run', '-c', configFile.path],
        workingDirectory: runtime.workDir.path,
        runInShell: false,
      );
      _process = process;
      runtime.pidFile.writeAsStringSync('${process.pid}');
      process.stdout.transform(utf8.decoder).listen(_appendLog);
      process.stderr.transform(utf8.decoder).listen(_appendLog);
      unawaited(process.exitCode.then((int code) async {
        if (_process != process) return;
        // 内核自己退出了：多半是配置或网络问题，把原因带出来。
        _process = null;
        _stopPolling();
        // 必须同时撤销系统代理。否则内核已经没了、代理还指着它，
        // 用户的所有网站都会打不开，而且完全看不出原因。
        if (_proxyTakenOver) {
          await SystemProxy.clear();
          _proxyTakenOver = false;
        }
        _deletePidFile();
        listener.onError('内核已退出（代码 $code）${_logTail.isEmpty ? '' : '：${_logTail.last}'}');
        listener.onStatusChanged(VpnStatus.disconnected);
      }));

      // 3) 等内核就绪：Clash API 能应答就说明配置已经完整加载。
      final ready = await _waitForApi(const Duration(seconds: 12));
      if (!ready) {
        final detail = _logTail.isEmpty ? '' : '：${_logTail.last}';
        listener.onError('内核启动超时$detail');
        await disconnect();
        return;
      }

      // 4) 接管系统代理。
      if (settings.takeoverMode == TakeoverMode.systemProxy) {
        _proxyTakenOver = await SystemProxy.set(
          host: '127.0.0.1',
          port: mixedPort,
        );
        if (!_proxyTakenOver) {
          listener.onError('无法设置系统代理，请检查系统设置是否被策略锁定');
        }
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

    if (_proxyTakenOver) {
      await SystemProxy.clear();
      _proxyTakenOver = false;
    }

    final process = _process;
    _process = null;
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
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  @override
  void dispose() {
    _stopPolling();
    _process?.kill();
    _process = null;
  }

  // ------------------------------------------------------------ 运行时路径

  /// 随包分发的内核与规则库所在位置。
  ///
  /// 内核是可执行文件，由 Windows 构建脚本直接放在 xvpn.exe 旁边（见
  /// windows/CMakeLists.txt），不走 Flutter 资源体系；规则集体积很小，
  /// 作为资源分发，两端共用。
  ({File singBoxExe, Directory ruleSetDir, List<File> ruleSets, Directory workDir, File pidFile}) _resolveRuntimePaths() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final ruleDir = Directory(
      '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets'
      '${Platform.pathSeparator}assets${Platform.pathSeparator}rulesets',
    );

    final localAppData = Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    final workDir = Directory(
      '$localAppData${Platform.pathSeparator}XVPN${Platform.pathSeparator}runtime',
    );

    return (
      singBoxExe: File('${exeDir.path}${Platform.pathSeparator}sing-box.exe'),
      // 规则库用可写目录里的副本：出厂副本首次运行时复制过去，之后可由
      // 「检查更新」覆盖，既保证离线可用，又不依赖安装目录的写权限。
      ruleSetDir: RuleSetStore.ensure(ruleDir),
      ruleSets: <File>[
        File('${ruleDir.path}${Platform.pathSeparator}geosite-cn.srs'),
        File('${ruleDir.path}${Platform.pathSeparator}geoip-cn.srs'),
      ],
      workDir: workDir,
      // 内核 PID。正常关闭由原生侧按「自己的子进程」精确清理；这里用于
      // 「被强杀」的场景：下次启动据此清掉残留实例，否则端口会被一直占着。
      pidFile: File('${workDir.path}${Platform.pathSeparator}core.pid'),
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

      final probe = Process.runSync(
        'tasklist',
        <String>['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
      );
      if (!probe.stdout.toString().toLowerCase().contains('sing-box.exe')) {
        return;
      }
      Process.runSync('taskkill', <String>['/F', '/PID', '$pid']);
      listener.onError('已清理上次残留的内核进程（PID $pid）');
    } on Object {
      // 清理失败不阻断连接：端口若真被占用，内核启动时会自己报错。
    }
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
    // 只查 /connections 这一个接口就够了：
    //   * 它是**普通快照**接口，一次返回连接列表与累计流量；
    //   * /traffic 是**流式**接口（持续推送、永不结束），用 GET 读它会一直
    //     挂着不返回——这曾导致后面的连接查询永远执行不到，
    //     表现为「最近分流」与流量统计同时没有数据。
    final body = await _apiGet('/connections');
    if (body == null) return;

    Map<String, Object?> json;
    try {
      json = jsonDecode(body) as Map<String, Object?>;
    } on Object {
      return;
    }

    _emitTraffic(json);
    _emitRecords(json);
    await _probeLatency();
  }

  /// 探测隧道延迟。
  ///
  /// 用 Clash API 的 delay 接口让内核**真的经隧道**发一次请求并计时，
  /// 这比 ping 服务器 IP 更准确——用户关心的是「能不能顺畅上网」，
  /// 而不是「服务器 ICMP 通不通」。
  ///
  /// 探测失败本身就是重要信息：说明节点当前不可用。
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
    if (body == null) {
      // 接口不可用不算节点问题，保持上一次的值，避免误报。
      return;
    }
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final delay = (json['delay'] as num?)?.toInt();
      if (delay != null && delay > 0) {
        listener.onLatency(delay);
        _latencyFailures = 0;
      } else {
        _registerLatencyFailure(json['message']?.toString() ?? '探测失败');
      }
    } on Object {
      _registerLatencyFailure('探测返回无法解析');
    }
  }

  void _registerLatencyFailure(String message) {
    _latencyFailures++;
    listener.onLatency(null);
    // 连续失败才提醒：偶发一次多半是网络抖动。
    if (_latencyFailures == 3) {
      listener.onError('连续 3 次延迟探测失败（$message），节点可能不稳定');
    }
  }

  /// 从累计字节数算出速率。
  void _emitTraffic(Map<String, Object?> json) {
    final downloadTotal = (json['downloadTotal'] as num?)?.toInt() ?? 0;
    final uploadTotal = (json['uploadTotal'] as num?)?.toInt() ?? 0;
    final sample = _rate.sample(DateTime.now(), downloadTotal, uploadTotal);
    if (sample == null) return; // 首次采样只建立基准
    listener.onTraffic(
      downBps: sample.downBps,
      upBps: sample.upBps,
      totalBytes: sample.totalBytes,
    );
  }

  /// 连接列表 → 分流记录。只上报本次新出现的连接。
  void _emitRecords(Map<String, Object?> json) {
    final snapshot = ClashSnapshot.fromJson(json);
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
  }

  // ---------------------------------------------------------------- HTTP

  Future<String?> _apiGet(String path, {Duration timeout = const Duration(seconds: 2)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$clashApiPort$path')).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      // join() 必须带超时：Clash API 里存在流式接口（如 /traffic），
      // 不设超时会让这个 Future 永远不完成，把整个轮询卡死在那里。
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 轮询 Clash API 直到它能应答，或超时。
  Future<bool> _waitForApi(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process == null) return false; // 进程已退出，不必再等
      final body = await _apiGet('/version');
      if (body != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  void _appendLog(String chunk) {
    for (final line in chunk.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      _logTail.add(trimmed);

      // 顺路做失败归因：内核在失败日志里写明了走的哪个出站，
      // 这正是区分「规则判错」与「节点不通」所需要的唯一信息。
      final failure = parseConnectionFailure(trimmed);
      if (failure != null) listener.onConnectionFailure(failure);
    }
    // 只保留最近若干行，够诊断即可。
    while (_logTail.length > 40) {
      _logTail.removeAt(0);
    }
  }
}
