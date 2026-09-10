/// 内核日志解析。
///
/// 目标是回答一个用户最关心、但光看界面看不出来的问题：
/// **「打不开」到底是规则判错了，还是节点本身不通？**
///
/// 这两者的表现完全一样，处理方式却截然相反：
///   * 判为直连却失败 → 规则库可能没覆盖这个域名，应该改走代理；
///   * 走了隧道却失败 → 是节点/服务器的问题，改规则没有任何用。
///
/// 内核日志里带有判断所需的全部信息。以下是一条实测日志的原文：
///
/// ```
/// ERROR [2292784999641 10.1s] connection: open connection to www.baidu.com:443
///   using outbound/direct[direct]: lookup www.baidu.com: (exchange6: ... | exchange4: ...)
/// ```
///
/// `using outbound/direct[direct]` 明确指出走了哪个出站，
/// 冒号之后是失败原因。解析器只做纯文本处理，因此可以完整单元测试。
library;

/// 一条连接失败。
class ConnectionFailure {
  const ConnectionFailure({
    required this.time,
    required this.target,
    required this.outbound,
    required this.reason,
  });

  final DateTime time;

  /// 目标，形如 `www.baidu.com:443` 或 `8.8.8.8:53`。
  final String target;

  /// 实际使用的出站标签：`direct` / `vpn` / 其它。
  final String outbound;

  /// 内核给出的原因原文。
  final String reason;

  /// 是否走了直连。
  bool get wasDirect => outbound == 'direct';

  /// 是否走了隧道。
  bool get wasProxied => !wasDirect;

  /// 目标的主机名部分（去掉端口）。IP 目标也会原样返回。
  String get host {
    final idx = target.lastIndexOf(':');
    if (idx <= 0) return target;
    final maybePort = target.substring(idx + 1);
    if (int.tryParse(maybePort) == null) return target;
    return target.substring(0, idx);
  }

  /// 是否看起来是 IP 目标（而不是域名）。
  bool get isIpTarget {
    final h = host;
    if (h.contains(':')) return true; // IPv6
    final parts = h.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 失败原因的简短归类，用于界面展示。
  String get reasonSummary {
    final r = reason.toLowerCase();
    if (r.contains('i/o timeout')) return '连接超时';
    if (r.contains('context deadline exceeded')) return '解析或握手超时';
    if (r.contains('connection refused')) return '连接被拒绝';
    if (r.contains('no such host') || r.contains('lookup failed')) return '域名解析失败';
    if (r.contains('missing ipv6 local address')) return '隧道缺少 IPv6 地址';
    if (r.contains('no known endpoint')) return '隧道端点不可达';
    if (r.contains('reset by peer')) return '连接被重置';
    if (r.contains('certificate')) return '证书校验失败';
    return '连接失败';
  }

  /// 这条失败是否可能说明「规则库没覆盖到这个域名」。
  ///
  /// 判为直连却失败是主要线索，但有两种情况要排除：
  ///   * IP 目标的失败——域名规则本来就管不到它，多半是站点/网络问题；
  ///   * 解析失败——那是 DNS 层面的事，与分流规则无关。
  bool get suggestsMissingRule {
    if (!wasDirect) return false;
    if (isIpTarget) return false;
    if (reasonSummary == '域名解析失败') return false;
    return true;
  }
}

/// 从内核日志里解析连接失败。无法识别时返回 null。
ConnectionFailure? parseConnectionFailure(String line, {DateTime? now}) {
  if (!line.contains('ERROR')) return null;

  // connection: open connection to <目标> using outbound/<类型>[<标签>]: <原因>
  final open = RegExp(
    r'connection:\s*open connection to (\S+) using outbound/(\w+)\[([^\]]+)\]:\s*(.+)$',
  ).firstMatch(line);
  if (open != null) {
    final reason = open.group(4)!.trim();
    if (reason.isEmpty) return null;
    return ConnectionFailure(
      time: now ?? DateTime.now(),
      target: open.group(1)!,
      outbound: open.group(3)!.trim(),
      reason: reason,
    );
  }

  // 隧道端点自身解析不出来时，内核只会报 endpoint 级别的错误，
  // 这时连接甚至还没建立，但原因同样重要。
  final endpoint = RegExp(
    r'endpoint/\w+\[([^\]]+)\]:\s*(.+)$',
  ).firstMatch(line);
  if (endpoint != null && line.contains('failed')) {
    return ConnectionFailure(
      time: now ?? DateTime.now(),
      target: '(隧道端点)',
      outbound: endpoint.group(1)!.trim(),
      reason: endpoint.group(2)!.trim(),
    );
  }

  return null;
}

/// 失败归因摘要。界面用它把「打不开」翻译成用户能理解的一句话。
class FailureDigest {
  const FailureDigest({
    required this.total,
    required this.directFailures,
    required this.proxiedFailures,
    required this.suspectedMissingRules,
  });

  static const empty = FailureDigest(
    total: 0,
    directFailures: 0,
    proxiedFailures: 0,
    suspectedMissingRules: <String>[],
  );

  final int total;
  final int directFailures;
  final int proxiedFailures;

  /// 疑似规则库未覆盖的域名（去重，按出现顺序）。
  final List<String> suspectedMissingRules;

  bool get hasProblems => total > 0;

  /// 给出处置建议。这是「检测能力」最终要落到的东西：
  /// 用户不需要懂分流，只需要知道该做什么。
  String get advice {
    if (total == 0) return '暂未发现异常连接';
    if (suspectedMissingRules.isNotEmpty) {
      return '有 ${suspectedMissingRules.length} 个域名被判为直连但连接失败，'
          '可能是规则库未覆盖；可尝试切换为「全局代理」验证是否为节点问题。';
    }
    if (proxiedFailures > 0 && directFailures == 0) {
      return '失败都发生在隧道上，说明规则判定正常，问题在节点或服务器本身。';
    }
    if (directFailures > 0) {
      return '有直连连接失败，但目标为 IP 或 DNS 层问题，与分流规则无关。';
    }
    return '暂未发现异常连接';
  }
}

/// 把失败列表汇总成摘要。
FailureDigest digestFailures(List<ConnectionFailure> failures) {
  if (failures.isEmpty) return FailureDigest.empty;
  var direct = 0;
  var proxied = 0;
  final suspected = <String>[];
  for (final f in failures) {
    if (f.wasDirect) {
      direct++;
    } else {
      proxied++;
    }
    if (f.suggestsMissingRule && !suspected.contains(f.host)) {
      suspected.add(f.host);
    }
  }
  return FailureDigest(
    total: failures.length,
    directFailures: direct,
    proxiedFailures: proxied,
    suspectedMissingRules: List<String>.unmodifiable(suspected),
  );
}
