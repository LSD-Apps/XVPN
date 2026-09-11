/// 自动纠正表：把「观察到的失败」变成「内核里的高优先级分流规则」。
///
/// 这是让「傻瓜式」真正闭环的一步。内置规则库覆盖不到的长尾情况有两类，
/// 而这两类的表现都是「网站打不开，用户完全看不出原因」：
///
///   1. 被墙站点解析到**国内 IP**（境外服务用了国内 CDN）→ 命中 geoip-cn 被
///      判为直连 → 直连必然失败。规则库修不了，因为它「正确地」命中了。
///   2. 域名被投毒，国内解析器返回一个不属于该站点的地址 → 直连/代理判定
///      建立在假地址之上。
///
/// 程序能观察到这两类的共同后果：**判为直连却失败**。内核日志里写明了失败的
/// 出站（见 `core_log.dart`），DNS 监测能补充「这个域名的解析是否可信」
/// （见 `dns_monitor.dart`）。把两者合起来，就足以在不打扰用户的前提下
/// 自动把这个域名改成走隧道。
///
/// 设计上刻意保守：
///   * 只有**域名**会被学习，IP 目标一律不动——IP 失败与分流规则无关；
///   * 需要**连续多次**失败才纠正，单次抖动不会改路由；
///   * 只要出现过一次直连成功，连续失败计数就清零；
///   * 纠正表有容量上限，且会随时间衰减，不会变成一个只增不减的黑名单。
library;

/// 分流倾向。
enum RoutePreference {
  /// 强制走隧道。
  forceProxy,

  /// 强制直连。
  ///
  /// 目前只在用户手工指定时产生：程序能可靠观察到的是「直连失败」，
  /// 而「走隧道其实很慢、本该直连」缺少同等强度的证据，自动改判风险太高。
  forceDirect,
}

extension RoutePreferenceX on RoutePreference {
  String get label => this == RoutePreference.forceProxy ? '强制代理' : '强制直连';

  String get storageKey => this == RoutePreference.forceProxy ? 'proxy' : 'direct';
}

/// 规则来源，决定它在表里的优先级。
enum RouteRuleSource {
  /// 用户手工指定。永远最高优先级，且不会被程序覆盖。
  user,

  /// 程序从失败证据里学到的。
  learned,
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
    this.consecutiveFailures = 0,
    this.proxiedBytes = 0,
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

  /// 累计「判为直连且成功」的观测次数。
  ///
  /// 只要它大于 0，就说明直连**能**通，连续失败计数会被清零。
  int directSuccesses;

  /// 连续失败次数。达到阈值才触发纠正。
  int consecutiveFailures;

  /// 走隧道时累计的字节数。用来判断「改成代理以后确实在用」。
  int proxiedBytes;

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
        'source': source == RouteRuleSource.user ? 'user' : 'learned',
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (lastHitAt != null) 'lastHitAt': lastHitAt!.toIso8601String(),
        'directFailures': directFailures,
        'directSuccesses': directSuccesses,
        'consecutiveFailures': consecutiveFailures,
        'proxiedBytes': proxiedBytes,
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
      source: json['source'] == 'user' ? RouteRuleSource.user : RouteRuleSource.learned,
      createdAt: _time(json['createdAt']),
      lastHitAt: _time(json['lastHitAt']),
      directFailures: (json['directFailures'] as num?)?.toInt() ?? 0,
      directSuccesses: (json['directSuccesses'] as num?)?.toInt() ?? 0,
      consecutiveFailures: (json['consecutiveFailures'] as num?)?.toInt() ?? 0,
      proxiedBytes: (json['proxiedBytes'] as num?)?.toInt() ?? 0,
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
  AutoRouteTable({
    this.capacity = 400,
    this.promotionThreshold = 3,
    this.decayAfter = const Duration(days: 14),
  }) : assert(capacity > 0);

  /// 表容量上限。超出时淘汰证据最弱的条目。
  final int capacity;

  /// 连续失败多少次才自动纠正。
  ///
  /// 取 3 而不是 1：单次失败可能只是网络抖动或对端临时故障，
  /// 一次抖动就把域名永久推进隧道，会让用户觉得「分流时好时坏」。
  final int promotionThreshold;

