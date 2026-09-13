/// 分流决策表：**域名走向的唯一决策来源**。
///
/// 表里的每一条都是「这个域名走隧道还是直连」，来源有三类，优先级
/// 用户 > 学到 > 预置（见 [RouteRuleSourceX.rank]）：
///
///   * **用户手工指定**（`user`）——用户的明确决定，永不被程序改写；
///   * **程序学到**（`learned`）——从证据里自动纠正，两个方向都会学：
///     直连失败 → 走隧道；直连解析落在国内网段 → 直连；
///   * **内置白名单**（`preset`）——由「直连白名单」开关安装的静态清单
///     （见 `app_presets.dart`）。
///
/// 把它做成**唯一**来源而不是让每条机制各插一段路由规则，是为了让匹配、
/// 优先级、界面展示、DNS 策略、反向纠正的候选过滤全部一致。此前预置是绕过
/// 本表、在配置生成时另插规则的，于是 `match()`、`domain_check`、自动纠正
/// 都看不到它，优先级只能靠配置生成函数里的书写顺序表达——一被重排就是
/// 静默的行为变更。
///
/// 双向学习的理由：内置规则库覆盖不到的长尾情况有两类，而它们都会表现为
/// 「用户完全看不出原因」：
///
///   1. 判为直连的主机解析到 **geoip-cn 内的地址**、却并不真的可达（例如服务
///      由规则集范围内的 CDN 承载）→ 判为直连 → 直连失败。规则库修不了，
///      因为它「正确地」命中了。
///   2. **该直连的域名被判进了隧道**（不在 `geosite-cn` 内）→ 不失败、不报错，
///      只白占隧道带宽、并把访问来源换成境外 IP。这一类的证据是 DNS 事实：
///      该域名的直连解析落在国内网段内。
///
/// 设计上刻意保守：
///   * 只有**域名**会被学习，IP 目标一律不动——IP 层面的失败与按域名的规则无关；
///   * 需要**连续多次**独立证据才纠正，单次抖动不会改路由；
///   * 两个方向互为反证：一次直连失败会清零「该直连」的连续计数；
///   * 表有容量上限，且会随时间衰减，不会变成一个只增不减的黑名单。
library;

import 'app_presets.dart';
import 'outbound_tags.dart';
import 'route_learning.dart';

/// 把本模块的词汇一并转出：`RoutePreference` / `RouteRuleSource` 是分流规则与
/// 学习策略**共用**的词汇，调用方（界面、内核配置生成、各测试）一直从本文件
/// 引入它们。转出而不是让每个调用方多一行 import，是为了让这次拆分对它们是
/// 透明的。
export 'route_learning.dart'
    show
        DirectOutcome,
        EvidenceKind,
        LearningPolicy,
        OutcomeThrottle,
        RoutePreference,
        RoutePreferenceX,
        RouteRuleSource,
        RouteRuleSourceX,
        judgeSetback,
        shouldRevokeLearnedProxy;


/// 一条尚未定性的「直连没有交付」证据。
///
/// 它还不是规则，因此不放进 `AutoRouteTable._exact`（那会立刻生成路由规则）。
/// 达到阈值后由 [AutoRouteTable._recordDirectSetback] 提升成真正的规则。
class _PendingSetback {
  _PendingSetback({required this.createdAt});

  /// 首次观察到它的时间。提升成规则时沿用，让规则的「存在多久」如实反映观察起点。
  final DateTime createdAt;

  /// 连接失败的次数。
  int failures = 0;

  /// 「握手成功但没有数据」的次数。
  int stalls = 0;

  /// 连续「没有交付」的次数。达到阈值即提升。
  int consecutive = 0;

  /// 最近一次的原因摘要，提升后写进规则供界面展示。
  String? reason;

  /// 最近一次的 DNS 交叉校验结论名。
  String? dnsVerdict;
}

/// 一个域名的交付速率证据（尚未定性，因此还不是规则）。
///
/// 单独存放而不是挂在 [AutoRouteEntry] 上，理由见
/// [AutoRouteTable.recordDeliveryRate]：条目的默认倾向是 `forceProxy`，
/// 为了记证据而建条目会立刻生成一条强制代理规则。
class _RateEvidence {
  _RateEvidence({required this.createdAt});

  /// 首次观察到它的时间。提升成规则时沿用，让规则的「存在多久」如实反映观察起点。
  final DateTime createdAt;

  /// 直连路径上的速率窗口。
  final RollingMedian direct = RollingMedian();

  /// 隧道路径上的速率窗口。
  final RollingMedian proxy = RollingMedian();

  /// 连续「直连偏慢」的次数。
  int directSlowStreak = 0;

  /// 连续「隧道偏慢」的次数。
  int proxySlowStreak = 0;

  /// 最近一次的可读摘要，供界面展示。
  String? note;
}

/// 一条自动纠正规则 + 支撑它的证据。
class AutoRouteEntry {
  AutoRouteEntry({
    required this.domain,
    this.preference = RoutePreference.forceProxy,
    this.source = RouteRuleSource.learned,
    this.createdAt,
    this.lastHitAt,
    this.directFailures = 0,
    this.directSuccesses = 0,
    this.stalls = 0,
    this.consecutiveFailures = 0,
    this.consecutiveSuccesses = 0,
    this.proxiedBytes = 0,
    this.domesticHits = 0,
    this.byRate = false,
    this.rateNote,
    this.dnsVerdict,
    this.lastFailureReason,
  });

  /// 域名。可能是精确域名，也可能是后缀（`example.com` 同时覆盖子域）。
  final String domain;

  final RoutePreference preference;
  final RouteRuleSource source;

  final DateTime? createdAt;

  /// 最近一次「因这条规则而生效」的时间。用于界面排序与说明。
  DateTime? lastHitAt;

  /// 累计「判为直连却失败」的次数。
  int directFailures;

  /// 累计「判为直连且**确实交付了内容**」的观测次数。
  ///
  /// 关键词是「确实交付」。此前这里把「连接跑出过任何字节」都算成功，而实测
  /// （见 [AutoRouteTable.recordDirectStall]）表明失败形态里有「TLS 握手成功、
  /// 随后只漏出几百字节就挂住」——那会被记成成功，于是 `consecutiveFailures`
  /// 被清零、「直连其实能通」这个错误结论被写进证据。
  /// 现在只有字节数达到 `CoreMonitor.substantiveByteFloor` 的观测才会走到这里。
  int directSuccesses;

  /// 累计「握手成功但没有交付内容」的次数。
  ///
  /// 这是实测里最常见、而原实现**完全看不见**的失败形态：日志里没有 `ERROR` 行
  /// （所以失败归因抓不到），又有零星字节（所以也不算成功），于是既不推动学习、
  /// 也不构成反证——一个 40% 成功率的域名因此在学习表里永远静默。
  ///
  /// 对分流决策而言它与 [directFailures] 同类：直连这条路没有交付内容。
  int stalls;

  /// 连续「直连没有交付」的次数（含连接失败与 [stalls]）。达到阈值才改判走隧道。
  int consecutiveFailures;

