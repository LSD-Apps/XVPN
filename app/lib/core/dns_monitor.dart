/// DNS 监测：解析器健康度 + 答案交叉校验。
///
/// 这一层要回答三个问题，它们分别对应三种不同的处置方式：
///
/// | 现象 | 结论 | 该做什么 |
/// | --- | --- | --- |
/// | 国内解析器超时或极慢 | 直连路径的解析环节坏了 | 换解析器；被投毒的域名更要走隧道 |
/// | 国内与隧道解析答案完全不一致，且国内那组在国内 | 域名有国内外两套部署（CDN 就近） | 按域名判定分流，不要一刀切 |
/// | 国内答案「不在国内」，且与隧道答案不一致 | 大概率被投毒 | 强制走隧道，否则直连必然失败 |
///
/// 之所以要单独做一层监测，而不是读内核日志：sing-box 的 `/connections`
/// 快照在服务端就把 DNS 流量过滤掉了
/// （`experimental/clashapi/connections.go` 里的
/// `metadata.OutboundType != C.TypeDNS`），所以 DNS 的表现**不会**出现在
/// 连接列表里，只能主动探测。
///
/// 所有统计都是纯计算（滚动窗口 + 分位数），网络部分通过注入
/// [DnsResolver] 隔离，因此可以完整单元测试。
library;

import 'dart:async';
import 'dart:collection';

import 'cn_ip_index.dart';
import 'dns_client.dart';

/// 一个解析器的健康度快照。
class ResolverHealth {
  const ResolverHealth({
    required this.server,
    required this.role,
    required this.samples,
    required this.failures,
    required this.consecutiveFailures,
    required this.lastMillis,
    required this.lastSummary,
    required this.lastCheckedAt,
  });

  /// 解析器地址。
  final String server;

  /// 用途：国内直连用，还是隧道内用。
  final String role;

  /// 参与统计的样本数（成功与失败都算）。
  final int samples;

  final int failures;

  /// 连续失败次数。用来区分「偶发抖动」与「真的挂了」。
  final int consecutiveFailures;

  /// 最近一次成功查询的耗时；最近一次失败时为 null。
  final int? lastMillis;

  /// 最近一次结果的简短描述。
  final String lastSummary;

  final DateTime? lastCheckedAt;

  bool get healthy => consecutiveFailures == 0 && samples > 0;

  /// 连续失败多少次才认定这个解析器「不响应」。
  ///
  /// 定在 3 而不是 1：DNS 探测走的是**明文 UDP**，偶尔丢一个包很正常。单次失败
  /// 不足以支撑一条要用户去改设置的结论，也不该让界面变黄——否则一次抖动就会
  /// 让「DNS 检测」长期看起来有问题，而这恰恰是用户最容易误解的地方。
  ///
  /// [statusLabel] 与界面的告警判定共用这个阈值，避免两处各写一个数而漂移。
  static const int downThreshold = 3;

  /// 是否已经可以判定这个解析器不响应。
  ///
  /// 界面据此决定要不要把这一行标成需要注意。刻意不复用 `consecutiveFailures > 0`：
  /// 那会让「文字说一致、颜色说异常」同时出现，用户只能得出「这软件一直报错」。
  bool get isDown => consecutiveFailures >= downThreshold;

  /// 有过失败但还没到定性程度。用于「不稳定」这种中间态展示。
  bool get isFlaky => consecutiveFailures > 0 && !isDown;

  double get successRate => samples == 0 ? 0 : (samples - failures) / samples;

  /// 界面用的可读状态。
  String get statusLabel {
    if (samples == 0) return '待探测';
    if (isDown) return '不响应';
    if (consecutiveFailures > 0) return '不稳定';
    return '正常';
  }
}

/// 滚动窗口的耗时统计。
///
/// 只保留最近 [capacity] 个样本：DNS 耗时受网络抖动影响很大，
/// 全量平均会把「刚刚变慢」这个最重要的信息冲淡。
class LatencyWindow {
  LatencyWindow({this.capacity = 32});

  final int capacity;
  final Queue<int> _samples = Queue<int>();

