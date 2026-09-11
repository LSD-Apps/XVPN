/// 两端共用的观测引擎。
///
/// Windows 与 Android 的差别只有「内核怎么跑」和「流量怎么接管」，而连接观测、
/// 速率统计、失败归因、DNS 监测、自动纠正这些逻辑完全一致。这份代码此前被复制
/// 在两处（`singbox_runner.dart` 与 `android_vpn_core.dart`），已经出现过
/// 「一端修好、另一端还是旧行为」的问题。现在统一到这里，两端只保留
/// 启动/停止与平台交互。
///
/// 主要职责：
///
///   1. **读 Clash API 并保持只读一次**。一个长连接复用 [HttpClient]，
///      不再每次轮询都新建 TCP 连接。
///   2. **只做必要的工作**。累计流量每秒都要更新，而连接列表只在出现新连接时
///      才构造对象；速率、DNS、自检各有自己的节奏，不互相拖累。
///   3. **把观测结果转成对用户有意义的结论**：失败归因、DNS 健康、
///      自动纠正了哪些域名。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'auto_route.dart';
import 'clash_api.dart';
import 'cn_ip_index.dart';
import 'core_log.dart';
import 'dns_client.dart';
import 'dns_monitor.dart';
import 'record_buffer.dart';
import 'singbox_config.dart';
import 'startup_self_check.dart';
import 'vpn_core.dart';

/// 观测引擎的依赖注入点。
class CoreMonitorHooks {
  CoreMonitorHooks({
    required this.listener,
    required this.clashApiPort,
    this.autoRoute,
    CnIpIndex? cnIpIndex,
    this.dnsResolver,
    this.probesEnabled = true,
    this.httpClient,
  }) : cnIpIndex = cnIpIndex ?? CnIpIndex.empty;

  final VpnCoreListener listener;
  final int clashApiPort;

  /// 自动纠正表。为 null 时不做学习，行为与改造前一致。
  final AutoRouteTable? autoRoute;

  /// 中国 IP 索引，用于 DNS 交叉校验的地理判定。
  ///
  /// 可变字段而不是 final：索引是异步加载的（首次连接时才读盘），
  /// 而观测引擎在更早就建好了。加载完成后赋值即可，下一次 DNS 监测就会用上。
  CnIpIndex cnIpIndex;

  /// DNS 查询实现。默认走真实 UDP；测试可注入桩。
  final DnsResolver? dnsResolver;

  /// 是否允许主动探测（DNS 监测、启动自检、直连连通性）。
  ///
  /// 关掉之后「被动观测」（Clash API 轮询、速率、分流记录、失败归因）照常工作。
  /// 之所以做成可关闭：
  ///   * 单元测试里不该真的发 UDP 包与 TCP 连接；
  ///   * 计量网络或用户明确不希望后台流量时，需要一条只读不探的模式。
  final bool probesEnabled;

  /// Clash API 的 HTTP 客户端。为 null 时由观测引擎自建并复用。
  ///
  /// 做成可注入是为了让「一轮采样到底上报了什么数字」可以被真正测到——
  /// 那是界面上所有统计的唯一来源，只靠读代码确认等于没测。
  final HttpClient? httpClient;
}