  /// 连续「确实交付」的次数。用于**撤销**学到的强制代理规则。
  ///
  /// 为什么需要它，而不是沿用「累计成功 2 次即撤销」：
  ///
  /// 实测 github.com 在 10 次尝试里呈「成功 / 连续失败 4 次 / 成功 / 连续失败 3 次 /
  /// 成功」——即在坏时段里**失败是成簇的，而成功偶尔插进来**。用累计计数，两次
  /// 侥幸成功就足以撤销刚刚学到的强制代理规则，于是规则被反复推翻又重建，用户
  /// 看到的是「分流时好时坏」。改用**连续**计数后，交替出现的成败永远攒不满阈值，
  /// 规则因此稳定；而网络真的恢复时连续成功会很快攒够并撤销——迟滞是自动的。
  int consecutiveSuccesses;

  /// 走隧道时累计的字节数。用来判断「改成代理以后确实在用」。
  int proxiedBytes;

  /// 这条强制代理规则是**因为交付速率偏慢**而学到的。
  ///
  /// 必须与「因为直连失败而学到」区分开，因为两者的**回滚条件不同**：
  ///
  ///   * 失败学到的：直连**连不上**，因此绝不能因为隧道也慢就把它放回直连；
  ///   * 速率学到的：直连**能连但慢**，所以若隧道同样慢，说明问题不在路径上，
  ///     应当放回直连（省下隧道带宽）并进入冷却。
  ///
  /// 若不做这个区分，一次「隧道也慢」的回滚会把那些本来就连不上的域名放回直连，
  /// 那是明确的错误。
  bool byRate;

  /// 最近一次速率判定的可读摘要，供界面展示。
  ///
  /// 与 [lastFailureReason] 分开：速率偏慢**不是失败**（连接成功交付了内容），
  /// 把它记成失败原因会让界面上出现「判为直连但失败 0 次 · 速率偏慢」这种
  /// 自相矛盾的说法。
  String? rateNote;

  /// 直连解析结果落在国内网段（`geoip-cn` 前缀索引内）的次数。  ///
  /// 这是**反方向**（把走隧道的域名改成直连）的证据，与 [directFailures] 方向相反。
  /// 之所以需要它：本程序是白名单式直连，不在 `geosite-cn` 内的域名必然进隧道，
  /// 而 `geoip-cn` 不参与域名目标的判定（见 `docs/RULES.md` 的实测）。因此
  /// 「该直连却走了隧道」既不失败、也不报错，此前没有任何证据可用于发现它。
  ///
  /// 直连解析给出国内地址，是这个域名属于国内站点的一个确定性证据——它是 DNS
  /// 事实，不是猜测。但仍然要求**连续多次**才改判：单一解析器的答案会随 CDN
  /// 调度变化，而一次误判会把本该走隧道的流量推去直连。
  ///
  /// 任何一次直连失败都会把它清零（见 [recordDomesticAnswer] 的调用方约定与
  /// [recordDirectFailure]）：反证优先，且能防止两个方向反复翻转。
  int domesticHits;

  /// 最近一次 DNS 交叉校验的结论名（见 `DnsVerdict`）。
  String? dnsVerdict;

  /// 最近一次失败原因摘要，展示在界面上供用户判断。
  String? lastFailureReason;

  /// 规则对该域名的匹配宽度。精确匹配优于后缀匹配。
  bool matches(String host) {
    if (host.isEmpty) return false;
    if (host == domain) return true;
    // 后缀匹配必须落在标签边界上：`notexample.com` 不该被 `example.com` 命中。
    return host.length > domain.length &&
        host.endsWith(domain) &&
        host[host.length - domain.length - 1] == '.';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'domain': domain,
    'preference': preference.storageKey,
    'source': source.name,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (lastHitAt != null) 'lastHitAt': lastHitAt!.toIso8601String(),
    'directFailures': directFailures,
    'directSuccesses': directSuccesses,
    'stalls': stalls,
    'consecutiveFailures': consecutiveFailures,
    'consecutiveSuccesses': consecutiveSuccesses,
    'proxiedBytes': proxiedBytes,
    'domesticHits': domesticHits,
    if (byRate) 'byRate': true,
    if (rateNote != null) 'rateNote': rateNote,
    if (dnsVerdict != null) 'dnsVerdict': dnsVerdict,
    if (lastFailureReason != null) 'lastFailureReason': lastFailureReason,
  };

