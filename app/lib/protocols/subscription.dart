/// 用户自备订阅 / 多节点清单的解析。
///
/// 这不是节点市场：地址与正文都必须由用户自己提供。本模块只做格式识别，
/// 不内置任何 URL，也不猜测「该用哪一家」。法律边界见 `docs/LEGAL.md`。
///
/// 认三种正文（现实里订阅接口给出的就是这三种）：
///
///   1. 一行一条分享链接（`ss://` / `vmess://` / `vless://` / `trojan://` /
///      `hysteria2://` / `hy2://`），允许整段再套一层标准 Base64；
///   2. sing-box JSON：整份配置的 `outbounds[]`，或单个出站对象；
///   3. Clash YAML 的 `proxies:` 列表——只映射本项目已经能导入的协议，
///      不引入 `yaml` 包：订阅正文是一份受限的键值列表，用缩进扫描就够。
///
/// 认不出的节点记进 [skipped]，不让整份失败。用户看到的是「导入了 N 个、
/// 跳过了 M 个」，而不是一句「无法识别」。
library;

import 'dart:convert';

import 'parsed_profile.dart';
import 'protocol_adapter.dart';

/// 分享链接的协议前缀。大小写不敏感，匹配时统一小写。
const List<String> shareLinkSchemes = <String>[
  'ss://',
  'vmess://',
  'vless://',
  'trojan://',
  'hysteria2://',
  'hy2://',
];

/// 内核配置里可以变成一条独立配置的出站类型。
const Set<String> importableOutboundTypes = <String>{
  'shadowsocks',
  'vmess',
  'vless',
  'trojan',
  'hysteria2',
};

/// 一份订阅 / 多节点正文拆出来的结果。
class SubscriptionDocument {
  const SubscriptionDocument({
    required this.nodes,
    this.skipped = const <String>[],
    this.userinfo,
  });

  final List<SubscriptionNode> nodes;
  final List<String> skipped;

  /// `subscription-userinfo` 响应头原文，没有则为 null。
  final String? userinfo;

  bool get isEmpty => nodes.isEmpty;
}

/// 订阅里的一个节点：能再交给 [VpnProtocolFactory.parse] 的文本。
class SubscriptionNode {
  const SubscriptionNode({
    required this.name,
    required this.text,
  });

  /// 展示名（链接 fragment / JSON tag / Clash name）。
  final String name;

  /// 单节点配置正文。
  final String text;
}

/// HTTP 拉取结果。测试注入假实现时只填这两项。
class SubscriptionFetchResult {
  const SubscriptionFetchResult({required this.body, this.userinfo});

  final String body;
  final String? userinfo;
}

typedef SubscriptionFetcher = Future<SubscriptionFetchResult> Function(Uri url);

/// 这段文本是不是用户粘贴的 **http(s) 订阅地址**（一整段、没有换行里的配置）。
///
/// 分享链接的 scheme 不是 http，WireGuard / OpenVPN 正文也不会是单个 URL。
/// 误把文档站首页当成订阅去拉，解析阶段会失败并说明「不是节点列表」。
bool looksLikeSubscriptionUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains('\n')) return false;
  if (_startsWithShareScheme(trimmed)) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'https' || scheme == 'http';
}

/// 解析订阅正文。空结果表示这份文本应按「单份配置」走原有工厂，而不是订阅。
///
/// 单条分享链接也返回 1 个节点——调用方用 [nodes.length] 决定走批量还是表单。
SubscriptionDocument? parseSubscriptionBody(
  String text, {
  String? userinfo,
  String fallbackName = '节点',
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  final fromJson = _parseSingBox(trimmed, fallbackName: fallbackName);
  if (fromJson != null && fromJson.nodes.length >= 2) return fromJson;
  // 单个出站 JSON 仍走原工厂，确认表单能核对字段。

  if (_looksLikeClash(trimmed)) {
    return _parseClash(trimmed, fallbackName: fallbackName, userinfo: userinfo);
  }

  final decoded = _maybeDecodeBase64List(trimmed);
  final fromLinks = _parseShareLinks(
    decoded ?? trimmed,
    fallbackName: fallbackName,
    userinfo: userinfo,
  );
  if (fromLinks != null && fromLinks.nodes.isNotEmpty) return fromLinks;

  // Clash 失败、链接也没有：若 JSON 抽出了恰好 1 个出站，交给单节点路径。
  return null;
}

/// 把 Clash / 多链接正文里抽出的节点再经工厂校验，丢掉解析失败的。
SubscriptionDocument materialize(
  SubscriptionDocument raw, {
  String Function(String text, String fileName)? parseCheck,
}) {
  final nodes = <SubscriptionNode>[];
  final skipped = List<String>.from(raw.skipped);
  for (final node in raw.nodes) {
    try {
      if (parseCheck != null) {
        parseCheck(node.text, '${node.name}.txt');
      } else {
        VpnProtocolFactory.parse(node.text, '${node.name}.txt');
      }
      nodes.add(node);
    } on VpnConfigException catch (e) {
      skipped.add('${node.name}：${e.message}');
    } on Object catch (e) {
      skipped.add('${node.name}：$e');
    }
  }
  return SubscriptionDocument(
    nodes: nodes,
    skipped: skipped,
    userinfo: raw.userinfo,
  );
}

// ---------------------------------------------------------------- 分享链接

bool _startsWithShareScheme(String line) {
  final lower = line.trimLeft().toLowerCase();
  for (final scheme in shareLinkSchemes) {
    if (lower.startsWith(scheme)) return true;
  }
  return false;
}

SubscriptionDocument? _parseShareLinks(
  String text, {
  required String fallbackName,
  String? userinfo,
}) {
  final nodes = <SubscriptionNode>[];
  var index = 0;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#') && !_startsWithShareScheme(line)) continue;
    if (!_startsWithShareScheme(line)) continue;
    index++;
    nodes.add(
      SubscriptionNode(
        name: _nameFromShareLink(line) ?? '$fallbackName $index',
        text: line,
      ),
    );
  }
  if (nodes.isEmpty) return null;
  return SubscriptionDocument(nodes: nodes, userinfo: userinfo);
}

