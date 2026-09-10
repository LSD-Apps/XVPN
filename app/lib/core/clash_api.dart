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
library;

import 'dart:convert';

/// 一条连接（Clash API 快照里的元素）。
class ClashConnection {
  const ClashConnection({
    required this.id,
    required this.target,
    required this.rule,
    required this.outbound,
    required this.proxied,
  });

  final String id;

  /// 展示目标：优先域名，其次 IP（带端口）。
  final String target;

  /// 命中规则的展示名。
  final String rule;

  /// 实际走的出站标签。
  final String outbound;

  /// 是否走隧道。
  final bool proxied;

  static ClashConnection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;

    final metadata = (json['metadata'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final chains = (json['chains'] as List?) ?? const <Object?>[];
    final proxied = chains.any((c) => c.toString() == 'vpn');

    return ClashConnection(
      id: id,
      target: _targetOf(metadata),
      rule: _ruleOf(json),
      outbound: proxied ? 'vpn' : 'direct',
      proxied: proxied,
    );
  }

  /// 目标展示名：优先域名，其次 IP。
  static String _targetOf(Map<String, Object?> metadata) {
    final host = metadata['host']?.toString() ?? '';
    if (host.isNotEmpty) return host;
    final ip = metadata['destinationIP']?.toString() ?? '';
    final port = metadata['destinationPort']?.toString() ?? '';
    if (ip.isEmpty) return '(未知目标)';
    return port.isEmpty ? ip : '$ip:$port';
  }

  /// 命中规则的展示名。
  static String _ruleOf(Map<String, Object?> conn) {
    final rule = conn['rule']?.toString() ?? '';
    final payload = conn['rulePayload']?.toString() ?? '';
    if (payload.isNotEmpty) return payload;
    return switch (rule) {
      '' => '默认规则',
      'final' => '默认规则',
      'IpIsPrivate' => '局域网地址',
      'RuleSet' => '规则库',
      _ => rule,
    };
  }
}

/// 一次 `/connections` 快照。
class ClashSnapshot {
  const ClashSnapshot({
    required this.downloadTotal,
    required this.uploadTotal,
    required this.connections,
  });

  final int downloadTotal;
  final int uploadTotal;
  final List<ClashConnection> connections;

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
  static ClashSnapshot fromJson(Map<String, Object?> json) {
    final rawList = (json['connections'] as List?) ?? const <Object?>[];
    final connections = <ClashConnection>[];
    for (final raw in rawList) {
      final conn = ClashConnection.fromJson(raw);
      if (conn != null) connections.add(conn);
    }
    return ClashSnapshot(
      downloadTotal: (json['downloadTotal'] as num?)?.toInt() ?? 0,
      uploadTotal: (json['uploadTotal'] as num?)?.toInt() ?? 0,
      connections: connections,
    );
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
