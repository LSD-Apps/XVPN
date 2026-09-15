/// VMess / VLESS / Trojan 共用解析。
///
/// 三种协议的分享链接与 sing-box 出站 JSON 结构高度同源：都是
/// `server` + 凭据 + 可选 `tls` + 可选 V2Ray 传输层。拆成三份解析器会把
/// 「ws path 怎么映射」「reality 缺公钥怎么报错」复制三遍，改一处漏两处。
/// 协议差异只留在凭据字段与默认 TLS。
///
/// 不做 Clash YAML：与 Shadowsocks 同一条约束，YAML 入口留给订阅。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'parsed_profile.dart';
import 'vpn_protocol.dart';

enum V2RayKind {
  vmess,
  vless,
  trojan;

  VpnProtocol get protocol => switch (this) {
    V2RayKind.vmess => VpnProtocol.vmess,
    V2RayKind.vless => VpnProtocol.vless,
    V2RayKind.trojan => VpnProtocol.trojan,
  };

  String get outboundType => name;

  String get shareScheme => name;

  String get label => protocol.label;
}

enum V2RayTransportKind { tcp, ws, grpc, http, httpupgrade, quic }

enum V2RaySecurity { none, tls, reality }

/// 内核认识的 VMess 加密。名字必须原样下发。
const Set<String> vmessSecurities = <String>{
  'auto',
  'none',
  'zero',
  'aes-128-gcm',
  'chacha20-poly1305',
  'aes-128-ctr',
};

const Set<String> vlessFlows = <String>{'', 'xtls-rprx-vision'};

class V2RayTransport {
  const V2RayTransport({
    required this.kind,
    this.path,
    this.host,
    this.serviceName,
  });

  final V2RayTransportKind kind;
  final String? path;
  final String? host;
  final String? serviceName;

  String get label => switch (kind) {
    V2RayTransportKind.tcp => 'TCP',
    V2RayTransportKind.ws => 'WebSocket',
    V2RayTransportKind.grpc => 'gRPC',
    V2RayTransportKind.http => 'HTTP',
    V2RayTransportKind.httpupgrade => 'HTTPUpgrade',
    V2RayTransportKind.quic => 'QUIC',
  };

  Map<String, Object?>? toJson() {
    if (kind == V2RayTransportKind.tcp) return null;
    return switch (kind) {
      V2RayTransportKind.ws => <String, Object?>{
        'type': 'ws',
        if (path != null && path!.isNotEmpty) 'path': path,
        if (host != null && host!.isNotEmpty)
          'headers': <String, Object?>{'Host': host},
      },
      V2RayTransportKind.grpc => <String, Object?>{
        'type': 'grpc',
        if (serviceName != null && serviceName!.isNotEmpty)
          'service_name': serviceName,
      },
      V2RayTransportKind.http => <String, Object?>{
        'type': 'http',
        if (path != null && path!.isNotEmpty) 'path': path,
        if (host != null && host!.isNotEmpty) 'host': <String>[host!],
      },
      V2RayTransportKind.httpupgrade => <String, Object?>{
        'type': 'httpupgrade',
        if (path != null && path!.isNotEmpty) 'path': path,
        if (host != null && host!.isNotEmpty) 'host': host,
      },
      V2RayTransportKind.quic => <String, Object?>{'type': 'quic'},
      V2RayTransportKind.tcp => null,
    };
  }
}

class V2RayTls {
  const V2RayTls({
    required this.security,
    this.serverName,
    this.insecure = false,
    this.fingerprint,
    this.realityPublicKey,
    this.realityShortId,
  });

  final V2RaySecurity security;
  final String? serverName;
  final bool insecure;
  final String? fingerprint;
  final String? realityPublicKey;
  final String? realityShortId;

  bool get enabled => security != V2RaySecurity.none;

  Map<String, Object?> toJson() {
    final tls = <String, Object?>{
      'enabled': true,
      if (serverName != null && serverName!.isNotEmpty)
        'server_name': serverName,
      if (insecure) 'insecure': true,
    };
    final fp = fingerprint?.trim();
    if (fp != null && fp.isNotEmpty) {
      tls['utls'] = <String, Object?>{'enabled': true, 'fingerprint': fp};
    }
    if (security == V2RaySecurity.reality) {
      tls['utls'] ??= <String, Object?>{
        'enabled': true,
        'fingerprint': (fp == null || fp.isEmpty) ? 'chrome' : fp,
      };
      tls['reality'] = <String, Object?>{
        'enabled': true,
        'public_key': realityPublicKey,
        if (realityShortId != null && realityShortId!.isNotEmpty)
          'short_id': realityShortId,
      };
    }
    return tls;
  }
}