String? _nameFromShareLink(String line) {
  final hash = line.lastIndexOf('#');
  if (hash <= 0 || hash == line.length - 1) return null;
  // vmess:// 的 fragment 不是备注（正文是 base64 JSON），不在这里取。
  if (line.toLowerCase().startsWith('vmess://')) return _vmessRemark(line);
  try {
    return Uri.decodeComponent(line.substring(hash + 1)).replaceAll('+', ' ');
  } on FormatException {
    return line.substring(hash + 1);
  }
}

String? _vmessRemark(String line) {
  final payload = line.substring('vmess://'.length).trim();
  final decoded = _decodeBase64(payload.split('#').first);
  if (decoded == null) return null;
  try {
    final json = jsonDecode(decoded);
    if (json is Map && json['ps'] is String) {
      final ps = (json['ps'] as String).trim();
      if (ps.isNotEmpty) return ps;
    }
  } on Object {
    return null;
  }
  return null;
}

/// 整段是 Base64 的分享链接列表时解码一次。解码后仍不像链接则返回 null。
String? _maybeDecodeBase64List(String text) {
  if (text.contains('://')) return null;
  // 订阅接口常把正文折行。去空白再解。
  final compact = text.replaceAll(RegExp(r'\s'), '');
  if (compact.length < 16) return null;
  final decoded = _decodeBase64(compact);
  if (decoded == null) return null;
  if (!_looksLikeLinkList(decoded)) return null;
  return decoded;
}

bool _looksLikeLinkList(String text) {
  var n = 0;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    if (_startsWithShareScheme(raw)) n++;
    if (n >= 1) return true;
  }
  return false;
}

String? _decodeBase64(String raw) {
  var s = raw.trim();
  s = s.replaceAll('-', '+').replaceAll('_', '/');
  final pad = s.length % 4;
  if (pad != 0) s = s.padRight(s.length + (4 - pad), '=');
  try {
    return utf8.decode(base64.decode(s));
  } on Object {
    return null;
  }
}

// ---------------------------------------------------------------- sing-box JSON