  static AutoRouteEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final domain = json['domain']?.toString() ?? '';
    if (domain.isEmpty) return null;
    return AutoRouteEntry(
      domain: domain,
      preference: json['preference'] == 'direct'
          ? RoutePreference.forceDirect
          : RoutePreference.forceProxy,
      // 预置是随代码分发的，不从存档恢复：它由「直连白名单」的开关驱动，
      // 存档里出现 preset 来源（旧版本写入或手工编辑）一律降级成「程序学到」，
      // 免得一条没有开关对应的条目永久留在表里。
      source: switch (json['source']) {
        'user' => RouteRuleSource.user,
        'preset' => RouteRuleSource.learned,
        _ => RouteRuleSource.learned,
      },
      createdAt: _time(json['createdAt']),
      lastHitAt: _time(json['lastHitAt']),
      directFailures: (json['directFailures'] as num?)?.toInt() ?? 0,
      directSuccesses: (json['directSuccesses'] as num?)?.toInt() ?? 0,
      // 旧存档没有这两个键：`stalls` 从 0 起算（它记录的是新引入的观测），
      // `consecutiveSuccesses` 也从 0 起——宁可让撤销多等几次，
      // 也不要凭一个不存在的历史立刻撤销一条正在起作用的规则。
      stalls: (json['stalls'] as num?)?.toInt() ?? 0,
      consecutiveFailures: (json['consecutiveFailures'] as num?)?.toInt() ?? 0,
      consecutiveSuccesses: (json['consecutiveSuccesses'] as num?)?.toInt() ?? 0,
      proxiedBytes: (json['proxiedBytes'] as num?)?.toInt() ?? 0,
      domesticHits: (json['domesticHits'] as num?)?.toInt() ?? 0,
      // 旧存档没有这个键：按「不是因为速率学到的」处理。宁可让一条速率规则
      // 享受不到回滚（最坏只是白走隧道），也不要凭一个不存在的标记把一条
      // **因为直连失败**而学到的规则放回直连——那是明确的功能回退。
      byRate: json['byRate'] as bool? ?? false,
      rateNote: json['rateNote']?.toString(),
      dnsVerdict: json['dnsVerdict']?.toString(),
      lastFailureReason: json['lastFailureReason']?.toString(),
    );
  }

  static DateTime? _time(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

/// 一条规则为什么被加进来。用于界面解释与日志。
class AutoRouteDecision {
  const AutoRouteDecision({
    required this.domain,
    required this.added,
    required this.reason,
    this.entry,
  });

  final String domain;

  /// true 表示这次调用**新增**了规则（而不是更新已有规则）。
  final bool added;

  final String reason;

  final AutoRouteEntry? entry;
}

/// 自动纠正表。
///
/// 查找是「后缀索引 + 精确匹配」而不是遍历整张表：连接列表每秒都在刷新，
/// 而纠正表最多会有几百条，逐条 `endsWith` 在每帧的成本不可接受。
/// 索引按「去掉最后一级标签」归档，因此对 `a.b.example.com` 最多只需要看
/// 4 个桶，与表的大小无关。
class AutoRouteTable {
  /// [policy] 是所有学习策略参数（阈值、判据、限流）的唯一来源，见
  /// `route_learning.dart`。三个具名参数是**测试与嵌入方的便捷覆盖**：它们会
  /// 覆盖策略里的对应字段，而不是另开一份事实来源。
  AutoRouteTable({
    LearningPolicy policy = const LearningPolicy(),
    int? capacity,
    int? promotionThreshold,
    int? domesticPromotionThreshold,
    int? revokeSuccessThreshold,
    Duration? decayAfter,
  }) : policy = LearningPolicy(
         promotionThreshold: promotionThreshold ?? policy.promotionThreshold,
         domesticPromotionThreshold:
             domesticPromotionThreshold ?? policy.domesticPromotionThreshold,
         revokeSuccessThreshold:
             revokeSuccessThreshold ?? policy.revokeSuccessThreshold,
         substantiveByteFloor: policy.substantiveByteFloor,
         stallFloor: policy.stallFloor,
         outcomeWindow: policy.outcomeWindow,
         capacity: capacity ?? policy.capacity,
         decayAfter: decayAfter ?? policy.decayAfter,
         maxPendingEvidence: policy.maxPendingEvidence,
         maxOutcomeLog: policy.maxOutcomeLog,
       );

  /// 学习策略。阈值与判据都从它读，本类不再自带一份。
  final LearningPolicy policy;

  /// 表容量上限。便捷读取，等价于 `policy.capacity`。
  int get capacity => policy.capacity;

  /// 多久没有任何新证据就淘汰。便捷读取，等价于 `policy.decayAfter`。
  Duration get decayAfter => policy.decayAfter;

  /// 精确域名 → 条目。
  final Map<String, AutoRouteEntry> _exact = <String, AutoRouteEntry>{};

  /// 「去掉最后一级标签」→ 后缀规则条目集。
  ///
  /// 例：规则 `example.com` 归档到键 `com`，规则 `example.co.uk` 归档到键 `co.uk`。
  final Map<String, List<AutoRouteEntry>> _suffixBuckets =
      <String, List<AutoRouteEntry>>{};

  /// 尚未定性的「直连解析落在国内网段」连续计数。
  ///
  /// 与 [_exact] 分开是刻意的：这些还**不是规则**，只是证据。放进 [_exact]
  /// 会立刻生成路由规则，而方向正好是反的（见 [recordDomesticAnswer]）。
  final Map<String, int> _domesticStreak = <String, int>{};

  /// 尚未定性的「直连没有交付」证据（连接失败与挂死都算）。
  ///
  /// 同样与 [_exact] 分开，理由更硬：`AutoRouteEntry` 的默认 `preference` 是
  /// [RoutePreference.forceProxy]，一旦装进 [_exact]，`buildRouteRules()` 立刻会
  /// 为它生成一条「强制走隧道」的规则——于是写在 [promotionThreshold] 上的
  /// 「连续 3 次才纠正」实际变成了「1 次就生效」。文档与代码在这里是矛盾的，
  /// 而矛盾的方向是**更激进**（一次抖动就把域名推进隧道），正是本文件开头
  /// 说要避免的那种「分流时好时坏」。
  ///
  /// 因此未定性的证据先攒在这里，达到阈值才变成规则。两个方向（失败→代理、
  /// 国内解析→直连）现在用的是同一种做法。
  ///
  /// 不落盘：它还不是规则，不该在用户看不见的地方积累状态。代价是重启后要
  /// 重新数几次，而这个代价是刻意的。
  final Map<String, _PendingSetback> _pendingSetbacks =
      <String, _PendingSetback>{};

  /// 未定性证据的条数上限。超过就整表清空——它只影响「再数几次」的成本。
  static const int maxPendingSetbacks = 200;

  /// 未定性证据的上界。超过就整表清空，理由见 [_rememberDomesticStreak]。
  static const int maxPendingDomesticEvidence = 200;

  int get length => _exact.length;

  bool get isEmpty => _exact.isEmpty;

  Iterable<AutoRouteEntry> get entries => _exact.values;

  /// 用户手工指定一条规则。永远覆盖程序学到的规则。
  AutoRouteDecision setUserRule(String domain, RoutePreference preference) {
    final normalized = normalizeDomain(domain);
    if (normalized.isEmpty) {
      return AutoRouteDecision(domain: domain, added: false, reason: '域名不合法');
    }
    final existing = _exact[normalized];
    final entry = AutoRouteEntry(
      domain: normalized,
      preference: preference,
      source: RouteRuleSource.user,
      createdAt: existing?.createdAt ?? DateTime.now(),
      lastHitAt: existing?.lastHitAt,
      directFailures: existing?.directFailures ?? 0,
      directSuccesses: existing?.directSuccesses ?? 0,
      stalls: existing?.stalls ?? 0,
      consecutiveFailures: existing?.consecutiveFailures ?? 0,
      consecutiveSuccesses: existing?.consecutiveSuccesses ?? 0,
      proxiedBytes: existing?.proxiedBytes ?? 0,
      dnsVerdict: existing?.dnsVerdict,
      lastFailureReason: existing?.lastFailureReason,
    );
    _install(entry);
    return AutoRouteDecision(
      domain: normalized,
      added: existing == null,
      reason: '用户指定为${preference.label}',
      entry: entry,
    );
  }

  /// 用户移除一条规则（含程序学到的）。
  bool remove(String domain) {
    final normalized = normalizeDomain(domain);
    if (!_exact.containsKey(normalized)) return false;
    _uninstall(normalized);
    return true;
  }

  /// 安装或卸载一个「直连白名单」预置。
  ///
  /// 预置走的是**同一条**决策模型（而不是在配置生成时另插一段规则），因此
  /// 匹配、优先级、界面展示、反向纠正的候选过滤全都自动一致。这是把两套平行
  /// 机制收敛成一套的关键一步：此前预置绕过本表，导致
  /// `match()` / `domain_check` / 自动纠正都看不到它们，优先级只能靠
  /// 配置生成函数里的书写顺序表达。
  ///
  /// 唯一注意点：安装时**不覆盖**优先级更高的条目。否则每次重启重新安装预置，
  /// 都会把运行中学到的纠正（例如某个预置域名直连连不通、已被改成走隧道）
  /// 悄悄抹掉——那是「学一次、以后都记得」这个承诺的反例。
  void setPreset(AppPreset preset, {required bool enabled}) {
    if (!enabled) {
      for (final domain in <String>[
        ...preset.directDomains,
        ...preset.tunnelExceptions,
      ]) {
        final normalized = normalizeDomain(domain);
        final entry = _exact[normalized];
        if (entry != null && entry.source == RouteRuleSource.preset) {
          _uninstall(normalized);
        }
      }
      return;
    }

    void install(String domain, RoutePreference preference) {
      final normalized = normalizeDomain(domain);
      if (normalized.isEmpty) return;
      final existing = _exact[normalized];
      // 学到/手工指定的条目优先，预置不覆盖它们。
      if (existing != null && existing.source != RouteRuleSource.preset) {
        return;
      }
      _install(
        AutoRouteEntry(
          domain: normalized,
          preference: preference,
          source: RouteRuleSource.preset,
          createdAt: existing?.createdAt ?? DateTime.now(),
          directFailures: existing?.directFailures ?? 0,
          directSuccesses: existing?.directSuccesses ?? 0,
          stalls: existing?.stalls ?? 0,
          consecutiveFailures: existing?.consecutiveFailures ?? 0,
          consecutiveSuccesses: existing?.consecutiveSuccesses ?? 0,
          proxiedBytes: existing?.proxiedBytes ?? 0,
          domesticHits: existing?.domesticHits ?? 0,
        ),
      );
    }

    // 例外先装：它最终会排在直连规则之前（生成规则时所有走隧道的规则在前），
    // 这里先装只是为了让两条都进表，顺序由 [buildRouteRules] 决定。
    for (final domain in preset.tunnelExceptions) {
      install(domain, RoutePreference.forceProxy);
    }
    for (final domain in preset.directDomains) {
      install(domain, RoutePreference.forceDirect);
    }
  }

  /// 记录一次「判为直连却失败」。
  ///
  /// [dnsVerdict] 来自 DNS 交叉校验（`DnsVerdict.name`）。为
  /// `suspectPoisoning` 时阈值降为 1：解析结果不一致是确定性证据，不需要再等两次。
  AutoRouteDecision recordDirectFailure(
    String host, {
    String? reason,
    String? dnsVerdict,
  }) => _recordDirectSetback(
    host,
    reason: reason,
    dnsVerdict: dnsVerdict,
    stalled: false,
  );

  /// 记录一次「直连握手成功但**没有交付内容**」。
  ///
  /// 这是实测里最常见、而原先完全看不见的一类失败：TLS 握手只用几百毫秒就完成，
  /// 随后连接活着 8–10 秒却只交付 0 字节（或零星几百字节）。它为什么看不见：
  ///
  ///   * 失败归因只解析含 `ERROR` 的日志行（`core_log.dart`），而这条路径没有
  ///     `ERROR`——连接是「建立成功」的，只是没有数据；
  ///   * 它又有零星字节，于是按「跑出过流量就算成功」的旧判据会被记成**成功**，
  ///     把 `consecutiveFailures` 清零。
  ///
  /// 对分流决策而言它与连接失败同类：**直连这条路交付不了内容**。因此这里把它
  /// 计入同一个连续失败计数，只是单独记在 [AutoRouteEntry.stalls] 里，
  /// 好让界面上能区分「连不上」与「连上了但没数据」。
  AutoRouteDecision recordDirectStall(String host, {String? reason}) =>
      _recordDirectSetback(host, reason: reason, stalled: true);

  /// 失败与挂死的共同处理。
  ///
  /// 两者对决策的影响完全一致（都说明直连没有交付），差异只在记到哪个计数、
  /// 以及界面上的说法。因此共用一条路径。
  ///
  /// **判断本身不在这里**：阈值与「累计到多少才改判」由 `route_learning.dart` 的
  /// [judgeSetback] 给出（纯函数），本方法只负责把结论落到表上。
  AutoRouteDecision _recordDirectSetback(
    String host, {
    String? reason,
    String? dnsVerdict,
    required bool stalled,
  }) {
    final domain = normalizeDomain(host);
    if (domain.isEmpty) {
      return AutoRouteDecision(domain: host, added: false, reason: '目标不是域名');
    }
    // 反证优先：一次「没有交付」就把「直连解析落在国内」的连续计数清零。
    //
    // 不做这一步会来回翻转——被改成 forceProxy 之后，残留的计数会让下一次正面
    // 解析立刻又把它改回 forceDirect，用户看到的是分流「时好时坏」。
    _domesticStreak.remove(domain);

    final poisoned = dnsVerdict == 'suspectPoisoning';
    final existing = _exact[domain];

    if (existing != null) {
      if (stalled) {
        existing.stalls++;
      } else {
        existing.directFailures++;
      }
      existing.consecutiveFailures++;
      // 一次「没有交付」就清零连续成功：撤销规则必须靠**连续**的正常交付，
      // 而不是累计几次侥幸成功（见 [AutoRouteEntry.consecutiveSuccesses]）。
      existing.consecutiveSuccesses = 0;
      if (reason != null) existing.lastFailureReason = reason;
      if (dnsVerdict != null) existing.dnsVerdict = dnsVerdict;

      // 用户已经显式指定过的规则不参与自动改写。
      if (existing.source == RouteRuleSource.user) {
        _install(existing);
        return AutoRouteDecision(
          domain: domain,
          added: false,
          reason: '已有用户规则（${existing.preference.label}），仅记录失败',
          entry: existing,
        );
      }

      final verdict = judgeSetback(
        policy: policy,
        consecutiveFailures: existing.consecutiveFailures,
        currentPreference: existing.preference,
        stalled: stalled,
        poisoned: poisoned,
      );
      if (!verdict.promote) {
        _install(existing);
        return AutoRouteDecision(
          domain: domain,
          added: false,
          reason: verdict.reason,
          entry: existing,
        );
      }
      final promoted = AutoRouteEntry(
        domain: domain,
        preference: RoutePreference.forceProxy,
        source: RouteRuleSource.learned,
        createdAt: existing.createdAt ?? DateTime.now(),
        lastHitAt: DateTime.now(),
        directFailures: existing.directFailures,
        directSuccesses: existing.directSuccesses,
        stalls: existing.stalls,
        consecutiveFailures: existing.consecutiveFailures,
        consecutiveSuccesses: 0,
        proxiedBytes: existing.proxiedBytes,
        dnsVerdict: existing.dnsVerdict,
        lastFailureReason: existing.lastFailureReason,
      );
      _install(promoted);
      return AutoRouteDecision(
        domain: domain,
        added: true,
        reason: verdict.reason,
        entry: promoted,
      );
    }

    // 还没有规则：证据先攒在待定区，达到阈值才建规则（见 [_pendingSetbacks]）。
    final pending = _pendingSetbacks.putIfAbsent(
      domain,
      () => _PendingSetback(createdAt: DateTime.now()),
    );
    if (stalled) {
      pending.stalls++;
    } else {
      pending.failures++;
    }
    pending.consecutive++;
    if (reason != null) pending.reason = reason;
    if (dnsVerdict != null) pending.dnsVerdict = dnsVerdict;

    final verdict = judgeSetback(
      policy: policy,
      consecutiveFailures: pending.consecutive,
      currentPreference: null,
      stalled: stalled,
      poisoned: poisoned,
    );
    if (!verdict.promote) {
      _enforcePendingCapacity();
      return AutoRouteDecision(
        domain: domain,
        added: false,
        reason: verdict.reason,
      );
    }

    _pendingSetbacks.remove(domain);
    final promoted = AutoRouteEntry(
      domain: domain,
      preference: RoutePreference.forceProxy,
      source: RouteRuleSource.learned,
      createdAt: pending.createdAt,
      lastHitAt: DateTime.now(),
      directFailures: pending.failures,
      stalls: pending.stalls,
      consecutiveFailures: pending.consecutive,
      dnsVerdict: pending.dnsVerdict,
      lastFailureReason: pending.reason,
    );
    _install(promoted);
    return AutoRouteDecision(
      domain: domain,
      added: true,
      reason: verdict.reason,
      entry: promoted,
    );
  }

  /// 未定性证据超限时整表清空，避免它随会话无限增长。
  void _enforcePendingCapacity() {
    if (_pendingSetbacks.length > policy.maxPendingEvidence) {
      _pendingSetbacks.clear();
    }
  }

  /// 记录一次交付速率观测，并在证据足够时改判路由。
  ///
  /// 这是继「失效」与「挂死」之后的第三种证据，补的是**「能通但很慢」**——
  /// 前两者都是二值判据，抓不住「交付了 50 KB 却用了 30 秒」。
  ///
  /// ## 为什么基准是「本机整体水平」
  ///
  /// 绝对速率没有意义：实测本机国内基线只有 337 KB/s，而同一批测量里
  /// github.com 的成功样本是 125–760 KB/s。因此判据是相对值——该域名相对
  /// **全session 所有实质连接的中位数**。
  ///
  /// 刻意**不做**「同一域名直连 vs 隧道的跨时对比」：实测 github.com 在 40 分钟内
  /// 从 40% 成功率变成 100%，两次测量根本不在同一条件下，那种对比得到的是
  /// 「当时网络好不好」而不是「哪条路更适合这个域名」。
  ///
  /// ## 两个方向
  ///
  /// * 直连偏慢 → 学到 `forceProxy`（试走隧道），并标上 [AutoRouteEntry.byRate]；
  /// * 隧道同样偏慢 → 说明问题**不在路径上**，撤销并进入冷却，
  ///   省下隧道带宽。只有 [AutoRouteEntry.byRate] 的规则会走这一步——
  ///   因为直连失败而学到的规则**绝不能**放回直连。
  ///
  /// [now] 可注入，便于测试冷却与窗口语义。
  AutoRouteDecision? recordDeliveryRate(
    String host, {
    required bool direct,
    required int bytes,
    required Duration duration,
    DateTime? now,
  }) {
    // 样本不够格：不计入统计也不下结论。
    if (!policy.isRateSampleMeaningful(bytes)) return null;
    final rate = LearningPolicy.bytesPerSecond(bytes, duration);
    if (rate == null) return null;

    final domain = normalizeDomain(host);
    if (domain.isEmpty) return null;
    final at = now ?? DateTime.now();

    // 本机整体水平：全session、两条路径都算。用中位数以抗住单次异常样本。
    _linkRates.add(rate);

    final evidence = _rateEvidence.putIfAbsent(
      domain,
      () => _RateEvidence(createdAt: at),
    );
    final window = direct ? evidence.direct : evidence.proxy;
    window.add(rate);

    final existing = _exact[domain];

    // 用户已经指定过走向：只记证据，不改写。
    if (existing != null && existing.source == RouteRuleSource.user) {
      return null;
    }

    final verdict = policy.judgeDeliveryRate(
      domainMedian: window.median,
      linkMedian: _linkRates.median,
      linkSamples: _linkRates.length,
    );
    // 连续计数：只有**连续**偏慢或**连续**正常才改变状态，
    // 中间插进一个正常样本就清零（与失败/成功的连续计数同一套迟滞思想）。
    if (verdict == RateVerdict.slow) {
      if (direct) {
        evidence.directSlowStreak++;
      } else {
        evidence.proxySlowStreak++;
      }
    } else if (verdict == RateVerdict.healthy) {
      if (direct) {
        evidence.directSlowStreak = 0;
      } else {
        evidence.proxySlowStreak = 0;
      }
    }

    final linkMedian = _linkRates.median;
    final domainMedian = window.median;
    final note = _rateNote(
      direct: direct,
      domainMedian: domainMedian,
      linkMedian: linkMedian,
    );
    evidence.note = note;

    // 方向一：隧道上同样偏慢 → 问题不在路径上，放回直连并冷却。
    // 只对**因为速率**学到的规则这样做：因为直连失败而学到的规则放回直连
    // 是明确的错误（它在那里连不上）。
    if (!direct &&
        existing != null &&
        existing.byRate &&
        existing.preference == RoutePreference.forceProxy &&
        evidence.proxySlowStreak >= policy.slowSamplesNeeded) {
      _uninstall(domain);
      _rateRetryAt[domain] = at;
      _pruneRateRetry(now: at);
      return AutoRouteDecision(
        domain: domain,
        added: false,
        reason: '隧道上交付速率同样偏慢，已放回直连（问题不在路径上）',
      );
    }

    // 方向二：直连持续偏慢 → 试走隧道。
    if (direct &&
        evidence.directSlowStreak >= policy.slowSamplesNeeded &&
        policy.rateTrialAllowed(
          now: at,
          lastTrialAt: _rateRetryAt[domain],
        )) {
      final promoted = AutoRouteEntry(
        domain: domain,
        preference: RoutePreference.forceProxy,
        source: RouteRuleSource.learned,
        createdAt: existing?.createdAt ?? evidence.createdAt,
        lastHitAt: at,
        directFailures: existing?.directFailures ?? 0,
        directSuccesses: existing?.directSuccesses ?? 0,
        stalls: existing?.stalls ?? 0,
        consecutiveFailures: existing?.consecutiveFailures ?? 0,
        consecutiveSuccesses: existing?.consecutiveSuccesses ?? 0,
        proxiedBytes: existing?.proxiedBytes ?? 0,
        domesticHits: existing?.domesticHits ?? 0,
        byRate: true,
        rateNote: note,
        dnsVerdict: existing?.dnsVerdict,
        lastFailureReason: existing?.lastFailureReason,
      );
      _install(promoted);
      return AutoRouteDecision(
        domain: domain,
        added: true,
        reason:
            '连续 ${evidence.directSlowStreak} 次直连交付速率明显偏低，已试走隧道',
        entry: promoted,
      );
    }

    // 证据还不够：只更新展示用的摘要，**不建规则**。
    if (existing != null) {
      existing.rateNote = note;
      _install(existing);
    }
    return null;
  }

  /// 速率判定的可读摘要，供界面展示。
  static String? _rateNote({
    required bool direct,
    required double? domainMedian,
    required double? linkMedian,
  }) {
    if (domainMedian == null || linkMedian == null) return null;
    final path = direct ? '直连' : '隧道';
    // 显示时换算成 KB/s：内部用字节/秒，而界面上的量级用 KB 更好读。
    return '$path交付速率 ≈ ${(domainMedian / 1024).round()} KB/s'
        '（本机中位 ${(linkMedian / 1024).round()} KB/s）';
  }

  /// 冷却表：某个域名上次「试走隧道后回滚」的时刻。
  ///
  /// 只在内存里：它的唯一用途是防止短时间内的来回横跳，跨重启保留没有意义
  /// （重启本身就是一次重置，而用户也不会在几秒内重启）。
  final Map<String, DateTime> _rateRetryAt = <String, DateTime>{};

  /// 尚未定性、也还不是规则的交付速率证据。
  ///
  /// 与 [_pendingSetbacks] 同一个理由单独存放：`AutoRouteEntry` 的默认
  /// `preference` 是 `forceProxy`，为了记证据而建条目会立刻生成一条强制代理规则，
  /// 于是「连续 3 次偏慢才试走隧道」就变成了「1 次就生效」。
  final Map<String, _RateEvidence> _rateEvidence = <String, _RateEvidence>{};

  /// 冷却表的容量上限。达到上限时清掉已过冷期的条目。
  static const int maxRateRetryEntries = 200;

  /// 清掉已经过了冷期的条目，避免只增不减。
  void _pruneRateRetry({required DateTime now}) {
    if (_rateRetryAt.length < maxRateRetryEntries) return;
    _rateRetryAt.removeWhere(
      (String _, DateTime at) => now.difference(at) >= policy.rateRetryCooldown,
    );
  }

  /// 本机整体交付速率水平（全session、两条路径的中位数）。
  ///
  /// 这是「偏慢」的基准。用中位数而不是均值：一次 3 秒超时能把均值拉低一倍以上，
  /// 而中位数几乎不受影响——与 DNS 监测的耗时统计同一条理由。
  final RollingMedian _linkRates = RollingMedian(capacity: 64);

  /// 当前的基准值（字节/秒）。尚未建立时为 null。
  double? get linkRateReference => _linkRates.median;

  /// 记录一次「判为直连且**确实交付了内容**」。
  ///
  /// 返回 bool 而不是 void 是为了让上层能正确地去重：只有**确实记录成功**时
  /// 才该把这个域名标记为「已处理过」。
  ///
  /// 「确实交付」由调用方保证（见 `CoreMonitor` 的字节下限判据）：只有字节数够
  /// 说明连接真的把内容送出来了才算。此前只要连接跑出过任何字节就走到这里，
  /// 于是「TLS 通了、漏出几百字节、然后挂住」会被记成成功——那正是实测里最常见
  /// 的失败形态，却被当成了「直连没问题」的证据。
  ///
  /// 这是反证：直连既然把内容交付出来了，就说明之前把它判为「规则未覆盖」
  /// 是不成立的，连续失败计数必须清零，否则会攒够阈值误改路由。
  bool recordDirectSuccess(String host) {
    final domain = normalizeDomain(host);
    if (domain.isEmpty) return false;
    final entry = _exact[domain];
    if (entry == null) {
      // 还没有规则：这次交付推翻的是**待定区**里的失败证据。
      // 删掉它并如实返回 true——若在这里返回 false，上层会认为「什么都没记下」，
      // 于是同一个域名会反复重试，而反证其实已经生效。
      return _pendingSetbacks.remove(domain) != null;
    }
    entry.directSuccesses++;
    entry.consecutiveSuccesses++;
    entry.consecutiveFailures = 0;
    // 学到的强制代理规则如果被连续证明能直连，就撤销它；用户指定的规则不动。
    // 判断本身在 `route_learning.dart` 的 [shouldRevokeLearnedProxy] 里。
    if (shouldRevokeLearnedProxy(
      policy: policy,
      consecutiveSuccesses: entry.consecutiveSuccesses,
      source: entry.source,
      preference: entry.preference,
    )) {
      _uninstall(domain);
    }
    return true;
  }

  /// 查一个域名在**待定区**里的证据（尚未定性，因此还没有规则）。
  ///
  /// 供测试与诊断使用：单独暴露是为了让「未定性的证据确实被记下了」这件事能被
  /// 直接断言——否则只能通过「攒够阈值后规则出现」间接推断，而中间状态恰恰是
  /// 最容易写错的地方（它此前正是被一次 `_install` 静默变成了规则）。
  ///
  /// 刻意不给它加 `@visibleForTesting`：本文件是纯 Dart 模型，为了一个注解引入
  /// Flutter 依赖不划算。
  ({int failures, int stalls, int consecutive})? pendingSetback(String domain) {
    final pending = _pendingSetbacks[normalizeDomain(domain)];
    if (pending == null) return null;
    return (
      failures: pending.failures,
      stalls: pending.stalls,
      consecutive: pending.consecutive,
    );
  }

  /// 未定性证据的条数。
  int get pendingSetbackCount => _pendingSetbacks.length;

  /// 记录一次「直连解析结果落在国内网段」。
  ///
  /// 这是**反方向**的自动纠正：把「本该直连却走了隧道」的域名拉出来。它补的是
  /// 本文件开头那条设计缺口——原来只有「判为直连却失败」这一种证据，于是程序
  /// 只能往隧道里推，永远不能往回拉，而误入隧道的流量既不失败也不报错。
  ///
  /// 证据的性质要说清楚：调用方给出的是**DNS 事实**（该域名的直连解析答案落在
  /// `geoip-cn` 覆盖的网段内），不是猜测；而「因此该走直连」是推断。因此这里
  /// 要求连续 [domesticPromotionThreshold] 次，且任何一次直连失败都会清零。
  ///
  /// [reason] 用于界面展示，说明这条规则为什么出现。
  AutoRouteDecision recordDomesticAnswer(String host, {String? reason}) {
    final domain = normalizeDomain(host);
    if (domain.isEmpty) {
      return AutoRouteDecision(domain: host, added: false, reason: '目标不是域名');
    }
    final existing = _exact[domain];
    // 用户已经明确指定过走向：只记证据，不改写他的决定。
    if (existing != null && existing.source == RouteRuleSource.user) {
      return AutoRouteDecision(
        domain: domain,
        added: false,
        reason: '已有用户规则（${existing.preference.label}），仅记录解析结果',
        entry: existing,
      );
    }

    final streak = (_domesticStreak[domain] ?? 0) + 1;
    if (streak < policy.domesticPromotionThreshold) {
      // **不建表项**。这一点很关键：一条 preference 为 forceProxy 的新条目
      // 会变成一条「强制走隧道」的规则并注入到规则库之前，而本方法的证据方向
      // 恰好相反——它说明这个域名**可能**该直连。单次证据不足以改路由，
      // 更不足以把它钉死在隧道里。
      _rememberDomesticStreak(domain, streak);
      return AutoRouteDecision(
        domain: domain,
        added: false,
        reason:
            '直连解析落在国内网段 $streak/${policy.domesticPromotionThreshold} 次，继续观察',
      );
    }

    final current =
        existing ??
        AutoRouteEntry(domain: domain, createdAt: DateTime.now());
    final promoted = AutoRouteEntry(
      domain: domain,
      preference: RoutePreference.forceDirect,
      source: RouteRuleSource.learned,
      createdAt: current.createdAt ?? DateTime.now(),
      lastHitAt: DateTime.now(),
      directFailures: current.directFailures,
      directSuccesses: current.directSuccesses,
      stalls: current.stalls,
      consecutiveFailures: current.consecutiveFailures,
      consecutiveSuccesses: current.consecutiveSuccesses,
      proxiedBytes: current.proxiedBytes,
      // 计数留在规则上：它既是这条规则的依据，也是界面上的证据。
      domesticHits: streak,
      dnsVerdict: current.dnsVerdict,
      lastFailureReason: reason ?? current.lastFailureReason,
    );
    _install(promoted);
    _domesticStreak.remove(domain);
    return AutoRouteDecision(
      domain: domain,
      added: true,
      reason: '连续 $streak 次直连解析落在国内网段，已自动改为直连',
      entry: promoted,
    );
  }

  /// 记录「还不足以改路由」的正向证据。
  ///
  /// 刻意只放在内存里，不进 [_exact]：它不是一条规则，因此不该出现在
  /// `buildRouteRules()` 的结果里，也不该被界面当成规则列出来。代价是重启后
  /// 要重新数两次——而这个代价是刻意的：把未定性的证据持久化，会让程序在
  /// 用户看不到的地方积累状态，而它对应不上任何一条可见的规则。
  void _rememberDomesticStreak(String domain, int streak) {
    _domesticStreak[domain] = streak;
    // 上界：绝大多数条目会在下一次探测就定性（阈值只有 2），留下的是
    // 「只被看到一次就再没出现过」的域名。整表清掉比做 LRU 更简单，
    // 而它只影响「再数两次」的成本。
    if (_domesticStreak.length > maxPendingDomesticEvidence) {
      _domesticStreak.clear();
    }
  }

  /// 记录一次走隧道的流量，用于判断自动纠正是否真的起作用。
  void recordProxiedBytes(String host, int bytes) {    if (bytes <= 0) return;
    final domain = normalizeDomain(host);
    if (domain.isEmpty) return;
    final entry = _exact[domain];
    if (entry == null) return;
    entry.proxiedBytes += bytes;
  }

  /// 查出某个主机名应该走哪条路。没有规则时返回 null，交给内核按常规判定。
  AutoRouteEntry? match(String host) {
    if (host.isEmpty) return null;
    final normalized = normalizeDomain(host);
    if (normalized.isEmpty) return null;

    final exact = _exact[normalized];
    if (exact != null) return exact;

    // 后缀匹配：从最具体的父域开始逐级上溯。
    // `a.b.example.com` 依次试 `b.example.com` 的桶、`example.com` 的桶、`com` 的桶。
    final labels = normalized.split('.');
    for (var i = 1; i < labels.length; i++) {
      final bucketKey = labels.sublist(i).join('.');
      final bucket = _suffixBuckets[bucketKey];
      if (bucket == null) continue;
      AutoRouteEntry? best;
      for (final entry in bucket) {
        // 只接受后缀规则（精确规则在 _exact 里已经查过）。
        if (entry.domain == normalized) continue;
        if (!entry.matches(normalized)) continue;
        // 更长的后缀更具体，优先。
        if (best == null || entry.domain.length > best.domain.length) {
          best = entry;
        }
      }
      if (best != null) return best;
    }
    return null;
  }

  /// 淘汰过期的学习规则。
  ///
  /// [now] 可注入，便于测试。返回被淘汰的域名列表。
  List<String> evictStale({DateTime? now}) {
    final reference = now ?? DateTime.now();
    final removed = <String>[];
    for (final entry in _exact.values.toList(growable: false)) {
      if (entry.source == RouteRuleSource.user) continue;
      final last = entry.lastHitAt ?? entry.createdAt;
      if (last == null) continue;
      if (reference.difference(last) < decayAfter) continue;
      // 走隧道确实跑过流量说明这条规则有用，保留。
      if (entry.proxiedBytes > 0) continue;
      // 直连规则「有用」的证据是直连真的跑出了流量——按 proxiedBytes 判断
      // 会让一条正常工作的直连规则被当成没用的规则淘汰掉。
      if (entry.preference == RoutePreference.forceDirect &&
          entry.directSuccesses > 0) {
        continue;
      }
      removed.add(entry.domain);
    }
    for (final domain in removed) {
      _uninstall(domain);
    }
    return removed;
  }

  /// 容量超限时淘汰证据最弱的条目。
  void _enforceCapacity() {
    if (_exact.length <= capacity) return;
    final learned =
        _exact.values
            .where((AutoRouteEntry e) => e.source == RouteRuleSource.learned)
            .toList(growable: false)
          ..sort((AutoRouteEntry a, AutoRouteEntry b) {
            // 证据越弱越先淘汰：失败次数少、代理流量少、创建时间早的排前面。
            final byFailures = a.directFailures.compareTo(b.directFailures);
            if (byFailures != 0) return byFailures;
            final byBytes = a.proxiedBytes.compareTo(b.proxiedBytes);
            if (byBytes != 0) return byBytes;
            return (a.createdAt ?? DateTime(2000)).compareTo(
              b.createdAt ?? DateTime(2000),
            );
          });
    var overflow = _exact.length - capacity;
    for (final entry in learned) {
      if (overflow <= 0) break;
      _uninstall(entry.domain);
      overflow--;
    }
  }

  void _install(AutoRouteEntry entry) {
    _exact[entry.domain] = entry;
    _reindexSuffix(entry);
    _enforceCapacity();
  }

  void _uninstall(String domain) {
    _exact.remove(domain);
    final dot = domain.indexOf('.');
    if (dot <= 0 || dot == domain.length - 1) return;
    final key = domain.substring(dot + 1);
    final bucket = _suffixBuckets[key];
    if (bucket == null) return;
    bucket.removeWhere((AutoRouteEntry e) => e.domain == domain);
    if (bucket.isEmpty) _suffixBuckets.remove(key);
  }

  /// 把条目挂到它对应的后缀桶里。精确匹配与后缀匹配共用同一份条目。
  void _reindexSuffix(AutoRouteEntry entry) {
    final dot = entry.domain.indexOf('.');
    if (dot <= 0 || dot == entry.domain.length - 1) {
      // 单标签域名（如 `localhost`）不参与后缀匹配。
      return;
    }
    final key = entry.domain.substring(dot + 1);
    final bucket = _suffixBuckets.putIfAbsent(key, () => <AutoRouteEntry>[]);
    final existing = bucket.indexWhere(
      (AutoRouteEntry e) => e.domain == entry.domain,
    );
    if (existing >= 0) {
      bucket[existing] = entry;
    } else {
      bucket.add(entry);
    }
  }

  /// 移除**全部程序学到**的规则，保留用户手工指定与内置白名单预置。返回被移除的域名。
  ///
  /// 用于「恢复内置规则」：用户要的是回到出厂时的判断，而程序在运行中观察到的
  /// 结论应当被丢弃。手工指定的规则是用户明确的决定，不在清理范围内——
  /// 把两者一起清掉会让用户手动配置的例外被悄悄抹掉，那比不清理更糟。
  /// 预置同理：它的开关在「直连白名单」卡片上，「恢复内置规则」不该顺带改动它。
  List<String> removeLearned() {
    final removed = _exact.values
        .where((AutoRouteEntry e) => e.source == RouteRuleSource.learned)
        .map((AutoRouteEntry e) => e.domain)
        .toList(growable: false);
    for (final domain in removed) {
      _uninstall(domain);
    }
    // 未定性的证据也是程序学来的，一并丢弃——「恢复内置规则」的意思是回到出厂
    // 判断，而不是保留一半观察。
    _pendingSetbacks.clear();
    _rateEvidence.clear();
    _rateRetryAt.clear();
    _linkRates.clear();
    return removed;
  }

  void clear() {
    _exact.clear();
    _suffixBuckets.clear();
    _domesticStreak.clear();
    _pendingSetbacks.clear();
    // 速率证据与基准也是运行中观察到的，一并清掉。
    _rateEvidence.clear();
    _rateRetryAt.clear();
    _linkRates.clear();
  }

  /// 需要落盘的条目。
  ///
  /// **预置不落盘**：它随代码分发、由开关驱动、每次启动重新安装。写进存档会留下
  /// 一份会过期的副本（域名清单属于程序版本），而且用户关掉开关后旧的域名还会
  /// 留在文件里。这与 `AppSettings.enabledAppPresets` 只存 id 是同一个理由。
  List<Map<String, Object?>> toJson() => _exact.values
      .where((AutoRouteEntry e) => e.source != RouteRuleSource.preset)
      .map((AutoRouteEntry e) => e.toJson())
      .toList(growable: false);

  /// 从持久化数据恢复。单条损坏只跳过这一条。
  void loadFrom(Object? raw) {
    clear();
    if (raw is! List) return;
    for (final item in raw) {
      final entry = AutoRouteEntry.fromJson(item);
      if (entry == null) continue;
      _install(entry);
    }
  }

  /// 单条规则里最多带多少个域名。超过就分成多条规则，避免单条规则过长。
  static const int domainsPerRule = 512;

  /// 生成 sing-box 路由规则片段，**按优先级分成两段**。
  ///
  /// 分成两段而不是一段，是为了让「内网地址始终直连」这条规则有一个确定的位置。
  /// 完整的优先级契约（从前到后，内核按**首次命中**生效）：
  ///
  /// | 顺序 | 规则 | 谁能覆盖它 |
  /// | --- | --- | --- |
  /// | 1 | [`userRules`] 用户手工指定 | ——（最高） |
  /// | 2 | `ip_is_private` 内网直连（在 `_route()` 里） | 只有用户规则 |
  /// | 3 | [`otherRules`] 程序学到 + 内置白名单 | 1、2 |
  /// | 4 | 规则库 `geosite-cn` / `geoip-cn`（在 `_route()` 里） | 1、2、3 |
  /// | 5 | `route.final` 兜底 | 全部 |
  ///
  /// 为什么把 [otherRules] 放在 `ip_is_private` **之后**：程序学到的规则来自
  /// 「直连失败」或「解析落在国内网段」这两类证据，而**内网主机名同样会落在
  /// 这两类里**——`nas.local` 解析出 `192.168.x.x` 会被 `geoip-cn` 命中（于是
  /// 反方向学成直连，无害），而它一旦临时不可达就会攒够「直连失败」被推成
  /// `forceProxy`（**有害**：内网流量被送进隧道，既费流量又必然连不上，而且
  /// 用户完全看不出原因）。私有地址段是确定的、可判定的边界，不该由推断出的
  /// 证据去推翻它。用户显式指定则不同——那是人的明确意图，保留它的最高优先级。
  ///
  /// 之所以同时下发 `domain` 与 `domain_suffix`：sing-box 的 `domain` 是
  /// **精确匹配**，`example.com` 不会命中 `www.example.com`；
  /// 学习者手里拿到的却往往是子域。两者都下发才符合直觉。
  ///
  /// 每段内按 `proxy 精确 → proxy 后缀 → direct 精确 → direct 后缀` 排列。
  ({
    List<Map<String, Object?>> userRules,
    List<Map<String, Object?>> otherRules,
  })
  buildRouteRules() {
    final user = <AutoRouteEntry>[];
    final others = <AutoRouteEntry>[];
    for (final entry in _exact.values) {
      if (entry.source == RouteRuleSource.user) {
        user.add(entry);
      } else {
        others.add(entry);
      }
    }
    return (
      userRules: _rulesFor(user),
      otherRules: _rulesFor(others),
    );
  }

  /// 把一批条目翻译成路由规则片段。
  ///
  /// 段内排序：按域名长度降序，这样更具体的子域规则先命中父域规则
  /// （父域规则在同一个 `domain_suffix` 列表里会覆盖它）。
  static List<Map<String, Object?>> _rulesFor(List<AutoRouteEntry> entries) {
    if (entries.isEmpty) return const <Map<String, Object?>>[];
    final sorted = entries.toList(growable: false)
      ..sort((AutoRouteEntry a, AutoRouteEntry b) {
        final byLength = b.domain.length.compareTo(a.domain.length);
        return byLength != 0 ? byLength : a.domain.compareTo(b.domain);
      });

    final proxyExact = <String>[];
    final proxySuffix = <String>[];
    final directExact = <String>[];
    final directSuffix = <String>[];

    for (final entry in sorted) {
      final hasSuffixForm = entry.domain.contains('.');
      switch (entry.preference) {
        case RoutePreference.forceProxy:
          proxyExact.add(entry.domain);
          if (hasSuffixForm) proxySuffix.add(entry.domain);
        case RoutePreference.forceDirect:
          directExact.add(entry.domain);
          if (hasSuffixForm) directSuffix.add(entry.domain);
      }
    }

    return <Map<String, Object?>>[
      ..._chunkedRule(proxyExact, proxySuffix, OutboundTags.vpn),
      ..._chunkedRule(directExact, directSuffix, OutboundTags.direct),
    ];
  }

  /// 按走向分组的域名集合。供 DNS 规则复用**同一份决策**。
  ///
  /// 存在的理由是本项目一处真实的不一致：`dns.rules` 原先只认 `geosite-cn`，
  /// 而路由决策来自三个来源（规则库、自动纠正、直连白名单）。两者会互相矛盾——
  /// 「已判定该直连」的域名仍被境外解析器解析（于是拿到境外 CDN 的地址再去直连），
  /// 「因境内答案不可信而强制代理」的域名却仍被送去境内解析器。
  ///
  /// 因此 DNS 决策必须从**同一个** `_exact` 派生，而不是另写一份条件。
  ({
    List<String> directDomains,
    List<String> proxyDomains,
  })
  domainSets() {
    final direct = <String>[];
    final proxy = <String>[];
    for (final entry in _exact.values) {
      switch (entry.preference) {
        case RoutePreference.forceDirect:
          direct.add(entry.domain);
        case RoutePreference.forceProxy:
          proxy.add(entry.domain);
      }
    }
    return (directDomains: direct, proxyDomains: proxy);
  }

  static List<Map<String, Object?>> _chunkedRule(
    List<String> exact,
    List<String> suffix,
    String outbound,
  ) {
    final rules = <Map<String, Object?>>[];
    // 精确域与后缀域各自分块，块数取两者中较大的那个。
    final exactChunks = _chunk(exact);
    final suffixChunks = _chunk(suffix);
    final chunkCount = exactChunks.length > suffixChunks.length
        ? exactChunks.length
        : suffixChunks.length;
    for (var i = 0; i < chunkCount; i++) {
      rules.add(<String, Object?>{
        if (i < exactChunks.length) 'domain': exactChunks[i],
        if (i < suffixChunks.length) 'domain_suffix': suffixChunks[i],
        'outbound': outbound,
      });
    }
    return rules;
  }

  static List<List<String>> _chunk(List<String> values) {
    if (values.isEmpty) return const <List<String>>[];
    final chunks = <List<String>>[];
    for (var i = 0; i < values.length; i += domainsPerRule) {
      final end = i + domainsPerRule > values.length
          ? values.length
          : i + domainsPerRule;
      chunks.add(values.sublist(i, end));
    }
    return chunks;
  }

  /// 归一化域名：小写、去掉端口与首尾点。
  ///
  /// 内核返回的目标可能是 `example.com:443` 或 `example.com.`（FQDN），
  /// 不归一化会导致同一个站点存成三条不同的规则。
  static String normalizeDomain(String host) {
    var value = host.trim().toLowerCase();
    if (value.isEmpty) return '';
    // 去掉端口。IPv6 会被下面的 IP 判断挡掉，这里只处理 `host:port` 形式。
    final colon = value.lastIndexOf(':');
    if (colon > 0 && !value.substring(0, colon).contains(':')) {
      final port = value.substring(colon + 1);
      if (int.tryParse(port) != null) value = value.substring(0, colon);
    }
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) return '';
    // IP 目标不参与自动纠正：IP 层面的失败与域名分流规则无关。
    if (isIpLiteral(value)) return '';
    // 单标签主机名（局域网主机）无意义。
    if (!value.contains('.')) return '';
    return value;
  }

  /// 是否是 IP 字面量（IPv4 或 IPv6）。
  static bool isIpLiteral(String value) {
    if (value.contains(':')) return true; // IPv6
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }
}