  int get length => _samples.length;
  bool get isEmpty => _samples.isEmpty;

  void add(int millis) {
    _samples.addLast(millis);
    while (_samples.length > capacity) {
      _samples.removeFirst();
    }
  }

  void clear() => _samples.clear();

  /// 分位数。窗口为空时返回 null。
  ///
  /// [quantile] 取 0.5 即中位数。用分位数而不是平均值：一次 3 秒超时
  /// 能把平均值从 20ms 拉到 100ms 以上，而中位数几乎不受影响。
  int? quantile(double quantile) {
    if (_samples.isEmpty) return null;
    final sorted = _samples.toList()..sort();
    final index = ((sorted.length - 1) * quantile).round();
    return sorted[index.clamp(0, sorted.length - 1)];
  }

  int? get median => quantile(0.5);

  int? get p95 => quantile(0.95);

  int? get min => _samples.isEmpty
      ? null
      : _samples.reduce((int a, int b) => a < b ? a : b);

  int? get average {
    if (_samples.isEmpty) return null;
    var sum = 0;
    for (final sample in _samples) {
      sum += sample;
    }
    return sum ~/ _samples.length;
  }
}

/// 一次完整监测的结果。
class DnsReport {
  const DnsReport({
    required this.checkedAt,
    required this.resolvers,
    required this.direct,
    required this.tunnel,
    required this.verdict,
  });

  final DateTime checkedAt;

  /// 各解析器的健康度，顺序与探测配置一致。
  final List<ResolverHealth> resolvers;

  /// 直连路径（经本地 nameserver）的耗时窗口。
  final LatencyWindow direct;

  /// 隧道路径（经内核 DNS 模块）的耗时窗口。
  final LatencyWindow tunnel;

  /// 交叉校验结论。
  final DnsVerdict verdict;

  bool get isEmpty => resolvers.isEmpty && direct.isEmpty && tunnel.isEmpty;

  /// 一句话结论，直接显示在界面上。
  String get summary {
    if (isEmpty) return '尚未完成 DNS 探测';

    final directMedian = direct.median;
    final tunnelMedian = tunnel.median;
    if (directMedian != null && tunnelMedian != null) {
      final delta = directMedian - tunnelMedian;
      if (delta > 120) {
        return '直连解析比隧道慢 ${delta}ms（$directMedian vs $tunnelMedian），'
            '国内域名可能正在走隧道解析';
      }
      return '直连解析 ${directMedian}ms · 隧道解析 ${tunnelMedian}ms';
    }
    if (directMedian != null) return '直连解析 ${directMedian}ms';
    if (tunnelMedian != null) return '隧道解析 ${tunnelMedian}ms';
    return 'DNS 探测暂时没有拿到有效结果';
  }
}

/// 交叉校验的结论。
enum DnsVerdict {
  /// 还没做过校验。
  unknown,

  /// 国内与隧道答案一致，或差异不足以支撑结论。
  consistent,

  /// 国内答案在国内、隧道答案在境外——典型的国内外双部署。
  dualStack,

  /// 国内答案不在国内，或与隧道答案完全无关——疑似投毒。
  suspectPoisoning,

  /// 国内解析器整体不可用。
  directResolverDown,

  /// **本机无法执行 DNS 探测**（探测套接字都建不起来），而不是解析器坏了。
  ///
  /// 与 [directResolverDown] 分开的理由很实际：两者的处置方式相反。
  /// 解析器坏了换个解析器有用；而本机不允许建 UDP 套接字时（企业策略、安全软件、
  /// 防火墙规则），换解析器毫无用处——把结论说成前者会让用户一直白折腾。
  probeUnavailable,
}

extension DnsVerdictX on DnsVerdict {
  String get label => switch (this) {
    DnsVerdict.unknown => '尚未校验（连接后会自动校验一次）',
    DnsVerdict.consistent => '一致',
    DnsVerdict.dualStack => '国内外双部署',
    DnsVerdict.suspectPoisoning => '疑似投毒',
    DnsVerdict.directResolverDown => '国内解析异常',
    DnsVerdict.probeUnavailable => '探测不可用',
  };

