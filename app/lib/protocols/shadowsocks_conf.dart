/// Shadowsocks 配置解析器。
///
/// 覆盖两种来源——面板与客户端实际给出的就是这两种：
///
///   1. **分享链接** `ss://…`（SIP002）：
///      * `ss://BASE64URL(method:password)@host:port/?plugin=…#备注`
///      * `ss://method:password@host:port`（userinfo 未做 base64、仅百分号编码）
///      * 旧式整串 `ss://BASE64(method:password@host:port)#备注`
///   2. **sing-box 出站 JSON**（`{"type": "shadowsocks", …}`，也支持从整份
///      配置的 `outbounds` 里挑出那一条）。
///
/// 不做 Clash YAML 作为**单节点**入口：本项目刻意不引入 `yaml` 包。
/// 多节点 Clash `proxies:` 由 `subscription.dart` 用缩进扫描处理。
///
/// 只做纯文本处理，不依赖任何平台能力，因此可以完整单元测试。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'parsed_profile.dart';
import 'vpn_protocol.dart';

/// 配置的来源形式。
enum ShadowsocksSource {
  link('分享链接'),
  json('sing-box 出站 JSON');

  const ShadowsocksSource(this.label);

  final String label;
}

/// sing-box 1.14 的 shadowsocks 出站认的加密方法。
///
/// 名字必须**原样**下发：内核按字符串精确匹配，大小写不对会 FATAL。
/// 解析阶段统一成小写再对这张表，认不出的方法直接报错——原样传下去用户只看到
/// 「连不上」。
const Set<String> shadowsocksMethods = <String>{
  'none',
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
  'aes-128-ctr',
  'aes-192-ctr',
  'aes-256-ctr',
  'aes-128-cfb',
  'aes-192-cfb',
  'aes-256-cfb',
  'rc4-md5',
  'chacha20-ietf',
  'xchacha20',
};

/// AEAD 方法。流密码仍被内核接受，但已过时，导入时给一条 info。
const Set<String> shadowsocksAeadMethods = <String>{
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
};

/// sing-box 随包内核认识的 SIP003 插件名。
const Set<String> shadowsocksKnownPlugins = <String>{
  'obfs-local',
  'v2ray-plugin',
};

/// 一份 Shadowsocks 配置的字段集合。
class ShadowsocksConf {
  const ShadowsocksConf({
    required this.server,
    required this.port,
    required this.method,
    required this.password,
    required this.source,
    this.plugin,
    this.pluginOpts,
    this.displayName,
    this.ignoredFields = const <String>[],
  });

  final String server;
  final int port;
  final String method;
  final String password;
  final ShadowsocksSource source;

  /// SIP003 插件名。为 null 表示未启用。
  final String? plugin;

  /// 插件参数，原样交给内核的 `plugin_opts`。
  final String? pluginOpts;

  final String? displayName;
  final List<String> ignoredFields;

  bool get usesPlugin => plugin != null && plugin!.isNotEmpty;

  bool get isAead => shadowsocksAeadMethods.contains(method);

  bool get isKnownPlugin =>
      plugin == null || shadowsocksKnownPlugins.contains(plugin);

  /// 刻意不回显口令：「配置文件」页会进截图。
  String get passwordDisplay => '已设置';

