/// Clash API 快照的解析。
///
/// 这里刻意做成**纯函数**：输入是接口返回的 JSON 文本，输出是结构化数据，
/// 不依赖网络、不依赖内核，因此可以完整单元测试。
///
/// 之所以单独拆出来，是因为踩过一个代价很大的坑：Clash API 里
/// `/connections` 是**普通快照**接口，而 `/traffic` 是**流式**接口
/// （持续推送、连接永不结束）。早先用 `join()` 去读 `/traffic`，
/// Future 永远不完成，把整个轮询卡死，导致「最近分流」与流量统计
/// 同时没有任何数据。因此现在只查 `/connections` 一个接口：
/// 它一次就返回连接列表与累计字节数，速率由相邻两次采样算差值。
///
/// 字段格式对着 sing-box v1.14.0 的 `experimental/clashapi/connections.go`
/// 逐个核对过，有几处与「Clash 原版」的习惯写法不同，值得单独说明：
///
///   * `rule` 不是规则名，而是一段**描述文本**，由内核用
///     `fmt.Sprintf("%s => %s", rule, action)` 拼出来，例如
///     `rule_set=[geosite-cn geoip-cn] => route`、`ip_is_private=true => route`；
///   * `rulePayload` **恒为空字符串**（sing-box 不填这个字段），
///     所以任何依赖它的解析都拿不到东西；
///   * `chains` 里是出站标签链，本项目只有一个 `vpn` 出站与一个 `direct` 出站；
///   * 每条连接自带 `upload` / `download` / `start`，可以做按连接的精确统计。
///
/// 另外注意：快照在服务端就**过滤掉了 DNS 流量**
/// （`metadata.OutboundType != C.TypeDNS`）。因此 DNS 查询永远不会出现在
/// 连接列表里，DNS 的健康状况必须另走一条探测链路，见 `dns_probe.dart`。
library;

import 'dart:convert';

import 'record_buffer.dart';