  String get advice => switch (this) {
    DnsVerdict.unknown => '连接后会自动完成一次校验',
    DnsVerdict.consistent => '域名按规则库判定即可，无需额外干预',
    DnsVerdict.dualStack => '两套答案分别指向国内外节点，按域名判定分流是正确的',
    DnsVerdict.suspectPoisoning => '这类域名直连必然失败，已自动改为走隧道',
    DnsVerdict.directResolverDown => '检查是否被本地 DNS 或运营商劫持，可尝试更换国内解析器',
    DnsVerdict.probeUnavailable =>
      '本机不允许建立 DNS 探测套接字（安全软件或系统策略），这不是节点问题，'
          '也不影响隧道使用；分流与隧道解析照常工作',
  };
}

/// 一次域名交叉校验的原始证据。
class DnsCrossCheck {
  const DnsCrossCheck({
    required this.domain,
    required this.domesticAnswers,
    required this.domesticMillis,
    required this.tunnelAnswers,
    required this.tunnelMillis,
    required this.verdict,
  });

  final String domain;

  final List<String> domesticAnswers;
  final int? domesticMillis;

  final List<String> tunnelAnswers;
  final int? tunnelMillis;

  final DnsVerdict verdict;

  /// 两组答案是否完全不同。
  bool get disjoint {
    if (domesticAnswers.isEmpty || tunnelAnswers.isEmpty) return false;
    final tunnel = tunnelAnswers.toSet();
    return !domesticAnswers.any(tunnel.contains);
  }
}

/// 监测配置。
class DnsMonitorConfig {
  const DnsMonitorConfig({
    required this.domesticServers,
    required this.tunnelProbeUrl,
    this.timeout = const Duration(seconds: 3),
    this.domesticProbeDomain = 'www.baidu.com',
    this.tunnelProbeDomain = 'www.gstatic.com',
  });

  /// 国内解析器地址列表，与内核配置里的 `dns-cn` 系列保持一致。
  final List<String> domesticServers;

  /// 隧道解析器的探测方式：让内核经隧道访问这个地址并计时。
  ///
  /// 用 URL 而不是直接查 DNS，是因为隧道内的解析器由内核托管，
  /// 从外面发 UDP 包查不到；而 `/proxies/{tag}/delay` 会让内核**真的**
  /// 经隧道解析并建立连接，回来的是用户实际感受到的耗时。
  final String tunnelProbeUrl;

  final Duration timeout;

  /// 用于测量「直连解析」的域名。
  ///
  /// 选国内一线站点：它必须被国内解析器秒回，如果它都慢了，
  /// 说明本地 DNS 链路有问题。
  final String domesticProbeDomain;

  /// 用于测量「隧道解析」的域名。选一个只可能经隧道解析的地址。
  final String tunnelProbeDomain;
}

/// 交叉校验的缓存条目。
class _CachedCheck {
  _CachedCheck(this.check, this.expiresAt);

  final DnsCrossCheck check;
  final DateTime expiresAt;
}

/// DNS 监测器。
///
/// 职责边界：只做「测量」和「给结论」，不直接改路由。
/// 由上层（`AutoRouteTable`）根据结论决定要不要调整分流。
class DnsMonitor {
  DnsMonitor({
    required this.config,
    required this.resolver,
    required this.tunnelLatencyProbe,
    CnIpIndex? cnIpIndex,
    this.crossCheckTtl = const Duration(minutes: 10),
    this.windowCapacity = 32,
  }) : cnIpIndex = cnIpIndex ?? CnIpIndex.empty,
       direct = LatencyWindow(capacity: windowCapacity),
       tunnel = LatencyWindow(capacity: windowCapacity);
  final DnsMonitorConfig config;
  final DnsResolver resolver;

  /// 中国 IP 索引。可由上层在异步加载完成后替换。
  CnIpIndex cnIpIndex;

  /// 隧道延迟探测函数：返回经隧道访问 [config.tunnelProbeUrl] 的毫秒数，失败返回 null。
  ///
  /// 做成回调是为了不把 Clash API 的 HTTP 细节耦合进来，也让测试能直接注入。
  final Future<int?> Function() tunnelLatencyProbe;