SubscriptionDocument? _parseSingBox(String text, {required String fallbackName}) {
  if (!text.startsWith('{') && !text.startsWith('[')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on Object {
    return null;
  }

  final outbounds = <Map<String, Object?>>[];
  if (decoded is Map) {
    final list = decoded['outbounds'];
    if (list is List) {
      for (final item in list) {
        if (item is Map) outbounds.add(item.cast<String, Object?>());
      }
    } else if (decoded['type'] is String) {
      outbounds.add(decoded.cast<String, Object?>());
    }
  } else if (decoded is List) {
    for (final item in decoded) {
      if (item is Map) outbounds.add(item.cast<String, Object?>());
    }
  }
  if (outbounds.isEmpty) return null;

  final nodes = <SubscriptionNode>[];
  final skipped = <String>[];
  var index = 0;
  for (final outbound in outbounds) {
    final type = outbound['type']?.toString() ?? '';
    if (!importableOutboundTypes.contains(type)) {
      if (type.isNotEmpty &&
          type != 'direct' &&
          type != 'block' &&
          type != 'dns' &&
          type != 'selector' &&
          type != 'urltest') {
        skipped.add('跳过出站类型「$type」');
      }
      continue;
    }
    index++;
    final tag = outbound['tag']?.toString().trim();
    nodes.add(
      SubscriptionNode(
        name: (tag != null && tag.isNotEmpty) ? tag : '$fallbackName $index',
        text: const JsonEncoder.withIndent('  ').convert(outbound),
      ),
    );
  }
  if (nodes.isEmpty) return null;
  return SubscriptionDocument(nodes: nodes, skipped: skipped);
}

// ---------------------------------------------------------------- Clash YAML

bool _looksLikeClash(String text) {
  return RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(text);
}

SubscriptionDocument _parseClash(
  String text, {
  required String fallbackName,
  String? userinfo,
}) {
  final proxies = _extractClashProxies(text);
  final nodes = <SubscriptionNode>[];
  final skipped = <String>[];
  var index = 0;
  for (final proxy in proxies) {
    final type = (proxy['type'] ?? '').toLowerCase();
    final name = proxy['name']?.trim();
    index++;
    final label =
        (name != null && name.isNotEmpty) ? name : '$fallbackName $index';
    final outbound = _clashToOutbound(proxy);
    if (outbound == null) {
      skipped.add(
        type.isEmpty ? '「$label」缺少 type' : '「$label」的 Clash 类型「$type」暂不导入',
      );
      continue;
    }
    nodes.add(
      SubscriptionNode(
        name: label,
        text: const JsonEncoder.withIndent('  ').convert(outbound),
      ),
    );
  }
  return SubscriptionDocument(
    nodes: nodes,
    skipped: skipped,
    userinfo: userinfo,
  );
}

/// 扫描 `proxies:` 下列出的映射。不实现 YAML 锚点 / 合并键 / 多文档。
List<Map<String, String>> _extractClashProxies(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^\s*proxies\s*:').hasMatch(lines[i])) {
      start = i + 1;
      break;
    }
  }
  if (start < 0) return const <Map<String, String>>[];

  final result = <Map<String, String>>[];
  Map<String, String>? current;
  for (var i = start; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    // 顶格新键：proxies 列表结束。
    if (indent == 0 && !line.trimLeft().startsWith('-')) break;

    final trimmed = line.trim();
    if (trimmed.startsWith('-')) {
      if (current != null && current.isNotEmpty) result.add(current);
      current = <String, String>{};
      final rest = trimmed.substring(1).trim();
      if (rest.startsWith('{')) {
        current.addAll(_parseFlowMap(rest));
        result.add(current);
        current = null;
      } else if (rest.contains(':')) {
        _putPair(current, rest);
      }
      continue;
    }
    if (current == null) continue;
    if (trimmed.contains(':')) _putPair(current, trimmed);
  }
  if (current != null && current.isNotEmpty) result.add(current);
  return result;
}

void _putPair(Map<String, String> target, String pair) {
  final idx = pair.indexOf(':');
  if (idx <= 0) return;
  final key = pair.substring(0, idx).trim();
  var value = pair.substring(idx + 1).trim();
  if (value.length >= 2) {
    final quote = value[0];
    if ((quote == '"' || quote == "'") && value.endsWith(quote)) {
      value = value.substring(1, value.length - 1);
    }
  }
  if (key.isEmpty) return;
  target[key] = value;
}

Map<String, String> _parseFlowMap(String raw) {
  var s = raw.trim();
  if (s.startsWith('{')) s = s.substring(1);
  if (s.endsWith('}')) s = s.substring(0, s.length - 1);
  final result = <String, String>{};
  for (final part in _splitFlowFields(s)) {
    _putPair(result, part);
  }
  return result;
}