  /// 解析任意一种来源形式。
  static ShadowsocksConf parse(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      throw VpnConfigException('配置内容为空');
    }
    final firstLine = firstMeaningfulLine(raw);
    if (firstLine.toLowerCase().startsWith('ss://')) {
      return _parseLink(firstLine);
    }
    if (raw.startsWith('{')) {
      return _parseJson(raw);
    }
    throw VpnConfigException(
      '无法识别这份 Shadowsocks 配置。请使用 ss:// 分享链接，或 sing-box 的 shadowsocks 出站 JSON。',
    );
  }

  /// 取第一条非空且非注释的行。
  ///
  /// 与 Hysteria2 同一规则：面板导出常在链接前面写几行 `#` 说明，
  /// 识别与解析必须按同一条线切，否则会出现「能识别但解析报错」。
  static String firstMeaningfulLine(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) continue;
      return trimmed;
    }
    return '';
  }

  // ------------------------------------------------------------- 分享链接

  static ShadowsocksConf _parseLink(String raw) {
    var body = raw.substring(5); // 去掉 ss://，大小写已在入口判断
    // 兼容误写成 SS:// 后 substring 仍按长度切。
    if (raw.toLowerCase().startsWith('ss://')) {
      body = raw.substring(5);
    }

    String? displayName;
    final hash = body.indexOf('#');
    if (hash != -1) {
      displayName = _decodeSafe(body.substring(hash + 1).replaceAll('+', ' '));
      body = body.substring(0, hash);
    }

    String? query;
    final question = body.indexOf('?');
    if (question != -1) {
      query = body.substring(question + 1);
      body = body.substring(0, question);
    }

    final at = body.lastIndexOf('@');
    late final String method;
    late final String password;
    late final String hostPort;

    if (at == -1) {
      // 旧式：整段 userinfo@host:port 被塞进一坨 base64。
      final decoded = _decodeBase64Utf8(body);
      if (decoded == null) {
        throw VpnConfigException('这份 ss:// 链接无法解码，请确认复制完整');
      }
      final innerAt = decoded.lastIndexOf('@');
      if (innerAt == -1) {
        throw VpnConfigException('这份 ss:// 链接里没有服务器地址');
      }
      final userinfo = decoded.substring(0, innerAt);
      hostPort = decoded.substring(innerAt + 1);
      final split = _splitMethodPassword(userinfo);
      method = split.method;
      password = split.password;
    } else {
      hostPort = body.substring(at + 1);
      final userinfo = body.substring(0, at);
      // userinfo 里有 `:` 就是明文 `method:password`（可百分号编码）。
      // SIP002 的 base64 userinfo 用的是字母数字，不会出现冒号——
      // 若把 `bf-cfb:pw` 这种不在表里的明文再拿去当 base64，会得到一句
      // 「无法识别」而不是「不支持的加密方法」。
      if (userinfo.contains(':')) {
        final split = _splitMethodPassword(_decodeSafe(userinfo));
        method = split.method;
        password = split.password;
      } else {
        final decoded = _decodeBase64Utf8(userinfo);
        if (decoded == null) {
          throw VpnConfigException('这份 ss:// 链接的加密方法无法识别');
        }
        final split = _splitMethodPassword(decoded);
        method = split.method;
        password = split.password;
      }
    }

    final slash = hostPort.indexOf('/');
    final hostPortOnly = slash == -1 ? hostPort : hostPort.substring(0, slash);
    final (host, port) = _splitHostPort(hostPortOnly, defaultPort: 8388);
    if (host.isEmpty) {
      throw VpnConfigException('分享链接里没有服务器地址');
    }

    String? plugin;
    String? pluginOpts;
    final ignored = <String>[];
    for (final entry in _parseQuery(query).entries) {
      if (entry.key == 'plugin') {
        final spec = entry.value.trim();
        if (spec.isEmpty) continue;
        final semi = spec.indexOf(';');
        if (semi == -1) {
          plugin = spec;
        } else {
          plugin = spec.substring(0, semi);
          pluginOpts = spec.substring(semi + 1);
        }
      } else {
        ignored.add(entry.key);
      }
    }

    return _build(
      server: host,
      port: port,
      method: method,
      password: password,
      source: ShadowsocksSource.link,
      plugin: plugin,
      pluginOpts: pluginOpts,
      displayName: displayName,
      ignored: ignored,
    );
  }

  static ({String method, String password}) _splitMethodPassword(String raw) {
    final colon = raw.indexOf(':');
    if (colon <= 0) {
      throw VpnConfigException('这份 ss:// 链接缺少加密方法或密码');
    }
    return (
      method: raw.substring(0, colon).trim().toLowerCase(),
      password: raw.substring(colon + 1),
    );
  }

  // ---------------------------------------------------------------- JSON

  static ShadowsocksConf _parseJson(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw VpnConfigException('这份 JSON 无法解析：${e.message}');
    }
    if (decoded is! Map) {
      throw VpnConfigException('这份 JSON 不是对象，无法作为出站配置');
    }
    var node = decoded.cast<String, Object?>();

    final outbounds = node['outbounds'];
    if (outbounds is List) {
      Map<String, Object?>? found;
      for (final item in outbounds) {
        if (item is Map && item['type'] == 'shadowsocks') {
          found = item.cast<String, Object?>();
          break;
        }
      }
      if (found == null) {
        throw VpnConfigException('这份 sing-box 配置里没有 shadowsocks 出站');
      }
      node = found;
    }

    final type = node['type'];
    if (type != null && type != 'shadowsocks') {
      throw VpnConfigException('这份 JSON 的出站类型是「$type」，不是 shadowsocks');
    }

    const known = <String>{
      'type',
      'tag',
      'server',
      'server_port',
      'method',
      'password',
      'plugin',
      'plugin_opts',
      'network',
      'udp_over_tcp',
      'multiplex',
      'domain_resolver',
    };
    final ignored = <String>[
      for (final key in node.keys)
        if (!known.contains(key)) key,
    ];
    if (node.containsKey('udp_over_tcp')) ignored.add('udp_over_tcp');
    if (node.containsKey('multiplex')) ignored.add('multiplex');
    if (node.containsKey('network')) ignored.add('network');

    return _build(
      server: _asString(node['server']) ?? '',
      port: _asInt(node['server_port']) ?? 8388,
      method: (_asString(node['method']) ?? '').trim().toLowerCase(),
      password: _asString(node['password']) ?? '',
      source: ShadowsocksSource.json,
      plugin: _asString(node['plugin']),
      pluginOpts: _asString(node['plugin_opts']),
      displayName: _asString(node['tag']),
      ignored: ignored,
    );
  }

  static ShadowsocksConf _build({
    required String server,
    required int port,
    required String method,
    required String password,
    required ShadowsocksSource source,
    String? plugin,
    String? pluginOpts,
    String? displayName,
    List<String> ignored = const <String>[],
  }) {
    final host = server.trim();
    if (host.isEmpty) {
      throw VpnConfigException('缺少服务器地址');
    }
    if (port < 1 || port > 65535) {
      throw VpnConfigException('端口不合法：$port');
    }
    if (!shadowsocksMethods.contains(method)) {
      throw VpnConfigException(
        '不支持的加密方法「$method」。内核认识的是 '
        '${shadowsocksAeadMethods.join(' / ')} 等，请改成其中之一。',
      );
    }
    if (password.isEmpty && method != 'none') {
      throw VpnConfigException('缺少密码。Shadowsocks 出站必须有 password');
    }
    final pluginName = plugin?.trim();
    final opts = pluginOpts?.trim();
    return ShadowsocksConf(
      server: host,
      port: port,
      method: method,
      password: password,
      source: source,
      plugin: (pluginName == null || pluginName.isEmpty) ? null : pluginName,
      pluginOpts: (opts == null || opts.isEmpty) ? null : opts,
      displayName: displayName?.trim().isEmpty == true ? null : displayName?.trim(),
      ignoredFields: List<String>.of(ignored)..sort(),
    );
  }

  /// 生成 SIP002 分享链接。表单往返只走这一条路径。
  String toShareLink() {
    final userinfo = base64Url
        .encode(utf8.encode('$method:$password'))
        .replaceAll('=', '');
    final buffer = StringBuffer('ss://$userinfo@${_urlHost(server)}:$port');
    if (usesPlugin) {
      final spec = pluginOpts == null ? plugin! : '$plugin;$pluginOpts';
      buffer.write('/?plugin=${Uri.encodeQueryComponent(spec)}');
    }
    final remark = displayName;
    if (remark != null && remark.isNotEmpty) {
      buffer.write('#${Uri.encodeComponent(remark)}');
    }
    return buffer.toString();
  }
}