/// 观测引擎。
class CoreMonitor {
  CoreMonitor(this.hooks)
      : _autoRoute = hooks.autoRoute,
        _clashApiPort = hooks.clashApiPort,
        _http = hooks.httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 3)
              ..idleTimeout = const Duration(seconds: 30));

  final CoreMonitorHooks hooks;
  final AutoRouteTable? _autoRoute;
  final int _clashApiPort;

  /// 复用的 HTTP 客户端。
  ///
  /// 原实现每次轮询都 `HttpClient()` + `close(force: true)`，即每秒建立并
  /// 拆除一次 TCP 连接。本地回环上这不算致命，但它同时意味着每秒一次的
  /// 三向握手与四次挥手，在连接数很大、界面本来就在吃力时是纯粹的额外负担。
  ///
  /// 由 [CoreMonitorHooks.httpClient] 注入时不再由本对象关闭——那属于调用方。
  final HttpClient _http;

  /// 已上报过的连接 id。有容量上限，见 [BoundedIdSet]。
  ///
  /// 原实现在长度超过 2000 时整体 `clear()`，那一刻「当前活着的每条连接」
  /// 都会被当成新连接重新上报，分流记录里立刻出现成片重复。
  static const int seenCapacity = 4000;

  final BoundedIdSet _seen = BoundedIdSet(seenCapacity);

  final RateCalculator _rate = RateCalculator();

  /// 已建立过连接的域名，用于「直连成功」的反证。
  ///
  /// 只保留最近若干条：这是纯粹的近期证据，不需要长期记忆。
  final BoundedIdSet _directSuccessSeen = BoundedIdSet(2000);

  late final DnsResolver _dnsResolver = hooks.dnsResolver ?? UdpDnsResolver();

  DnsMonitor? _dnsMonitor;
  StartupSelfCheck? _selfCheck;

  int _lastConnectionCount = 0;
  int _kernelMemory = 0;

  /// 本轮采样是否还在跑。慢探测（DNS 超时、内核卡住）会让定时器一轮接一轮地
  /// 叠起来，最终表现为界面越来越卡、数字越来越乱，因此要显式防重入。
  bool _tickRunning = false;

  bool _disposed = false;

  /// 轮询周期。1 秒是「够快」与「别浪费」之间的折中：
  /// 界面上速率与记录都按秒刷新，再快也只是重复同样的数字。
  static const Duration pollInterval = Duration(seconds: 1);

  /// DNS 监测间隔。DNS 状态不会每秒都变，探测本身要发 UDP 包，
  /// 频繁探测既浪费带宽也会把「耗时」测成排队时间。
  static const Duration dnsInterval = Duration(seconds: 45);

  /// 延迟探测间隔。
  static const Duration latencyInterval = Duration(seconds: 15);

  Timer? _pollTimer;
  Timer? _dnsTimer;
  Timer? _selfCheckTimer;
  DateTime? _lastLatencyProbe;
  int _latencyFailures = 0;

  AutoRouteTable? get autoRoute => _autoRoute;

  int get connectionCount => _lastConnectionCount;

  int get kernelMemory => _kernelMemory;

  // ---------------------------------------------------------------- 生命周期

  /// 内核就绪后调用。清空上一次会话的观测状态并开始定时采样。
  void start() {
    _seen.clear();
    _directSuccessSeen.clear();
    _rate.reset();
    _lastLatencyProbe = null;
    _latencyFailures = 0;
    _lastConnectionCount = 0;
    _kernelMemory = 0;

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(tick()));

    if (hooks.probesEnabled) {
      _ensureDnsMonitor();
      _dnsMonitor?.reset();
      _dnsTimer?.cancel();
      _dnsTimer = Timer.periodic(dnsInterval, (_) => unawaited(refreshDns()));

      _selfCheckTimer?.cancel();
      _selfCheckTimer = Timer.periodic(
        const Duration(minutes: 10),
        (_) => unawaited(runSelfCheck()),
      );

      // 第一轮尽快跑：界面在连上之后的几秒内就能看到真实结论，
      // 而不是先空白一分多钟。
      unawaited(refreshDns());
      unawaited(runSelfCheck());
    }
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _dnsTimer?.cancel();
    _dnsTimer = null;
    _selfCheckTimer?.cancel();
    _selfCheckTimer = null;
    _rate.reset();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _dnsResolver.close();
    // 注入进来的客户端由调用方负责关闭，避免测试里出现「用完之后被自己关掉」。
    if (hooks.httpClient == null) {
      try {
        _http.close(force: true);
      } on Object {
        // 关闭失败无所谓。
      }
    }
  }

  void _ensureDnsMonitor() {
    if (_dnsMonitor != null) {
      // 索引可能是异步加载完成后才到位的，这里同步一次。
      _dnsMonitor!.cnIpIndex = hooks.cnIpIndex;
      return;
    }
    final monitor = DnsMonitor(
      config: const DnsMonitorConfig(
        domesticServers: SingBoxConfigBuilder.domesticDns,
        tunnelProbeUrl: tunnelProbeUrl,
      ),
      resolver: _dnsResolver,
      tunnelLatencyProbe: probeTunnelLatency,
      cnIpIndex: hooks.cnIpIndex,
    );
    // 经内核 DNS 模块解析，用于交叉校验的第二组答案。
    monitor.tunnelResolveProbe = resolveViaCoreDns;
    _dnsMonitor = monitor;

    _selfCheck ??= StartupSelfCheck(
      directProbe: probeDirectLatency,
      tunnelProbe: probeTunnelLatency,
      coreResolve: resolveViaCoreDns,
      domesticResolve: _resolveDomestically,
    );
  }

  // ---------------------------------------------------------------- 每次采样

  /// 跑一轮采样。可以安全地重复调用（例如手动刷新）。
  Future<void> tick() async {
    // 上一轮还没结束时直接跳过：慢探测（DNS 超时、内核卡住）会让每一轮都
    // 叠在一起，最终表现为界面越来越卡、数字越来越乱。
    if (_tickRunning || _disposed) return;
    _tickRunning = true;
    try {
      final body = await _get('/connections');
      if (body == null) return;
      Map<String, Object?> json;
      try {
        json = jsonDecode(body) as Map<String, Object?>;
      } on Object {
        return;
      }

      // 1) 累计流量：每秒都要更新。
      final totals = ClashSnapshot.totalsOf(json);
      _kernelMemory = totals.memory;
      final sample = _rate.sample(
        DateTime.now(),
        totals.downloadTotal,
        totals.uploadTotal,
      );
      if (sample != null) {
        final breakdown = _outboundBreakdown(json);
        _lastConnectionCount = breakdown.count;
        hooks.listener.onTraffic(
          downBps: sample.downBps,
          upBps: sample.upBps,
          totalBytes: sample.totalBytes,
          directBytes: breakdown.directBytes,
          proxiedBytes: breakdown.proxiedBytes,
          connectionCount: breakdown.count,
          kernelMemory: totals.memory,
        );
      }

      // 2) 新连接：只有这一路需要构造对象与拼字符串。
      _emitNewConnections(json);

      // 3) 延迟探测按自己的节奏走。
      await probeLatency();
    } finally {
      _tickRunning = false;
    }
  }

  /// 按出站聚合字节数与连接数。
  ///
  /// 这是**监测数据精确性**的关键补充：此前界面上只有一个「本次累计」，
  /// 用户无法回答「这些流量里有多少真的走了隧道」——而那恰恰是判断
  /// 分流是否按预期工作的唯一依据。
  ({int directBytes, int proxiedBytes, int count}) _outboundBreakdown(
    Map<String, Object?> json,
  ) {
    final rawList = json['connections'];
    if (rawList is! List) {
      return (directBytes: 0, proxiedBytes: 0, count: 0);
    }
    var directBytes = 0;
    var proxiedBytes = 0;
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final conn = raw.cast<String, Object?>();
      final bytes = _int(conn['upload']) + _int(conn['download']);
      final rawChains = conn['chains'];
      final proxied = rawChains is List &&
          rawChains.any((Object? c) => c.toString() == 'vpn');
      if (proxied) {
        proxiedBytes += bytes;
      } else {
        directBytes += bytes;
      }
    }
    return (
      directBytes: directBytes,
      proxiedBytes: proxiedBytes,
      count: rawList.length,
    );
  }

  static int _int(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  /// 新连接 → 分流记录，并顺带做两件事：
  ///   * 直连且跑出了流量的域名，记为「直连成功」的反证；
  ///   * 走隧道的流量按域名累计，供自动纠正判断规则是否真在用。
  void _emitNewConnections(Map<String, Object?> json) {
    final fresh = ClashSnapshot.pullNew(json, _seen);
    if (fresh.isEmpty) return;
    final table = _autoRoute;
    for (final conn in fresh) {
      hooks.listener.onSplitRecord(
        SplitRecord(
          time: DateTime.now(),
          target: conn.target,
          kind: conn.proxied ? RouteKind.proxy : RouteKind.direct,
          rule: conn.rule,
          outbound: conn.outbound,
        ),
      );
      if (table == null) continue;
      final host = conn.host.isNotEmpty ? conn.host : '';
      if (host.isEmpty) continue;
      if (conn.proxied) {
        table.recordProxiedBytes(host, conn.totalBytes);
      } else if (conn.totalBytes > 0) {
        // 只在确实记下了一次「直连成功」时才把它标记为已处理，否则每秒都会
        // 累加一次。注意必须用返回值判断：这个域名可能先失败过若干次、
        // 现在才第一次真正连通，那时它是**新的**反证，不能被去重集合挡掉。
        final domain = AutoRouteTable.normalizeDomain(host);
        if (domain.isNotEmpty && !_directSuccessSeen.contains(domain)) {
          if (table.recordDirectSuccess(host)) {
            _directSuccessSeen.add(domain);
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- 失败归因

  /// 内核日志回调。两端各自把日志行喂进来。
  ///
  /// 这是「自动化智能化分流」的入口：判为直连却失败是唯一能同时说明
  /// 「规则库没覆盖」与「需要改为走隧道」的证据。
  void onCoreLogLine(String line) {
    final failure = parseConnectionFailure(line);
    if (failure == null) return;
    hooks.listener.onConnectionFailure(failure);
    unawaited(_learnFromFailure(failure));
  }

  /// 把一次直连失败转成自动纠正的证据。
  ///
  /// 需要 DNS 交叉校验时先补一次校验——它要发 UDP 查询，因此异步做，
  /// 不阻塞日志回调；校验结果会写进证据里，让「疑似投毒」的域名
  /// 一次失败即可纠正（见 [AutoRouteTable.recordDirectFailure]）。
  Future<void> _learnFromFailure(ConnectionFailure failure) async {
    final table = _autoRoute;
    if (table == null) return;
    if (!failure.suggestsMissingRule) return;

    String? verdict;
    final monitor = _dnsMonitor;
    if (monitor != null) {
      try {
        final check = monitor.cachedCheck(failure.host) ??
            await monitor.crossCheck(failure.host);
        verdict = check.verdict.name;
      } on Object {
        // 校验失败不影响纠正：没有 DNS 证据时按普通阈值处理。
      }
    }

    final decision = table.recordDirectFailure(
      failure.host,
      reason: failure.reasonSummary,
      dnsVerdict: verdict,
    );
    if (decision.added) {
      hooks.listener.onAutoRouteLearned(decision);
    }
  }

  // ---------------------------------------------------------------- DNS 监测

  /// 跑一轮 DNS 监测并上报。
  Future<void> refreshDns() async {
    if (_disposed) return;
    _ensureDnsMonitor();
    final monitor = _dnsMonitor;
    if (monitor == null) return;
    try {
      final report = await monitor.runOnce();
      hooks.listener.onDnsReport(report);
    } on Object {
      // 探测失败不该影响连接：界面保持上一次的报告。
    }
  }

  /// 对一个域名做交叉校验（连接失败时调用，也可由界面主动触发）。
  Future<DnsCrossCheck?> crossCheck(String domain) async {
    _ensureDnsMonitor();
    final monitor = _dnsMonitor;
    if (monitor == null) return null;
    try {
      return await monitor.crossCheck(domain);
    } on Object {
      return null;
    }
  }

  Future<List<String>> _resolveDomestically(String domain) async {
    for (final server in SingBoxConfigBuilder.domesticDns) {
      final outcome = await _dnsResolver.query(server, domain);
      if (outcome.resolved) return outcome.answers;
    }
    return const <String>[];
  }

  // ---------------------------------------------------------------- 探测原语

  /// 让内核**经隧道**访问一个地址并计时。
  ///
  /// 用 `/proxies/{tag}/delay` 而不是 ping 服务器 IP：用户关心的是
  /// 「能不能顺畅上网」，而不是「服务器 ICMP 通不通」。内核会真的完成
  /// 解析、TCP 握手与 TLS 握手，回来的是端到端耗时。
  Future<int?> probeTunnelLatency() async {
    final body = await _get(
      '/proxies/${SingBoxConfigBuilder.vpnTag}/delay'
      '?timeout=8000&url=$tunnelProbeUrl',
      timeout: const Duration(seconds: 12),
    );
    if (body == null) return null;
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final delay = (json['delay'] as num?)?.toInt();
      return (delay != null && delay > 0) ? delay : null;
    } on Object {
      return null;
    }
  }

  /// 直连路径的连通性探测：经系统网络直接访问一个国内一线站点。
  ///
  /// 这是「启动自检」里判断「国内直连这条腿是否正常」的依据。
  Future<int?> probeDirectLatency() async {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        directProbeHost,
        443,
        timeout: const Duration(seconds: 5),
      );
      return watch.elapsedMilliseconds;
    } on Object {
      return null;
    } finally {
      try {
        socket?.destroy();
      } on Object {
        // 忽略。
      }
    }
  }

  /// 经内核 DNS 模块解析域名。
  ///
  /// sing-box 的 Clash API 暴露了 `/dns/query`，它走的是内核自己的 DNS 路由，
  /// 因此返回的正是「隧道内解析器给出的答案」，正好用来与国内解析器交叉校验。
  Future<List<String>> resolveViaCoreDns(String domain) async {
    final body = await _get('/dns/query?name=$domain&type=A');
    if (body == null) return const <String>[];
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final answer = json['Answer'];
      if (answer is! List) return const <String>[];
      final addresses = <String>[];
      for (final record in answer) {
        if (record is! Map) continue;
        final data = record['data']?.toString() ?? '';
        // A 记录里 data 就是地址；AAAA 会带冒号，这里一并放行，
        // 因为交叉校验只关心「两组答案是否一致」。
        if (data.isEmpty) continue;
        addresses.add(data);
      }
      return addresses;
    } on Object {
      return const <String>[];
    }
  }

  /// 隧道探测用的目标地址。
  ///
  /// 用 https 而不是 http：不少网络封 80 端口但放行 443，
  /// 用 80 会让正常的节点看起来像挂了。
  static const String tunnelProbeUrl = 'https://www.gstatic.com/generate_204';

  /// 直连探测的目标。选国内一线站点：它必须秒连，
  /// 连不上说明本地网络或 DNS 有问题，而不是节点问题。
  static const String directProbeHost = 'www.baidu.com';

  // ---------------------------------------------------------------- 启动自检

  /// 跑一次启动自检。
  Future<StartupSelfCheckReport?> runSelfCheck() async {
    if (_disposed) return null;
    _ensureDnsMonitor();
    final check = _selfCheck;
    if (check == null) return null;
    try {
      final report = await check.run();
      hooks.listener.onSelfCheck(report);
      return report;
    } on Object {
      return null;
    }
  }

  /// 延迟探测：把结果上报给界面，并区分抖动与真的挂了。
  Future<void> probeLatency() async {
    final now = DateTime.now();
    final last = _lastLatencyProbe;
    if (last != null && now.difference(last) < latencyInterval) return;
    _lastLatencyProbe = now;

    final delay = await probeTunnelLatency();
    if (delay != null) {
      hooks.listener.onLatency(delay);
      _latencyFailures = 0;
      return;
    }
    _latencyFailures++;
    hooks.listener.onLatency(null);
    // 连续失败才提醒：偶发一次多半是网络抖动。
    if (_latencyFailures == 3) {
      hooks.listener.onError('连续 3 次延迟探测失败，节点可能不稳定');
    }
  }

  // ---------------------------------------------------------------- HTTP

  /// 读一个 Clash API 接口。
  ///
  /// 注意 `/traffic` 与 websocket 形态的 `/connections` 是**流式**接口，
  /// 不会自己结束；这里只用于普通 GET，`join()` 必须带超时，
  /// 否则一个不返回的响应会把整个轮询卡死（这是踩过的坑）。
  Future<String?> _get(
    String path, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_disposed) return null;
    try {
      final request = await _http
          .getUrl(Uri.parse('http://127.0.0.1:$_clashApiPort$path'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } on Object {
      return null;
    }
  }

  /// 轮询 Clash API 直到它能应答，或超时。
  ///
  /// [isAlive] 用于提前退出：内核进程已经退出时没必要把超时等满。
  Future<bool> waitForApi(
    Duration timeout, {
    bool Function()? isAlive,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isAlive != null && !isAlive()) return false;
      if (await _get('/version') != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }
}