List<String> _splitFlowFields(String s) {
  final parts = <String>[];
  final buf = StringBuffer();
  var quote = '';
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quote.isEmpty && (ch == '"' || ch == "'")) {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (quote.isNotEmpty) {
      buf.write(ch);
      if (ch == quote) quote = '';
      continue;
    }
    if (ch == ',') {
      final piece = buf.toString().trim();
      if (piece.isNotEmpty) parts.add(piece);
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  final last = buf.toString().trim();
  if (last.isNotEmpty) parts.add(last);
  return parts;
}

Map<String, Object?>? _clashToOutbound(Map<String, String> proxy) {
  final type = (proxy['type'] ?? '').trim().toLowerCase();
  final server = proxy['server']?.trim() ?? '';
  final port = int.tryParse(proxy['port'] ?? '') ?? 0;
  if (server.isEmpty || port <= 0) return null;
  final tag = proxy['name']?.trim();
  return switch (type) {
    'ss' || 'shadowsocks' => _clashSs(proxy, server, port, tag),
    'vmess' => _clashVmess(proxy, server, port, tag),
    'vless' => _clashVless(proxy, server, port, tag),
    'trojan' => _clashTrojan(proxy, server, port, tag),
    'hysteria2' || 'hy2' => _clashHy2(proxy, server, port, tag),
    _ => null,
  };
}

Map<String, Object?> _clashSs(
  Map<String, String> proxy,
  String server,
  int port,
  String? tag,
) {
  final outbound = <String, Object?>{
    'type': 'shadowsocks',
    'server': server,
    'server_port': port,
    'method': (proxy['cipher'] ?? proxy['method'] ?? '').toLowerCase(),
    'password': proxy['password'] ?? '',
    'tag': ?tag,
  };
  final plugin = proxy['plugin']?.trim();
  if (plugin != null && plugin.isNotEmpty) {
    outbound['plugin'] = plugin;
    final opts = proxy['plugin-opts'] ?? proxy['plugin_opts'];
    if (opts != null && opts.isNotEmpty) outbound['plugin_opts'] = opts;
  }
  return outbound;
}

Map<String, Object?> _clashVmess(
  Map<String, String> proxy,
  String server,
  int port,
  String? tag,
) {
  final outbound = <String, Object?>{
    'type': 'vmess',
    'server': server,
    'server_port': port,
    'uuid': proxy['uuid'] ?? proxy['password'] ?? '',
    'security': (proxy['cipher'] ?? 'auto').toLowerCase(),
    'tag': ?tag,
  };
  final alter = int.tryParse(proxy['alterId'] ?? proxy['alterid'] ?? '');
  if (alter != null) outbound['alter_id'] = alter;
  _applyClashTransport(outbound, proxy);
  _applyClashTls(outbound, proxy, defaultEnabled: proxy['tls'] == 'true');
  return outbound;
}

Map<String, Object?> _clashVless(
  Map<String, String> proxy,
  String server,
  int port,
  String? tag,
) {
  final outbound = <String, Object?>{
    'type': 'vless',
    'server': server,
    'server_port': port,
    'uuid': proxy['uuid'] ?? proxy['password'] ?? '',
    'packet_encoding': 'xudp',
    'tag': ?tag,
  };
  final flow = proxy['flow']?.trim();
  if (flow != null && flow.isNotEmpty) outbound['flow'] = flow;
  _applyClashTransport(outbound, proxy);
  _applyClashTls(
    outbound,
    proxy,
    defaultEnabled: proxy['tls'] != 'false',
  );
  return outbound;
}

Map<String, Object?> _clashTrojan(
  Map<String, String> proxy,
  String server,
  int port,
  String? tag,
) {
  final outbound = <String, Object?>{
    'type': 'trojan',
    'server': server,
    'server_port': port,
    'password': proxy['password'] ?? '',
    'tag': ?tag,
  };
  _applyClashTransport(outbound, proxy);
  _applyClashTls(outbound, proxy, defaultEnabled: true);
  return outbound;
}

Map<String, Object?> _clashHy2(
  Map<String, String> proxy,
  String server,
  int port,
  String? tag,
) {
  return <String, Object?>{
    'type': 'hysteria2',
    'server': server,
    'server_port': port,
    'password': proxy['password'] ?? proxy['auth'] ?? '',
    'tag': ?tag,
    'tls': <String, Object?>{
      'enabled': true,
      'server_name': proxy['sni'] ?? proxy['servername'] ?? server,
      'insecure': proxy['skip-cert-verify'] == 'true',
    },
  };
}

void _applyClashTransport(Map<String, Object?> outbound, Map<String, String> proxy) {
  final network = (proxy['network'] ?? proxy['net'] ?? 'tcp').toLowerCase();
  if (network == 'tcp' || network.isEmpty) return;
  if (network == 'ws') {
    outbound['transport'] = <String, Object?>{
      'type': 'ws',
      if ((proxy['ws-path'] ?? proxy['path']) != null)
        'path': proxy['ws-path'] ?? proxy['path'],
      if ((proxy['ws-headers'] ?? proxy['host']) != null)
        'headers': <String, Object?>{
          'Host': proxy['ws-host'] ?? proxy['host'] ?? proxy['server'] ?? '',
        },
    };
    return;
  }
  if (network == 'grpc') {
    outbound['transport'] = <String, Object?>{
      'type': 'grpc',
      'service_name': proxy['grpc-service-name'] ?? proxy['serviceName'] ?? '',
    };
  }
}

void _applyClashTls(
  Map<String, Object?> outbound,
  Map<String, String> proxy, {
  required bool defaultEnabled,
}) {
  final enabled = proxy['tls'] == 'true' ||
      (proxy['security'] ?? '').toLowerCase() == 'tls' ||
      defaultEnabled && proxy['tls'] != 'false';
  if (!enabled && (proxy['sni'] == null && proxy['servername'] == null)) {
    return;
  }
  outbound['tls'] = <String, Object?>{
    'enabled': enabled || defaultEnabled,
    'server_name': proxy['sni'] ?? proxy['servername'] ?? proxy['server'],
    'insecure': proxy['skip-cert-verify'] == 'true',
  };
}