  /// 同一个域名的交叉校验结果缓存多久。
  final Duration crossCheckTtl;

  final int windowCapacity;

  /// 直连路径的耗时窗口。
  final LatencyWindow direct;

  /// 隧道路径的耗时窗口。
  final LatencyWindow tunnel;

  final Map<String, ResolverHealth> _health = <String, ResolverHealth>{};
  final Map<String, int> _consecutiveFailures = <String, int>{};
  final Map<String, _CachedCheck> _crossChecks = <String, _CachedCheck>{};

  /// 正在进行的交叉校验，按域名去重。
  ///
  /// 失败往往成批出现（节点掉线、某个站点挂了），而每次交叉校验都要发 UDP 查询
  /// 加一次隧道往返。没有这层去重，一批失败会同时拉起几十个探测，
  /// 既互相抢带宽、又把「耗时」测成排队时间，让 DNS 健康度看起来比实际差。
  final Map<String, Future<DnsCrossCheck>> _inFlight =
      <String, Future<DnsCrossCheck>>{};

  DnsVerdict _lastVerdict = DnsVerdict.unknown;
  DateTime? _lastRunAt;
  bool _running = false;

  /// 「国内解析器全部失败」连续出现了几次。
  ///
  /// 用它给「国内解析异常」这条结论加一道门槛：单次失败可能只是丢了一个 UDP 包，
  /// 而界面上它是一条要用户去改设置的重结论。
  int _domesticAllFailedStreak = 0;

  /// 连续几次全失败才认定国内解析真的不可用。
  static const int domesticFailureThreshold = 2;

  /// 正在探测时返回 true。上层据此跳过本轮，避免慢探测把定时器堆起来。
  bool get isRunning => _running;

  DnsReport get report => DnsReport(
    checkedAt: _lastRunAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    resolvers: List<ResolverHealth>.unmodifiable(_health.values),
    direct: direct,
    tunnel: tunnel,
    verdict: _lastVerdict,
  );

  /// 跑一轮完整监测。
  ///
  /// 内部的多个探测彼此独立，但只有直连那一组会占用本地网络；
  /// 它们串行执行而不是并发，是为了让「耗时」这个数字反映真实排队情况，
  /// 并发发 UDP 会让多个解析器互相抢带宽并把耗时测得偏低。
  Future<DnsReport> runOnce() async {
    if (_running) return report;
    _running = true;
    try {
      await _probeDomesticServers();
      await _probeTunnel();
      _lastRunAt = DateTime.now();
      return report;
    } finally {
      _running = false;
    }
  }

  Future<void> _probeDomesticServers() async {
    for (final server in config.domesticServers) {
      final outcome = await resolver.query(
        server,
        config.domesticProbeDomain,
        timeout: config.timeout,
      );
      _record(server, role: '直连', outcome: outcome);
    }
    // 直连路径的耗时取「最快的那台」：国内解析器通常配了两台，
    // 内核也是谁先答应用谁，取最快才与真实体验一致。
    final fastest = <int>[];
    for (final server in config.domesticServers) {
      final millis = _health[server]?.lastMillis;
      if (millis != null) fastest.add(millis);
    }
    if (fastest.isNotEmpty) {
      direct.add(fastest.reduce((int a, int b) => a < b ? a : b));
    }
  }

  Future<void> _probeTunnel() async {
    final millis = await tunnelLatencyProbe();
    if (millis != null && millis > 0) {
      tunnel.add(millis);
      _health['vpn'] = ResolverHealth(
        server: '隧道 DNS',
        role: '隧道',
        samples: (_health['vpn']?.samples ?? 0) + 1,
        failures: _health['vpn']?.failures ?? 0,
        consecutiveFailures: 0,
        lastMillis: millis,
        lastSummary: '${config.tunnelProbeDomain} 可达',
        lastCheckedAt: DateTime.now(),
      );
      return;
    }
    final previous = _health['vpn'];
    final failures = (previous?.consecutiveFailures ?? 0) + 1;
    _health['vpn'] = ResolverHealth(
      server: '隧道 DNS',
      role: '隧道',
      samples: (previous?.samples ?? 0) + 1,
      failures: (previous?.failures ?? 0) + 1,
      consecutiveFailures: failures,
      lastMillis: null,
      lastSummary: '经隧道解析超时',
      lastCheckedAt: DateTime.now(),
    );
  }