class V2RayConf {
  const V2RayConf({
    required this.kind,
    required this.server,
    required this.port,
    required this.secret,
    required this.transport,
    this.tls,
    this.vmessSecurity = 'auto',
    this.alterId = 0,
    this.flow,
    this.displayName,
    this.ignoredFields = const <String>[],
  });

  final V2RayKind kind;
  final String server;
  final int port;

  /// VMess / VLESS 是 UUID，Trojan 是密码。详情页不回显。
  final String secret;
  final V2RayTransport transport;
  final V2RayTls? tls;
  final String vmessSecurity;
  final int alterId;
  final String? flow;
  final String? displayName;
  final List<String> ignoredFields;

  String get secretDisplay => kind == V2RayKind.trojan ? '已设置' : '已设置 UUID';

  static V2RayConf parse(String text, V2RayKind kind) {
    final raw = text.trim();
    if (raw.isEmpty) {
      throw VpnConfigException('配置内容为空');
    }
    final firstLine = firstMeaningfulLine(raw);
    final scheme = '${kind.shareScheme}://';
    if (firstLine.toLowerCase().startsWith(scheme)) {
      return kind == V2RayKind.vmess
          ? _parseVmessLink(firstLine)
          : _parseUriLink(firstLine, kind);
    }
    if (raw.startsWith('{')) {
      return _parseJson(raw, kind);
    }
    throw VpnConfigException(
      '无法识别这份 ${kind.label} 配置。请使用 ${kind.shareScheme}:// 分享链接，'
      '或 sing-box 的 ${kind.outboundType} 出站 JSON。',
    );
  }