  /// 多久没有任何新证据就淘汰。避免老规则一直留着。
  final Duration decayAfter;

  /// 精确域名 → 条目。
  final Map<String, AutoRouteEntry> _exact = <String, AutoRouteEntry>{};

  /// 「去掉最后一级标签」→ 后缀规则条目集。
  ///
  /// 例：规则 `example.com` 归档到键 `com`，规则 `example.co.uk` 归档到键 `co.uk`。
  final Map<String, List<AutoRouteEntry>> _suffixBuckets =
      <String, List<AutoRouteEntry>>{};

  int get length => _exact.length;

  bool get isEmpty => _exact.isEmpty;

  Iterable<AutoRouteEntry> get entries => _exact.values;

  /// 用户手工指定一条规则。永远覆盖程序学到的规则。
  AutoRouteDecision setUserRule(String domain, RoutePreference preference) {
    final normalized = normalizeDomain(domain);
    if (normalized.isEmpty) {
      return AutoRouteDecision(
        domain: domain,
        added: false,
        reason: '域名不合法',
      );
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
      consecutiveFailures: existing?.consecutiveFailures ?? 0,
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

  /// 记录一次「判为直连却失败」。
  ///
  /// [dnsVerdict] 来自 DNS 交叉校验（`DnsVerdict.name`）。为
  /// `suspectPoisoning` 时阈值降为 1：投毒是确定性证据，不需要再等两次。
  AutoRouteDecision recordDirectFailure(
    String host, {
    String? reason,
    String? dnsVerdict,
  }) {
    final domain = normalizeDomain(host);
    if (domain.isEmpty) {
      return AutoRouteDecision(domain: host, added: false, reason: '目标不是域名');
    }
    final entry = _exact[domain] ??
        AutoRouteEntry(domain: domain, createdAt: DateTime.now());
    entry.directFailures++;
    entry.consecutiveFailures++;
    entry.lastFailureReason = reason;
    if (dnsVerdict != null) entry.dnsVerdict = dnsVerdict;

    final poisoned = dnsVerdict == 'suspectPoisoning';
    final threshold = poisoned ? 1 : promotionThreshold;
    // 用户已经显式指定过的规则不参与自动改写。
    if (entry.source == RouteRuleSource.user) {
      _install(entry);
      return AutoRouteDecision(
        domain: domain,
        added: false,
        reason: '已有用户规则（${entry.preference.label}），仅记录失败',
        entry: entry,
      );
    }

    if (entry.consecutiveFailures >= threshold && entry.directSuccesses == 0) {
      final wasNew = !_exact.containsKey(domain) ||
          entry.preference != RoutePreference.forceProxy;
      final promoted = AutoRouteEntry(
        domain: domain,
        preference: RoutePreference.forceProxy,
        source: RouteRuleSource.learned,
        createdAt: entry.createdAt ?? DateTime.now(),
        lastHitAt: DateTime.now(),
        directFailures: entry.directFailures,
        directSuccesses: entry.directSuccesses,
        consecutiveFailures: entry.consecutiveFailures,
        proxiedBytes: entry.proxiedBytes,
        dnsVerdict: entry.dnsVerdict,
        lastFailureReason: entry.lastFailureReason,
      );
      _install(promoted);
      return AutoRouteDecision(
        domain: domain,
        added: wasNew,
        reason: poisoned
            ? '解析结果疑似被投毒，已自动改为走隧道'
            : '连续 ${entry.consecutiveFailures} 次判为直连但失败，已自动改为走隧道',
        entry: promoted,
      );
    }

    _install(entry);
    return AutoRouteDecision(
      domain: domain,
      added: false,
      reason: '失败 ${entry.consecutiveFailures}/$threshold 次，继续观察',
      entry: entry,
    );
  }

  /// 记录一次「判为直连且连接有流量」。返回是否确实记下了。
  ///
  /// 返回 bool 而不是 void 是为了让上层能正确地去重：只有**确实记录成功**时
  /// 才该把这个域名标记为「已处理过」。
  ///
  /// 这里踩过一个自己挖的坑：上层原本无条件把域名加进「已上报」集合，
  /// 而一个域名完全可能先失败若干次、之后才出现一次成功的直连。第一次成功时
  /// 表里已经有条目，一切正常；但如果顺序反过来（先被别的路径写进集合），
  /// 真正的成功就被当成重复而丢掉——于是「直连其实能通」这个关键反证
  /// 永远不会被记账，失败计数继续累积，最终把一个正常域名推进隧道。
  ///
  /// 这是反证：直连既然能跑出流量，就说明之前把它判为「规则未覆盖」
  /// 是不成立的，连续失败计数必须清零，否则会攒够阈值误改路由。
  bool recordDirectSuccess(String host) {
    final domain = normalizeDomain(host);
    if (domain.isEmpty) return false;
    final entry = _exact[domain];
    if (entry == null) return false;
    entry.directSuccesses++;
    entry.consecutiveFailures = 0;
    // 学到的强制代理规则如果被证明能直连，就撤销它；
    // 用户指定的规则不动。
    if (entry.source == RouteRuleSource.learned &&
        entry.preference == RoutePreference.forceProxy &&
        entry.directSuccesses >= 2) {
      _uninstall(domain);
    }
    return true;
  }

  /// 记录一次走隧道的流量，用于判断自动纠正是否真的起作用。
  void recordProxiedBytes(String host, int bytes) {
    if (bytes <= 0) return;
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
    final learned = _exact.values
        .where((AutoRouteEntry e) => e.source == RouteRuleSource.learned)
        .toList(growable: false)
      ..sort((AutoRouteEntry a, AutoRouteEntry b) {
        // 证据越弱越先淘汰：失败次数少、代理流量少、创建时间早的排前面。
        final byFailures = a.directFailures.compareTo(b.directFailures);
        if (byFailures != 0) return byFailures;
        final byBytes = a.proxiedBytes.compareTo(b.proxiedBytes);
        if (byBytes != 0) return byBytes;
        return (a.createdAt ?? DateTime(2000)).compareTo(b.createdAt ?? DateTime(2000));
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
    final existing = bucket.indexWhere((AutoRouteEntry e) => e.domain == entry.domain);
    if (existing >= 0) {
      bucket[existing] = entry;
    } else {
      bucket.add(entry);
    }
  }

  void clear() {
    _exact.clear();
    _suffixBuckets.clear();
  }

  List<Map<String, Object?>> toJson() =>
      _exact.values.map((AutoRouteEntry e) => e.toJson()).toList(growable: false);

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

  /// 生成 sing-box 路由规则片段。
  ///
  /// 规则顺序即优先级。调用方需要把它插在 `geosite-cn` / `geoip-cn` **之前**，
  /// 这样就实现了「学到的判断优先于规则库」——这正是本功能的意义所在：
  /// 规则库把某个被墙域名判成直连（因为它解析到国内 IP），
  /// 而这里的规则要能把它拉回隧道。
  ///
  /// 之所以同时下发 `domain` 与 `domain_suffix`：sing-box 的 `domain` 是
  /// **精确匹配**，`example.com` 不会命中 `www.example.com`；
  /// 学习者手里拿到的却往往是子域。两者都下发才符合直觉。
  ///
  /// 多条规则按 `proxy 精确 → proxy 后缀 → direct 精确 → direct 后缀` 排列。
  List<Map<String, Object?>> buildRouteRules() {
    final proxyExact = <String>[];
    final proxySuffix = <String>[];
    final directExact = <String>[];
    final directSuffix = <String>[];

    // 排序保证「最具体的优先」：用户规则在最前，其余按域名长度降序，
    // 这样被学到的子域规则会先于父域规则命中。
    final sorted = _exact.values.toList(growable: false)
      ..sort((AutoRouteEntry a, AutoRouteEntry b) {
        if (a.source != b.source) {
          return a.source == RouteRuleSource.user ? -1 : 1;
        }
        final byLength = b.domain.length.compareTo(a.domain.length);
        return byLength != 0 ? byLength : a.domain.compareTo(b.domain);
      });

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
      ..._chunkedRule(proxyExact, proxySuffix, 'vpn'),
      ..._chunkedRule(directExact, directSuffix, 'direct'),
    ];
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
    final chunkCount =
        exactChunks.length > suffixChunks.length ? exactChunks.length : suffixChunks.length;
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
      final end = i + domainsPerRule > values.length ? values.length : i + domainsPerRule;
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