  void _record(
    String server, {
    required String role,
    required DnsOutcome outcome,
  }) {
    final previous = _health[server];
    final failuresSoFar = previous?.failures ?? 0;
    final samples = (previous?.samples ?? 0) + 1;

    if (outcome.succeeded) {
      _consecutiveFailures[server] = 0;
      _health[server] = ResolverHealth(
        server: server,
        role: role,
        samples: samples,
        failures: failuresSoFar,
        consecutiveFailures: 0,
        lastMillis: outcome.millis,
        lastSummary: outcome.summary,
        lastCheckedAt: DateTime.now(),
      );
      return;
    }

    final consecutive = (_consecutiveFailures[server] ?? 0) + 1;
    _consecutiveFailures[server] = consecutive;
    _health[server] = ResolverHealth(
      server: server,
      role: role,
      samples: samples,
      failures: failuresSoFar + 1,
      consecutiveFailures: consecutive,
      lastMillis: null,
      lastSummary: outcome.summary,
      lastCheckedAt: DateTime.now(),
    );
  }

  /// 对一个域名做交叉校验：国内解析器 vs 隧道。
  ///
  /// 结果会缓存 [crossCheckTtl]，因为同一个域名短时间内反复校验没有意义，
  /// 而每次校验都要占用一次隧道往返。
  Future<DnsCrossCheck> crossCheck(String domain, {bool force = false}) {
    final cached = _crossChecks[domain];
    if (!force && cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return Future<DnsCrossCheck>.value(cached.check);
    }
    // 同一个域名已经有探测在跑时直接复用它的 Future。
    final pending = _inFlight[domain];
    if (pending != null) return pending;

    final future = _runCrossCheck(domain);
    _inFlight[domain] = future;
    // 无论成功失败都要摘掉登记，否则一次异常会让这个域名永远返回同一个失败的
    // Future，之后再也不会重新探测。
    return future.whenComplete(() {
      _inFlight.remove(domain);
    });
  }

  Future<DnsCrossCheck> _runCrossCheck(String domain) async {
    // 1) 国内解析器：逐个查，取第一个成功的答案。
    var domesticAnswers = const <String>[];
    int? domesticMillis;
    var domesticAllFailed = true;
    // 所有失败是否都属于「本机建不出探测套接字」。只有全失败时才有意义。
    var domesticAllLocalFailure = true;
    if (config.domesticServers.isNotEmpty) {
      for (final server in config.domesticServers) {
        final outcome = await resolver.query(
          server,
          domain,
          timeout: config.timeout,
        );
        _record(server, role: '直连', outcome: outcome);
        if (outcome.succeeded) domesticAllFailed = false;
        if (!outcome.localProbeUnavailable) domesticAllLocalFailure = false;
        if (outcome.resolved) {
          domesticAnswers = outcome.answers;
          domesticMillis = outcome.millis;
          break;
        }
      }
      // 一个都没配或全失败时，domesticAllFailed 仍然为真。
      domesticAllFailed = domesticAllFailed && domesticAnswers.isEmpty;
      domesticAllLocalFailure = domesticAllFailed && domesticAllLocalFailure;
    }
    // 记录连续全失败次数：结论的门槛依赖它（见 [_classify]）。
    _domesticAllFailedStreak = domesticAllFailed
        ? _domesticAllFailedStreak + 1
        : 0;

    // 2) 隧道侧：让内核经隧道解析同一个域名。
    final tunnelMillis = await tunnelLatencyProbe();
    final tunnelAnswers = await _resolveViaTunnel(domain);
    if (tunnelMillis != null && tunnelMillis > 0) tunnel.add(tunnelMillis);

    final verdict = _classify(
      domesticAnswers: domesticAnswers,
      tunnelAnswers: tunnelAnswers,
      domesticAllFailed: domesticAllFailed,
      domesticAllLocalFailure: domesticAllLocalFailure,
    );
    _lastVerdict = verdict;

    final check = DnsCrossCheck(
      domain: domain,
      domesticAnswers: domesticAnswers,
      domesticMillis: domesticMillis,
      tunnelAnswers: tunnelAnswers,
      tunnelMillis: tunnelMillis,
      verdict: verdict,
    );
    _crossChecks[domain] = _CachedCheck(
      check,
      DateTime.now().add(crossCheckTtl),
    );
    return check;
  }