  static String firstMeaningfulLine(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) continue;
      return trimmed;
    }
    return '';
  }

  static bool looksLike(String text, V2RayKind kind) {
    final trimmed = text.trimLeft();
    final first = firstMeaningfulLine(trimmed).toLowerCase();
    if (first.startsWith('${kind.shareScheme}://')) return true;
    if (!trimmed.startsWith('{')) return false;
    final lower = trimmed.toLowerCase();
    return lower.contains('"${kind.outboundType}"') &&
        (lower.contains('"server"') || lower.contains('"uuid"'));
  }

  // ------------------------------------------------------------- vmess://

  static V2RayConf _parseVmessLink(String raw) {
    var body = raw.substring(8);
    final hash = body.indexOf('#');
    String? fragmentName;
    if (hash != -1) {
      fragmentName = _decodeSafe(body.substring(hash + 1).replaceAll('+', ' '));
      body = body.substring(0, hash);
    }
    final decoded = _decodeBase64Utf8(body);
    if (decoded == null) {
      throw VpnConfigException('这份 vmess:// 链接无法解码，请确认复制完整');
    }
    final Object? json;
    try {
      json = jsonDecode(decoded);
    } on FormatException {
      throw VpnConfigException('这份 vmess:// 链接的内容不是 JSON');
    }
    if (json is! Map) {
      throw VpnConfigException('这份 vmess:// 链接的内容不是对象');
    }
    final node = json.cast<String, Object?>();
    final port = _asInt(node['port']) ?? 443;
    final aid = _asInt(node['aid']) ?? 0;
    final net = (_asString(node['net']) ?? 'tcp').trim();
    final tlsRaw = (_asString(node['tls']) ?? '').trim().toLowerCase();
    final security = switch (tlsRaw) {
      'tls' || 'xtls' => V2RaySecurity.tls,
      'reality' => V2RaySecurity.reality,
      _ => V2RaySecurity.none,
    };
    final path = _asString(node['path']);
    final host = _asString(node['host']);
    final sni = _asString(node['sni']) ?? host;
    final scy = (_asString(node['scy']) ?? 'auto').trim().toLowerCase();
    final ignored = <String>[];
    for (final key in node.keys) {
      const known = <String>{
        'v',
        'ps',
        'add',
        'port',
        'id',
        'aid',
        'scy',
        'net',
        'type',
        'headerType',
        'host',
        'path',
        'tls',
        'sni',
        'alpn',
        'fp',
        'pbk',
        'sid',
      };
      if (!known.contains(key)) ignored.add(key);
    }
    return _build(
      kind: V2RayKind.vmess,
      server: _asString(node['add']) ?? '',
      port: port,
      secret: _asString(node['id']) ?? '',
      transport: _transportFromShare(
        net: net,
        path: path,
        host: host,
      ),
      tls: _tlsFromShare(
        security: security,
        sni: sni,
        fingerprint: _asString(node['fp']),
        pbk: _asString(node['pbk']),
        sid: _asString(node['sid']),
        insecure: false,
      ),
      vmessSecurity: scy.isEmpty ? 'auto' : scy,
      alterId: aid,
      displayName: _asString(node['ps']) ?? fragmentName,
      ignored: ignored,
    );
  }

  // ----------------------------------------------- vless:// / trojan://

  static V2RayConf _parseUriLink(String raw, V2RayKind kind) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      throw VpnConfigException('这份 ${kind.shareScheme}:// 链接无法解析');
    }
    final query = uri.queryParameters;
    final type = (query['type'] ?? query['net'] ?? 'tcp').trim();
    final securityRaw = (query['security'] ?? query['tls'] ?? '').trim().toLowerCase();
    final security = switch (securityRaw) {
      'tls' || 'xtls' => V2RaySecurity.tls,
      'reality' => V2RaySecurity.reality,
      'none' || '' => kind == V2RayKind.trojan && securityRaw.isEmpty
          ? V2RaySecurity.tls
          : V2RaySecurity.none,
      _ => throw VpnConfigException(
        '不支持的 TLS 类型「$securityRaw」。内核认识 none / tls / reality。',
      ),
    };
    final path = query['path'] ?? query['serviceName'];
    final host = query['host'] ?? query['sni'];
    final ignored = <String>[];
    const known = <String>{
      'type',
      'net',
      'security',
      'tls',
      'sni',
      'path',
      'host',
      'serviceName',
      'service_name',
      'flow',
      'fp',
      'pbk',
      'sid',
      'spx',
      'alpn',
      'allowInsecure',
      'insecure',
      'encryption',
      'headerType',
      'mode',
    };
    for (final key in query.keys) {
      if (!known.contains(key)) ignored.add(key);
    }
    var secret = uri.userInfo;
    try {
      secret = Uri.decodeComponent(secret);
    } on ArgumentError {
      // 保持原样。
    }
    return _build(
      kind: kind,
      server: uri.host,
      port: uri.hasPort ? uri.port : 443,
      secret: secret,
      transport: _transportFromShare(
        net: type,
        path: path,
        host: query['host'],
        serviceName: query['serviceName'] ?? query['service_name'],
      ),
      tls: _tlsFromShare(
        security: security,
        sni: query['sni'] ?? host,
        fingerprint: query['fp'],
        pbk: query['pbk'],
        sid: query['sid'],
        insecure: query['allowInsecure'] == '1' || query['insecure'] == '1',
      ),
      flow: query['flow'],
      displayName: uri.hasFragment ? _decodeSafe(uri.fragment.replaceAll('+', ' ')) : null,
      ignored: ignored,
    );
  }

  // ------------------------------------------------------------- JSON

  static V2RayConf _parseJson(String raw, V2RayKind kind) {
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
        if (item is Map && item['type'] == kind.outboundType) {
          found = item.cast<String, Object?>();
          break;
        }
      }
      if (found == null) {
        throw VpnConfigException(
          '这份 sing-box 配置里没有 ${kind.outboundType} 出站',
        );
      }
      node = found;
    }
    final type = node['type'];
    if (type != null && type != kind.outboundType) {
      throw VpnConfigException(
        '这份 JSON 的出站类型是「$type」，不是 ${kind.outboundType}',
      );
    }

    final transportNode = node['transport'];
    final tlsNode = node['tls'];
    final ignored = <String>[];
    const known = <String>{
      'type',
      'tag',
      'server',
      'server_port',
      'uuid',
      'password',
      'security',
      'alter_id',
      'flow',
      'tls',
      'transport',
      'network',
      'packet_encoding',
      'multiplex',
      'domain_resolver',
      'global_padding',
      'authenticated_length',
    };
    for (final key in node.keys) {
      if (!known.contains(key)) ignored.add(key);
    }
    if (node.containsKey('multiplex')) ignored.add('multiplex');
    if (node.containsKey('network')) ignored.add('network');

    final secret = kind == V2RayKind.trojan
        ? (_asString(node['password']) ?? '')
        : (_asString(node['uuid']) ?? '');

    return _build(
      kind: kind,
      server: _asString(node['server']) ?? '',
      port: _asInt(node['server_port']) ?? 443,
      secret: secret,
      transport: _transportFromJson(transportNode),
      tls: _tlsFromJson(tlsNode, kind),
      vmessSecurity: (_asString(node['security']) ?? 'auto').trim().toLowerCase(),
      alterId: _asInt(node['alter_id']) ?? 0,
      flow: _asString(node['flow']),
      displayName: _asString(node['tag']),
      ignored: ignored,
    );
  }

  static V2RayTransport _transportFromShare({
    required String net,
    String? path,
    String? host,
    String? serviceName,
  }) {
    final kind = _transportKind(net);
    return V2RayTransport(
      kind: kind,
      path: path,
      host: host,
      serviceName: serviceName ??
          (kind == V2RayTransportKind.grpc ? path : null),
    );
  }

  static V2RayTransport _transportFromJson(Object? raw) {
    if (raw is! Map) {
      return const V2RayTransport(kind: V2RayTransportKind.tcp);
    }
    final node = raw.cast<String, Object?>();
    final kind = _transportKind(_asString(node['type']) ?? 'tcp');
    final headers = node['headers'];
    String? host;
    if (headers is Map) {
      host = _asString(headers['Host'] ?? headers['host']);
    }
    host ??= _asString(node['host']);
    if (host == null) {
      final list = node['host'];
      if (list is List && list.isNotEmpty) host = _asString(list.first);
    }
    return V2RayTransport(
      kind: kind,
      path: _asString(node['path']),
      host: host,
      serviceName: _asString(node['service_name']),
    );
  }

  static V2RayTransportKind _transportKind(String raw) {
    final key = raw.trim().toLowerCase();
    return switch (key) {
      '' || 'tcp' || 'raw' || 'none' => V2RayTransportKind.tcp,
      'ws' || 'websocket' => V2RayTransportKind.ws,
      'grpc' || 'gun' => V2RayTransportKind.grpc,
      'http' || 'h2' || 'h3' => V2RayTransportKind.http,
      'httpupgrade' || 'http-upgrade' => V2RayTransportKind.httpupgrade,
      'quic' => V2RayTransportKind.quic,
      _ => throw VpnConfigException(
        '不支持的传输方式「$raw」。内核认识 tcp / ws / grpc / http / httpupgrade / quic。',
      ),
    };
  }

  static V2RayTls? _tlsFromShare({
    required V2RaySecurity security,
    String? sni,
    String? fingerprint,
    String? pbk,
    String? sid,
    required bool insecure,
  }) {
    if (security == V2RaySecurity.none) return null;
    return V2RayTls(
      security: security,
      serverName: sni,
      fingerprint: fingerprint,
      realityPublicKey: pbk,
      realityShortId: sid,
      insecure: insecure,
    );
  }

  static V2RayTls? _tlsFromJson(Object? raw, V2RayKind kind) {
    if (raw is! Map) {
      return kind == V2RayKind.trojan
          ? const V2RayTls(security: V2RaySecurity.tls)
          : null;
    }
    final node = raw.cast<String, Object?>();
    if (node['enabled'] == false) return null;
    final reality = node['reality'];
    var security = V2RaySecurity.tls;
    String? pbk;
    String? sid;
    if (reality is Map && reality['enabled'] == true) {
      security = V2RaySecurity.reality;
      pbk = _asString(reality['public_key']);
      sid = _asString(reality['short_id']);
    }
    final utls = node['utls'];
    String? fp;
    if (utls is Map) fp = _asString(utls['fingerprint']);
    return V2RayTls(
      security: security,
      serverName: _asString(node['server_name']),
      insecure: node['insecure'] == true,
      fingerprint: fp,
      realityPublicKey: pbk,
      realityShortId: sid,
    );
  }

  static V2RayConf _build({
    required V2RayKind kind,
    required String server,
    required int port,
    required String secret,
    required V2RayTransport transport,
    V2RayTls? tls,
    String vmessSecurity = 'auto',
    int alterId = 0,
    String? flow,
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
    final cred = secret.trim();
    if (cred.isEmpty) {
      throw VpnConfigException(
        kind == V2RayKind.trojan ? '缺少密码' : '缺少 UUID',
      );
    }
    if (kind != V2RayKind.trojan && !_looksLikeUuid(cred)) {
      throw VpnConfigException(
        'UUID「$cred」格式不正确。应为 8-4-4-4-12 的十六进制。',
      );
    }
    if (kind == V2RayKind.vmess && !vmessSecurities.contains(vmessSecurity)) {
      throw VpnConfigException(
        '不支持的 VMess 加密「$vmessSecurity」。请使用 auto / aes-128-gcm / chacha20-poly1305。',
      );
    }
    final flowValue = flow?.trim();
    if (kind == V2RayKind.vless &&
        flowValue != null &&
        flowValue.isNotEmpty &&
        !vlessFlows.contains(flowValue)) {
      throw VpnConfigException(
        '不支持的 VLESS flow「$flowValue」。内核认识 xtls-rprx-vision，或不填。',
      );
    }
    var tlsValue = tls;
    if (tlsValue?.security == V2RaySecurity.reality) {
      final pbk = tlsValue!.realityPublicKey?.trim() ?? '';
      if (pbk.isEmpty) {
        throw VpnConfigException('Reality 需要公钥（pbk / public_key），缺少时内核无法握手');
      }
    }
    if (tlsValue?.security == V2RaySecurity.tls &&
        (tlsValue!.serverName == null || tlsValue.serverName!.trim().isEmpty) &&
        !tlsValue.insecure) {
      tlsValue = V2RayTls(
        security: tlsValue.security,
        serverName: host,
        insecure: tlsValue.insecure,
        fingerprint: tlsValue.fingerprint,
        realityPublicKey: tlsValue.realityPublicKey,
        realityShortId: tlsValue.realityShortId,
      );
    }
    return V2RayConf(
      kind: kind,
      server: host,
      port: port,
      secret: cred,
      transport: transport,
      tls: tlsValue,
      vmessSecurity: vmessSecurity,
      alterId: alterId < 0 ? 0 : alterId,
      flow: (flowValue == null || flowValue.isEmpty) ? null : flowValue,
      displayName: displayName?.trim().isEmpty == true
          ? null
          : displayName?.trim(),
      ignoredFields: List<String>.of(ignored)..sort(),
    );
  }

  Map<String, Object?> toOutbound({
    required String tag,
    required String resolverTag,
  }) {
    final fragment = <String, Object?>{
      'type': kind.outboundType,
      'tag': tag,
      'server': server,
      'server_port': port,
      'domain_resolver': <String, Object?>{'server': resolverTag},
    };
    switch (kind) {
      case V2RayKind.vmess:
        fragment['uuid'] = secret;
        fragment['security'] = vmessSecurity;
        if (alterId > 0) fragment['alter_id'] = alterId;
      case V2RayKind.vless:
        fragment['uuid'] = secret;
        if (flow != null) fragment['flow'] = flow;
        fragment['packet_encoding'] = 'xudp';
      case V2RayKind.trojan:
        fragment['password'] = secret;
    }
    final transportJson = transport.toJson();
    if (transportJson != null) fragment['transport'] = transportJson;
    if (tls != null && tls!.enabled) fragment['tls'] = tls!.toJson();
    return fragment;
  }

  String toShareLink() {
    switch (kind) {
      case V2RayKind.vmess:
        final payload = <String, Object?>{
          'v': '2',
          'ps': displayName ?? '',
          'add': server,
          'port': '$port',
          'id': secret,
          'aid': '$alterId',
          'scy': vmessSecurity,
          'net': _shareNet(),
          'type': 'none',
          'host': transport.host ?? '',
          'path': transport.path ?? transport.serviceName ?? '',
          'tls': switch (tls?.security) {
            V2RaySecurity.tls => 'tls',
            V2RaySecurity.reality => 'reality',
            _ => '',
          },
          'sni': tls?.serverName ?? '',
          if (tls?.fingerprint != null) 'fp': tls!.fingerprint,
          if (tls?.realityPublicKey != null) 'pbk': tls!.realityPublicKey,
          if (tls?.realityShortId != null) 'sid': tls!.realityShortId,
        };
        final blob = base64Encode(utf8.encode(jsonEncode(payload)));
        return 'vmess://$blob';
      case V2RayKind.vless:
      case V2RayKind.trojan:
        final params = <String, String>{
          'type': _shareNet(),
          'security': switch (tls?.security) {
            V2RaySecurity.reality => 'reality',
            V2RaySecurity.tls => 'tls',
            _ => 'none',
          },
        };
        if (tls?.serverName != null && tls!.serverName!.isNotEmpty) {
          params['sni'] = tls!.serverName!;
        }
        if (transport.host != null && transport.host!.isNotEmpty) {
          params['host'] = transport.host!;
        }
        if (transport.path != null && transport.path!.isNotEmpty) {
          params['path'] = transport.path!;
        }
        if (transport.serviceName != null &&
            transport.serviceName!.isNotEmpty) {
          params['serviceName'] = transport.serviceName!;
        }
        if (flow != null) params['flow'] = flow!;
        if (tls?.fingerprint != null && tls!.fingerprint!.isNotEmpty) {
          params['fp'] = tls!.fingerprint!;
        }
        if (tls?.realityPublicKey != null) {
          params['pbk'] = tls!.realityPublicKey!;
        }
        if (tls?.realityShortId != null && tls!.realityShortId!.isNotEmpty) {
          params['sid'] = tls!.realityShortId!;
        }
        if (tls?.insecure == true) params['allowInsecure'] = '1';
        final host = server.contains(':') && !server.startsWith('[')
            ? '[$server]'
            : server;
        final query = params.isEmpty ? '' : Uri(queryParameters: params).query;
        final buf = StringBuffer(
          '${kind.shareScheme}://${Uri.encodeComponent(secret)}@$host:$port',
        );
        if (query.isNotEmpty) buf.write('?$query');
        if (displayName != null && displayName!.isNotEmpty) {
          buf.write('#${Uri.encodeComponent(displayName!)}');
        }
        return buf.toString();
    }
  }

  String _shareNet() => switch (transport.kind) {
    V2RayTransportKind.tcp => 'tcp',
    V2RayTransportKind.ws => 'ws',
    V2RayTransportKind.grpc => 'grpc',
    V2RayTransportKind.http => 'http',
    V2RayTransportKind.httpupgrade => 'httpupgrade',
    V2RayTransportKind.quic => 'quic',
  };
}