/// 把 JSON 里的数值宽松地读成 int。
///
/// 内核偶尔会把计数器写成字符串（不同构建之间出现过），
/// 而统计数字读不出来不该让整份快照作废。
int _intOf(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

/// 一条连接（Clash API 快照里的元素）。
class ClashConnection {
  const ClashConnection({
    required this.id,
    required this.host,
    required this.destinationIp,
    required this.destinationPort,
    required this.rule,
    required this.outbound,
    required this.proxied,
    required this.upload,
    required this.download,
    this.startedAt,
    this.network = '',
    this.processPath = '',
  });

  final String id;

  /// 目标域名（内核嗅探到的 SNI/Host，或解析出的域名）。IP 直连时为空。
  final String host;

  /// 目标 IP。域名尚未解析或未连上时为 `0.0.0.0` / 空。
  final String destinationIp;

  final int destinationPort;

  /// 命中规则的展示名。已从内核的描述文本里归一化，例如 `geosite-cn + geoip-cn`。
  final String rule;

  /// 实际走的出站标签：`vpn` 或 `direct`。
  final String outbound;

  /// 是否走隧道。
  final bool proxied;

  /// 这条连接已上传/下载的字节数（内核按连接精确计数）。
  final int upload;
  final int download;

  /// 连接建立时间。缺失时为 null。
  final DateTime? startedAt;

  /// `tcp` / `udp`。
  final String network;

  /// 发起连接的程序路径。TUN 模式下可取，系统代理模式下通常为空。
  final String processPath;

  int get totalBytes => upload + download;

  /// 展示目标：优先域名，其次 IP（带端口）。
  String get target {
    if (host.isNotEmpty) return host;
    if (destinationIp.isEmpty || destinationIp == '0.0.0.0') return '(未知目标)';
    final hasPort = destinationPort > 0;
    final isIpv6 = destinationIp.contains(':');
    final shown = isIpv6 ? '[$destinationIp]' : destinationIp;
    return hasPort ? '$shown:$destinationPort' : shown;
  }

  static ClashConnection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;

    // 同样不能用 `as Map?`：字段存在但类型不对时它会抛，而不是退化成空表。
    final rawMetadata = json['metadata'];
    final metadata = rawMetadata is Map
        ? rawMetadata.cast<String, Object?>()
        : const <String, Object?>{};
    final rawChains = json['chains'];
    final chains = rawChains is List ? rawChains : const <Object?>[];
    // 出站标签取链尾：项目里只有 vpn / direct 两个出站，链尾就是最终落点。
    final outbound = chains.isEmpty
        ? 'direct'
        : chains.map((Object? c) => c.toString()).last;

    return ClashConnection(
      id: id,
      host: metadata['host']?.toString() ?? '',
      destinationIp: metadata['destinationIP']?.toString() ?? '',
      destinationPort: int.tryParse(metadata['destinationPort']?.toString() ?? '') ?? 0,
      rule: ruleDisplayName(json['rule']?.toString() ?? ''),
      outbound: outbound,
      proxied: chains.any((Object? c) => c.toString() == 'vpn'),
      upload: _intOf(json['upload']),
      download: _intOf(json['download']),
      startedAt: _parseTime(json['start']),
      network: metadata['network']?.toString() ?? '',
      processPath: metadata['processPath']?.toString() ?? '',
    );
  }

  /// 只需要 id 的场景（判断「这条见过没有」）不必构造整个对象。
  static String idOf(Object? raw) {
    if (raw is! Map) return '';
    return raw['id']?.toString() ?? '';
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  /// 把内核的规则描述文本归一化成用户看得懂的名字。
  ///
  /// 输入形如 `rule_set=[geosite-cn geoip-cn] => route`。
  /// 去掉 `=> action` 尾巴后按描述文本分类。
  static String ruleDisplayName(String raw) => normalizeRuleDescription(raw);
}

/// 把内核的规则描述文本归一化成用户看得懂的名字。
///
/// 做成模块级函数是为了让演示内核也能走**同一条**归一化路径。此前演示数据
/// 直接给的就是 `geosite-cn` 这样的成品名，于是「界面显示内核术语」这个 bug
/// 在演示数据上永远暴露不出来，而真实内核一接上就会满屏 `rule_set=[...]`。
String normalizeRuleDescription(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '默认规则';

  // 拆掉 "=> action" 部分。动作本身由「判定」列表达，这里不重复。
  var body = trimmed;
  final arrow = body.lastIndexOf('=>');
  if (arrow != -1) body = body.substring(0, arrow).trim();

  if (body.isEmpty || trimmed == 'final' || body == 'final') return '默认规则';
  if (body.startsWith('rule_set=')) {
    final inner = body
        .substring('rule_set='.length)
        .replaceAll('[', '')
        .replaceAll(']', '')
        .trim();
    if (inner.isEmpty) return '规则库';
    // 本项目固定是 geosite-cn + geoip-cn 两条，合并显示比原样展开更短。
    final tags = inner.split(RegExp(r'\s+')).where((String s) => s.isNotEmpty);
    return tags.length <= 2 ? tags.join(' + ') : '规则库（${tags.length} 项）';
  }
  if (body.startsWith('ip_is_private=true')) return '局域网地址';
  if (body.startsWith('protocol=dns')) return 'DNS 请求';
  if (body.startsWith('inbound=')) return '入站规则';
  if (body.startsWith('network=')) return '网络类型';
  if (body.startsWith('ip_version=')) return 'IP 版本';
  // 兜底：原样展示，总比把整句描述塞进表格强。
  return body.length > 40 ? '${body.substring(0, 40)}…' : body;
}

/// 一次 `/connections` 快照。
class ClashSnapshot {
  const ClashSnapshot({
    required this.downloadTotal,
    required this.uploadTotal,
    required this.connections,
    this.memory = 0,
  });

  final int downloadTotal;
  final int uploadTotal;
  final List<ClashConnection> connections;

  /// 内核报告的常驻内存字节数。用于「大数据量下是否真的顺畅」的自查。
  final int memory;

  int get totalBytes => downloadTotal + uploadTotal;

  /// 解析失败返回 null（网络抖动、内核正在退出等都不应让界面崩掉）。
  static ClashSnapshot? parse(String body) {
    try {
      final json = _decode(body);
      if (json == null) return null;
      return fromJson(json);
    } on Object {
      return null;
    }
  }

  /// 从已解码的 JSON 构造。
  ///
  /// 字段级容错：`connections` 缺失或类型不对时按空列表处理，而累计流量仍然
  /// 按能读到的值更新。这与「整份快照判为无效」不同——内核正在退出、或者
  /// 某个版本改了字段名时，流量数字没有理由跟着一起失效。
  ///
  /// 注意这里不能用 `as List?` 来收 `connections`：`as List?` 只允许 null，
  /// 拿到字符串照样抛类型错误，反而把整份快照变成 null。
  static ClashSnapshot fromJson(Map<String, Object?> json) {
    final rawList = json['connections'];
    final connections = <ClashConnection>[];
    if (rawList is List) {
      for (final raw in rawList) {
        final conn = ClashConnection.fromJson(raw);
        if (conn != null) connections.add(conn);
      }
    }
    return ClashSnapshot(
      downloadTotal: _intOf(json['downloadTotal']),
      uploadTotal: _intOf(json['uploadTotal']),
      connections: connections,
      memory: _intOf(json['memory']),
    );
  }

  /// 只取累计流量，跳过连接列表的构造。
  ///
  /// 每秒都要更新速率，但连接列表只有在「有新连接」时才需要展开。
  /// 在连接数上千时，把这一步单独拆出来能省掉绝大部分每秒的分配。
  static ({int downloadTotal, int uploadTotal, int memory}) totalsOf(
    Map<String, Object?> json,
  ) {
    return (
      downloadTotal: _intOf(json['downloadTotal']),
      uploadTotal: _intOf(json['uploadTotal']),
      memory: _intOf(json['memory']),
    );
  }

  /// 单遍挑出「本次新出现」的连接，并把它们登记进 [seen]。
  ///
  /// 与「先构造全部、再过滤」相比，这里对已见过的连接只读一个 id 字段就跳过，
  /// 不会为它分配 [ClashConnection]、也不会为它拼展示用的 target 字符串。
  /// 连接数越大，这个差别越明显——而稳态下每秒新增的连接通常只有个位数。
  ///
  /// [seen] 由调用方持有并在重连时清空。它必须是**有容量上限**的集合，
  /// 否则长连接场景下会无限增长；见 [BoundedIdSet]。
  static List<ClashConnection> pullNew(
    Map<String, Object?> json,
    BoundedIdSet seen, {
    int limit = 8,
  }) {
    final rawList = json['connections'];
    if (rawList is! List) return const <ClashConnection>[];
    final result = <ClashConnection>[];
    for (final raw in rawList) {
      if (result.length >= limit) break;
      final id = ClashConnection.idOf(raw);
      if (id.isEmpty || seen.contains(id)) continue;
      final conn = ClashConnection.fromJson(raw);
      if (conn == null) continue;
      seen.add(id);
      result.add(conn);
    }
    return result;
  }

  /// 挑出本次新出现的连接（按 id 去重由调用方维护）。
  ///
  /// [limit] 限制单次上报数量，避免首次连接时把历史连接一次性刷屏。
  List<ClashConnection> newSince(Set<String> seen, {int limit = 8}) {
    final result = <ClashConnection>[];
    for (final conn in connections) {
      if (result.length >= limit) break;
      if (seen.contains(conn.id)) continue;
      result.add(conn);
    }
    return result;
  }

  static Map<String, Object?>? _decode(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    return decoded.cast<String, Object?>();
  }
}

/// 速率计算器：把「自启动以来的累计字节数」换算成瞬时速率。
///
/// 内核只给累计值，速率必须由相邻两次采样求差得到。第一次采样只能建立基准。
class RateCalculator {
  int _lastDownload = 0;
  int _lastUpload = 0;
  DateTime? _lastSampleAt;

  void reset() {
    _lastDownload = 0;
    _lastUpload = 0;
    _lastSampleAt = null;
  }

  /// 采样一次。返回 (下行速率, 上行速率, 总字节数)；首次采样返回 null。
  ({double downBps, double upBps, int totalBytes})? sample(
    DateTime now,
    int downloadTotal,
    int uploadTotal,
  ) {
    final previous = _lastSampleAt;
    _lastSampleAt = now;

    if (previous == null) {
      _lastDownload = downloadTotal;
      _lastUpload = uploadTotal;
      return null;
    }

    final seconds = now.difference(previous).inMilliseconds / 1000.0;
    final downDelta = downloadTotal - _lastDownload;
    final upDelta = uploadTotal - _lastUpload;
    _lastDownload = downloadTotal;
    _lastUpload = uploadTotal;

    if (seconds <= 0) return null;
    // 内核重启会让计数器归零，出现负值；按 0 处理而不是显示一个负数。
    return (
      downBps: downDelta < 0 ? 0.0 : downDelta / seconds,
      upBps: upDelta < 0 ? 0.0 : upDelta / seconds,
      totalBytes: downloadTotal + uploadTotal,
    );
  }
}