  /// 经隧道解析域名。
  ///
  /// 默认实现返回空列表：这一路需要内核的 `/dns/query` 接口，由上层注入。
  /// 之所以留一个可覆盖的钩子而不是直接写 HTTP，是为了让 `DnsMonitor`
  /// 本身保持可单测。
  Future<List<String>> _resolveViaTunnel(String domain) async {
    final probe = tunnelResolveProbe;
    if (probe == null) return const <String>[];
    try {
      return await probe(domain);
    } on Object {
      return const <String>[];
    }
  }

  /// 经内核 DNS 模块解析域名的钩子。返回解析出的地址列表。
  Future<List<String>> Function(String domain)? tunnelResolveProbe;

  DnsVerdict _classify({
    required List<String> domesticAnswers,
    required List<String> tunnelAnswers,
    required bool domesticAllFailed,
    bool domesticAllLocalFailure = false,
  }) {
    if (domesticAllFailed) {
      // 先区分「本机探测跑不起来」与「解析器真的不通」——两者的处置方式相反。
      if (domesticAllLocalFailure) return DnsVerdict.probeUnavailable;
      // 单次失败不足以定性「国内解析异常」。
      //
      // 这里的探测是明文 UDP，丢一个包就会走到这条分支；而界面上它是一条**醒目
      // 的异常结论**，用户会照它去改解析器设置。要求连续两次全失败才下结论：
      // 真坏掉的解析器两次都失败，偶发丢包则几乎不会。
      final consecutive = _domesticAllFailedStreak;
      if (consecutive < domesticFailureThreshold) {
        // 还不到阈值：不下异常结论，交给下面的地理比对给出正常结论。
        return DnsVerdict.consistent;
      }
      return DnsVerdict.directResolverDown;
    }
    if (domesticAnswers.isEmpty) return DnsVerdict.consistent;

    final region = classifyRegion(cnIpIndex, domesticAnswers);
    final disjoint =
        tunnelAnswers.isNotEmpty &&
        !domesticAnswers.any(tunnelAnswers.toSet().contains);

    if (region == AddressRegion.domestic) {
      // 国内解析器给出国内地址：这是最正常的情况。
      // 即便与隧道答案不同，也只是国内外双部署，按域名判定是对的。
      return disjoint ? DnsVerdict.dualStack : DnsVerdict.consistent;
    }
    if (region == AddressRegion.overseas) {
      // 国内解析器给出境外地址：可能是域名本就用境外 CDN，
      // 也可能是被投毒成了别人的地址。只有「与隧道答案也不一样」才能定性。
      return disjoint ? DnsVerdict.suspectPoisoning : DnsVerdict.consistent;
    }
    // 拿不到地理信息（索引缺失或全是 IPv6）时不下结论，
    // 宁可少一次自动纠正，也不要把正常的流量推到隧道里。
    return DnsVerdict.consistent;
  }

  /// 读取缓存的校验结果，不触发新探测。
  DnsCrossCheck? cachedCheck(String domain) => _crossChecks[domain]?.check;

  void reset() {
    _health.clear();
    _consecutiveFailures.clear();
    _crossChecks.clear();
    // 注意不清 _inFlight：里面是已经发出去的探测，它们的完成回调仍会执行，
    // 清掉反而会让同一域名被重复探测。让它们自然跑完即可。
    direct.clear();
    tunnel.clear();
    _lastVerdict = DnsVerdict.unknown;
    _domesticAllFailedStreak = 0;
    _lastRunAt = null;
  }
}