/// Shadowsocks 配置的协议无关视图。
class ShadowsocksProfile extends ParsedProfile {
  const ShadowsocksProfile(this.conf);

  final ShadowsocksConf conf;

  @override
  VpnProtocol get protocol => VpnProtocol.shadowsocks;

  @override
  String get serverDisplay => '${conf.server}:${conf.port}';

  @override
  String get addressDisplay => '—';

  @override
  String get dnsDisplay => '内置策略';

  @override
  List<String> get declaredDns => const <String>[];

  @override
  bool get hasIpv6 => false;

  @override
  bool get needsIpv4OnlyDns => false;

  @override
  bool get wantsDebugLogs => false;

  @override
  bool get requiresCredentials => false;

  @override
  int? get declaredMtu => null;

  @override
  List<({String label, String value})> get details =>
      <({String label, String value})>[
        (label: '服务器', value: serverDisplay),
        (label: '加密', value: conf.method),
        (label: '密码', value: conf.passwordDisplay),
        (label: '来源', value: conf.source.label),
        (
          label: '插件',
          value: conf.usesPlugin
              ? (conf.pluginOpts == null
                    ? conf.plugin!
                    : '${conf.plugin}; ${conf.pluginOpts}')
              : '未启用',
        ),
        if (conf.displayName != null && conf.displayName!.isNotEmpty)
          (label: '备注', value: conf.displayName!),
      ];