class V2RayProfile extends ParsedProfile {
  const V2RayProfile(this.conf);

  final V2RayConf conf;

  @override
  VpnProtocol get protocol => conf.kind.protocol;

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
        (
          label: conf.kind == V2RayKind.trojan ? '密码' : 'UUID',
          value: conf.secretDisplay,
        ),
        (label: '传输', value: conf.transport.label),
        (
          label: 'TLS',
          value: switch (conf.tls?.security) {
            V2RaySecurity.reality => 'Reality',
            V2RaySecurity.tls => conf.tls?.serverName ?? '已启用',
            _ => '未启用',
          },
        ),
        if (conf.kind == V2RayKind.vmess)
          (label: '加密', value: conf.vmessSecurity),
        if (conf.kind == V2RayKind.vmess && conf.alterId > 0)
          (label: 'alterId', value: '${conf.alterId}'),
        if (conf.flow != null) (label: 'flow', value: conf.flow!),
        if (conf.displayName != null && conf.displayName!.isNotEmpty)
          (label: '备注', value: conf.displayName!),
      ];

  @override
  List<String> get unusedKeys => conf.ignoredFields;

  @override
  List<ProfileNotice> get notices {
    final out = <ProfileNotice>[];
    if (conf.kind == V2RayKind.vmess && conf.alterId > 0) {
      out.add(
        ProfileNotice.info(
          'alterId 为 ${conf.alterId}，这是 VMess 的旧式 MD5 模式。'
          '能改的话请让服务端改成 alterId = 0（AEAD）。',
        ),
      );
    }
    if (conf.tls?.insecure == true) {
      out.add(
        ProfileNotice.warn('已关闭证书校验（insecure）。只应出现在自签证书的测试环境。'),
      );
    }
    return out;
  }
}

bool _looksLikeUuid(String raw) {
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(raw.trim());
}

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