  @override
  List<String> get unusedKeys => conf.ignoredFields;

  @override
  List<ProfileNotice> get notices {
    final out = <ProfileNotice>[];
    if (!conf.isAead && conf.method != 'none') {
      out.add(
        ProfileNotice.info(
          '加密方法 ${conf.method} 是流密码，已被认为过时。'
          '能改的话请换成 aes-256-gcm 或 chacha20-ietf-poly1305。',
        ),
      );
    }
    if (conf.usesPlugin && !conf.isKnownPlugin) {
      out.add(
        ProfileNotice.warn(
          '插件「${conf.plugin}」不是随包内核认识的 SIP003 插件'
          '（obfs-local / v2ray-plugin）。导入后多半连不上。',
        ),
      );
    }
    return out;
  }
}

// ---------------------------------------------------------------- 取值助手

String _decodeSafe(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } on ArgumentError {
    return raw;
  }
}

Uint8List? _decodeBase64Bytes(String raw) {
  var s = raw.trim().replaceAll('-', '+').replaceAll('_', '/');
  s = s.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
  if (s.isEmpty) return null;
  switch (s.length % 4) {
    case 1:
      return null;
    case 2:
      s += '==';
    case 3:
      s += '=';
  }
  try {
    return base64.decode(s);
  } on FormatException {
    return null;
  }
}

String? _decodeBase64Utf8(String raw) {
  final bytes = _decodeBase64Bytes(raw);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

Map<String, String> _parseQuery(String? query) {
  if (query == null || query.isEmpty) return const <String, String>{};
  final out = <String, String>{};
  for (final part in query.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    if (eq == -1) {
      out[_decodeSafe(part)] = '';
    } else {
      out[_decodeSafe(part.substring(0, eq))] = _decodeSafe(part.substring(eq + 1));
    }
  }
  return out;
}

(String, int) _splitHostPort(String raw, {required int defaultPort}) {
  var s = raw.trim();
  if (s.isEmpty) return ('', defaultPort);
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close == -1) return (s, defaultPort);
    final host = s.substring(1, close);
    var port = defaultPort;
    if (close + 1 < s.length && s[close + 1] == ':') {
      port = int.tryParse(s.substring(close + 2)) ?? defaultPort;
    }
    return (host, port);
  }
  final colon = s.lastIndexOf(':');
  if (colon == -1) return (s, defaultPort);
  // 裸 IPv6 没有括号时会有多处冒号，不能按最后一个切。
  if (s.indexOf(':') != colon && !s.contains('.')) {
    return (s, defaultPort);
  }
  final host = s.substring(0, colon);
  final port = int.tryParse(s.substring(colon + 1)) ?? defaultPort;
  return (host, port);
}

String _urlHost(String host) => host.contains(':') ? '[$host]' : host;

String? _asString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
