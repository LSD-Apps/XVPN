/// Hysteria2 配置解析器。
///
/// 覆盖三种来源——面板与客户端实际给出的就是这三种形式：
///
///   1. **分享链接**：`hysteria2://auth@host:port/?sni=...&obfs=salamander&obfs-password=...`
///      （`hy2://` 简写同样常见，两种都接受）；
///   2. **官方客户端 YAML**（Hysteria2 官方文档里的那份 `config.yaml`）；
///   3. **sing-box 出站 JSON**（`{"type": "hysteria2", ...}`，也支持从整份
///      配置的 `outbounds` 里挑出那一条）。
///
/// 只做纯文本处理，不依赖任何平台能力，因此可以完整单元测试。
///
/// 本文件里每一条「必须这样写」的约束都对应一次真实内核实测，不是照文档推断的
/// ——文档与实现的差异正是本项目踩坑的来源（见 CONTRIBUTING「不要做的事」）。
library;

import 'dart:convert';

import 'parsed_profile.dart';
import 'vpn_protocol.dart';

/// 配置的来源形式。
///
/// 单独提出来展示，是因为三种形式的字段名完全不同：用户看到「来自分享链接」，
/// 才知道该回面板去改哪一项。
enum Hysteria2Source {
  link('分享链接'),
  yaml('官方客户端 YAML'),
  json('sing-box 出站 JSON');

  const Hysteria2Source(this.label);

  final String label;
}

/// 一份 Hysteria2 配置的字段集合。
class Hysteria2Conf {
  const Hysteria2Conf({
    required this.server,
    required this.port,
    required this.auth,
    required this.source,
    this.serverPorts = const <String>[],
    this.hopIntervalSeconds,
    this.sni,
    this.insecure = false,
    this.alpn = const <String>[],
    this.pinSha256,
    this.obfsPassword,
    this.upMbps,
    this.downMbps,
    this.displayName,
    this.ignoredFields = const <String>[],
  });

  /// 服务端主机（域名或 IP，不含端口）。
  final String server;

  /// 主端口。端口跳跃启用时它仍然要下发：内核用 [serverPorts] 做跳跃，
  /// 但缺了 `server_port` 时部分版本会把它当成 0。
  final int port;

  /// 认证串。Hysteria2 的服务端有两种认证：单一密码，或 `用户:密码`。
  /// 两种都原样放在这一个字段里，由服务端去解释。
  final String auth;

  final Hysteria2Source source;

  /// 端口跳跃区间，已归一化成内核要求的 `a:b` 形式（单端口也是 `443:443`）。
  final List<String> serverPorts;

  /// 端口跳跃的切换间隔（秒）。
  final int? hopIntervalSeconds;

  /// TLS SNI。未声明时为 null——此时适配器用服务器名兜底，
  /// 因为内核要求 `server_name` 与 `insecure` 至少有一个（实测报错
  /// `missing server_name or insecure=true`）。
  final String? sni;

  /// 是否跳过证书校验。**默认 false**：这是用户显式写在配置里的选择，
  /// 程序不替他关闭校验，也不替他打开。
  final bool insecure;

  final List<String> alpn;

  /// 证书公钥指纹（base64，已归一化）。对应 Hysteria2 的 `pinSHA256`。
  final String? pinSha256;

  /// salamander 混淆密码。为 null 表示未启用混淆。
  final String? obfsPassword;

  /// 服务端上下行带宽（Mbps）。声明了它，内核就不再自动探测，
  /// 拥塞控制会按这个值直接跑——弱网下这往往就是「能连但慢」与「跑满」的差别。
  final int? upMbps;
  final int? downMbps;

  /// 分享链接里的 `#` 备注名。
  final String? displayName;

  /// 读到但不参与连接的字段名，用于向用户解释。
  final List<String> ignoredFields;

  bool get hasPortHopping => serverPorts.isNotEmpty;

  bool get usesObfs => obfsPassword != null;

  /// 认证方式的展示文案。
  ///
  /// 刻意**不回显凭据本身**：「配置文件」页会在截图、录屏里出现，
  /// 而这一页的作用只是告诉用户「认证配好了」。
  String get authDisplay => auth.contains(':') ? '用户 + 密码' : '密码';

  /// 解析任意一种来源形式。
  static Hysteria2Conf parse(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      throw VpnConfigException('配置内容为空');
    }
    // 分享链接要按「第一条有意义的行」判断，不能对整段文本 startsWith：
    // 面板导出与用户自己存的文件几乎都会在前面写几行 `#` 说明，
    // 直接匹配会把它当成 YAML 去解析，然后报「解析不出任何字段」。
    final firstLine = firstMeaningfulLine(raw);
    final firstLower = firstLine.toLowerCase();
    if (firstLower.startsWith('hysteria2://') ||
        firstLower.startsWith('hy2://')) {
      return _parseLink(firstLine);
    }
    if (raw.startsWith('{')) {
      return _parseJson(raw);
    }
    return _parseYaml(raw);
  }

  /// 取第一条非空且非注释的行。
  ///
  /// 供识别与解析共用：适配器的 `canParse` 也必须按同一规则判断，
  /// 否则会出现「能识别但解析报错」或反过来的错配。
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

  /// 解析 `hysteria2://auth@host:port/?key=value` 形式的分享链接。
  static Hysteria2Conf _parseLink(String raw) {
    var body = raw.substring(
      raw.toLowerCase().startsWith('hysteria2://')
          ? 'hysteria2://'.length
          : 'hy2://'.length,
    );

    // 备注名在 `#` 之后，不参与连接参数。
    String? displayName;
    final hash = body.indexOf('#');
    if (hash != -1) {
      displayName = _decodeSafe(body.substring(hash + 1));
      body = body.substring(0, hash);
    }

    String? query;
    final question = body.indexOf('?');
    if (question != -1) {
      query = body.substring(question + 1);
      body = body.substring(0, question);
    }

    // 凭据取**最后一个** `@`：部分面板生成的密码里带 `@` 且没有转义。
    // 用第一个 `@` 切会把密码截断，得到一个「密码错误」的假故障。
    String? auth;
    final at = body.lastIndexOf('@');
    if (at != -1) {
      auth = _decodeSafe(body.substring(0, at));
      body = body.substring(at + 1);
    }

    // 分享链接里一般不写路径，写了也与我们无关。
    final slash = body.indexOf('/');
    if (slash != -1) body = body.substring(0, slash);

    final (host, port) = _splitHostPort(body, defaultPort: 443);
    if (host.isEmpty) {
      throw VpnConfigException('分享链接里没有服务器地址：$raw');
    }

    final params = _parseQuery(query);
    String? sni;
    var insecure = false;
    String? obfsPassword;
    String? obfsType;
    String? pin;
    final alpn = <String>[];
    String? hopSpec;
    int? up;
    int? down;
    int? hopInterval;
    final ignored = <String>[];

    for (final entry in params.entries) {
      final key = entry.key;
      final value = entry.value;
      switch (key) {
        case 'sni':
        case 'peer':
          sni = value;
        case 'insecure':
          insecure = _isTruthy(value);
        case 'obfs':
          // 链接里的 `obfs` 是**类型名**，密码在 `obfs-password`。
          // 实测：内核只认识 salamander，写别的名字会报
          // `unknown obfs type: ...` 并拒绝启动。
          if (value.isNotEmpty && value.toLowerCase() != 'salamander') {
            throw VpnConfigException(
              '分享链接声明了不支持的混淆类型「$value」，内核只支持 salamander',
            );
          }
          // 这里**只**记下「用户要混淆」这件事：缺密码时由 _build 统一报错。
          // 直接在这里静默丢掉混淆，等于把用户显式要求的一层伪装拿掉了。
          obfsType = 'salamander';
          break;
        case 'obfs-password':
        case 'obfspassword':
          obfsPassword = value;
          break;
        case 'pinsha256':
        case 'pin-sha256':
        case 'pin':
          pin = value;
        case 'alpn':
          alpn.addAll(
            value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
          );
        case 'mport':
        case 'ports':
        case 'server_ports':
          hopSpec = value;
        case 'hop-interval':
        case 'hop_interval':
        case 'hopinterval':
          hopInterval = _parseDurationSeconds(value, field: 'hop-interval');
        case 'up':
        case 'upmbps':
          up = _parseLeadingInt(value);
        case 'down':
        case 'downmbps':
          down = _parseLeadingInt(value);
        default:
          ignored.add(key);
      }
    }

    return _build(
      server: host,
      port: port,
      auth: auth ?? '',
      source: Hysteria2Source.link,
      displayName: displayName,
      sni: sni,
      insecure: insecure,
      alpn: alpn,
      pin: pin,
      obfsType: obfsType,
      obfsPassword: obfsPassword,
      up: up,
      down: down,
      hopSpec: hopSpec,
      hopInterval: hopInterval,
      ignored: ignored,
    );
  }

  // ---------------------------------------------------------------- JSON

  /// 解析 sing-box 出站 JSON，或从整份配置里挑出 hysteria2 出站。
  static Hysteria2Conf _parseJson(String raw) {
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

    // 整份 sing-box 配置：从 outbounds 里挑第一个 hysteria2。
    final outbounds = node['outbounds'];
    if (outbounds is List) {
      Map<String, Object?>? found;
      for (final item in outbounds) {
        if (item is Map && item['type'] == 'hysteria2') {
          found = item.cast<String, Object?>();
          break;
        }
      }
      if (found == null) {
        throw VpnConfigException('这份 sing-box 配置里没有 hysteria2 出站');
      }
      node = found;
    }

    final type = node['type'];
    if (type != null && type != 'hysteria2') {
      throw VpnConfigException('这份 JSON 的出站类型是「$type」，不是 hysteria2');
    }

    final tls = _asMap(node['tls']);
    final obfs = _asMap(node['obfs']);
    final ignored = <String>[];
    for (final key in node.keys) {
      const known = <String>{
        'type',
        'tag',
        'server',
        'server_port',
        'server_ports',
        'hop_interval',
        'password',
        'obfs',
        'up_mbps',
        'down_mbps',
        'tls',
        'domain_resolver',
        'network',
      };
      if (!known.contains(key)) ignored.add(key);
    }
    ignored.addAll(_unconsumedNestedKeys(tls, obfs));

    return _build(
      server: _asString(node['server']) ?? '',
      port: _asInt(node['server_port']) ?? 443,
      auth: _asString(node['password']) ?? '',
      source: Hysteria2Source.json,
      displayName: _asString(node['tag']),
      sni: _asString(tls?['server_name']),
      insecure: _asBool(tls?['insecure']) ?? false,
      alpn: _asStringList(tls?['alpn']),
      pin: _firstOrNull(_asStringList(tls?['certificate_public_key_sha256'])),
      obfsPassword: obfs == null ? null : (_asString(obfs['password']) ?? ''),
      up: _asInt(node['up_mbps']),
      down: _asInt(node['down_mbps']),
      // 这里已经是内核形式（`a:b`），直接透传即可。
      hopPorts: _asStringList(node['server_ports']),
      hopInterval: _parseDurationSeconds(
        node['hop_interval'],
        field: 'hop_interval',
      ),
      ignored: ignored,
    );
  }

  // ---------------------------------------------------------------- YAML

  /// 解析官方 Hysteria2 客户端的 `config.yaml`。
  static Hysteria2Conf _parseYaml(String raw) {
    final root = _parseYamlMap(raw);
    if (root.isEmpty) {
      throw VpnConfigException('这份配置解析不出任何字段，请确认内容完整');
    }

    final tls = _asMap(root['tls']);
    final obfs = _asMap(root['obfs']);
    final ignored = <String>[];

    // 键名统一成「小写且去掉分隔符」再比较：官方 YAML 用 camelCase
    // （`pinSHA256` / `hopInterval`），而 sing-box 风格与各家面板用下划线，
    // 三种写法在真实配置文件里都出现过。
    final flat = <String, Object?>{};
    for (final entry in root.entries) {
      flat[_normalizeKey(entry.key)] = entry.value;
    }
    final tlsFlat = <String, Object?>{};
    for (final entry in (tls ?? const <String, Object?>{}).entries) {
      tlsFlat[_normalizeKey(entry.key)] = entry.value;
    }
    final obfsFlat = <String, Object?>{};
    for (final entry in (obfs ?? const <String, Object?>{}).entries) {
      obfsFlat[_normalizeKey(entry.key)] = entry.value;
    }

    // 混淆有两种写法：官方的 `obfs: {type, password}` 与面板常见的
    // `obfs: salamander` + `obfs-password: xxx`。
    String? obfsType;
    String? obfsPassword;
    if (obfs != null) {
      obfsType = _asString(obfsFlat['type']);
      obfsPassword = _asString(obfsFlat['password']);
    } else {
      final plain = _asString(root['obfs']);
      if (plain != null && plain.isNotEmpty) {
        obfsType = plain;
        if (plain.toLowerCase() != 'salamander') {
          // 不是混淆，而是别的键恰好叫 obfs 的情况极少，直接当普通字段忽略。
          obfsType = null;
          ignored.add('obfs=$plain');
        }
      }
    }
    obfsPassword ??= _asString(flat['obfspassword'] ?? flat['obfspass']);

    // 以下一律查归一化后的键表：官方 YAML 写 `auth`、`pinSHA256`、`up`，
    // 而 sing-box 风格与部分面板写 `auth_str`、`pin_sha256`、`up_mbps`。
    var sni = _asString(tlsFlat['sni'] ?? tlsFlat['servername']);
    sni ??= _asString(flat['sni']);

    var insecure = _asBool(tlsFlat['insecure']) ?? false;
    insecure = insecure || (_asBool(flat['insecure']) ?? false);

    final alpn = _asStringList(tlsFlat['alpn'] ?? flat['alpn']);

    final pin =
        _asString(tlsFlat['pinsha256']) ??
        _asString(flat['pinsha256']) ??
        _asString(flat['pin']);

    // server 既可能是 `host:port`，也可能是 `host:port,8443-9443`。
    final serverSpec = _asString(flat['server']);
    if (serverSpec == null || serverSpec.trim().isEmpty) {
      throw VpnConfigException('这份 YAML 里没有 server 字段，无法定位服务器');
    }
    final (host, port, ports) = _splitServerSpec(serverSpec);

    return _build(
      server: host,
      port: port,
      auth:
          _asString(flat['auth']) ??
          _asString(flat['authstr']) ??
          _asString(flat['password']) ??
          '',
      source: Hysteria2Source.yaml,
      sni: sni,
      insecure: insecure,
      alpn: alpn,
      pin: pin,
      obfsType: obfsType,
      obfsPassword: obfsPassword,
      up:
          _parseLeadingInt(_asString(flat['up'])) ??
          _asInt(flat['upmbps']) ??
          _asInt(flat['up_mbps']),
      down:
          _parseLeadingInt(_asString(flat['down'])) ??
          _asInt(flat['downmbps']) ??
          _asInt(flat['down_mbps']),
      hopPorts: ports,
      hopInterval: _parseDurationSeconds(
        flat['hopinterval'],
        field: 'hopInterval',
      ),
      ignored: ignored,
      // 除上面显式消费掉的键，其余都记下来告诉用户。
      extraIgnored: <String>[
        ..._collectIgnoredYaml(root),
        ..._unconsumedNestedKeys(tls, obfs),
      ],
    );
  }

  /// `tls` / `obfs` 段里没被消费的键。
  ///
  /// 必须报出来而不是静默忽略：例如 `tls.ca`（自定义根证书）或
  /// `tls.utls`（指纹伪装）被丢掉，用户只会看到「握手失败」或
  /// 「能用但特征明显」，而原因在解析这一步，界面上任何地方都看不出来。
  static List<String> _unconsumedNestedKeys(
    Map<String, Object?>? tls,
    Map<String, Object?>? obfs,
  ) {
    const consumedTls = <String>{
      'enabled',
      'sni',
      'servername',
      'insecure',
      'alpn',
      'pinsha256',
    };
    const consumedObfs = <String>{'type', 'password'};
    final result = <String>[];
    for (final entry in (tls ?? const <String, Object?>{}).entries) {
      if (!consumedTls.contains(_normalizeKey(entry.key))) {
        result.add('tls.${entry.key}');
      }
    }
    for (final entry in (obfs ?? const <String, Object?>{}).entries) {
      if (!consumedObfs.contains(_normalizeKey(entry.key))) {
        result.add('obfs.${entry.key}');
      }
    }
    return result;
  }

  /// YAML 里被消费过的顶层键，其余键会被记为「已忽略」。
  static List<String> _collectIgnoredYaml(Map<String, Object?> root) {
    const consumed = <String>{
      'server',
      'auth',
      'authstr',
      'password',
      'sni',
      'insecure',
      'alpn',
      'pinsha256',
      'pin',
      'up',
      'upmbps',
      'down',
      'downmbps',
      'obfs',
      'obfspassword',
      'obfspass',
      'hopinterval',
      'tls',
      'serverports',
      'ports',
      'mport',
    };
    final result = <String>[];
    for (final key in root.keys) {
      if (!consumed.contains(_normalizeKey(key))) result.add(key);
    }
    return result;
  }

  // ------------------------------------------------------------ 组装校验

  /// 汇总三种来源的字段并做校验。集中在一处，避免三份重复的校验逻辑漂移。
  static Hysteria2Conf _build({
    required String server,
    required int port,
    required String auth,
    required Hysteria2Source source,
    String? displayName,
    String? sni,
    bool insecure = false,
    List<String> alpn = const <String>[],
    String? pin,
    String? obfsType,
    String? obfsPassword,
    int? up,
    int? down,
    String? hopSpec,
    List<String> hopPorts = const <String>[],
    int? hopInterval,
    List<String> ignored = const <String>[],
    List<String> extraIgnored = const <String>[],
  }) {
    final normalizedHost = server.trim();
    if (normalizedHost.isEmpty) {
      throw VpnConfigException('缺少服务器地址（server）');
    }
    if (port < 1 || port > 65535) {
      throw VpnConfigException('服务器端口 $port 超出 1–65535 的范围');
    }
    if (auth.trim().isEmpty) {
      throw VpnConfigException(
        '缺少认证凭据。Hysteria2 的服务端必须配置认证（密码或 用户:密码），'
        '请确认从面板复制的是完整链接',
      );
    }

    // 混淆：内核只认识 salamander，且没有密码时会直接拒绝启动
    // （实测报错 `missing obfs password`）。
    final normalizedObfs = obfsType?.trim().toLowerCase();
    if (normalizedObfs != null && normalizedObfs.isNotEmpty) {
      if (normalizedObfs != 'salamander') {
        throw VpnConfigException('不支持的混淆类型「$obfsType」：内核只支持 salamander');
      }
      if (obfsPassword == null || obfsPassword.isEmpty) {
        throw VpnConfigException(
          '配置启用了 salamander 混淆，但没有给出混淆密码（obfs-password）',
        );
      }
    }

    // 端口跳跃：显式声明的列表优先，其次是 `mport=20000-30000` 这种串。
    final ports = <String>[...hopPorts];
    if (ports.isEmpty && hopSpec != null && hopSpec.trim().isNotEmpty) {
      for (final part in hopSpec.split(',')) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        ports.add(_normalizePortRange(trimmed));
      }
    }

    return Hysteria2Conf(
      server: normalizedHost,
      port: port,
      auth: auth.trim(),
      source: source,
      serverPorts: List<String>.unmodifiable(ports),
      hopIntervalSeconds: hopInterval,
      sni: (sni == null || sni.trim().isEmpty) ? null : sni.trim(),
      insecure: insecure,
      alpn: List<String>.unmodifiable(alpn),
      pinSha256: pin == null ? null : _normalizePin(pin),
      obfsPassword: (obfsPassword == null || obfsPassword.isEmpty)
          ? null
          : obfsPassword,
      upMbps: up,
      downMbps: down,
      displayName: displayName,
      ignoredFields: List<String>.unmodifiable(<String>[
        ...ignored,
        ...extraIgnored,
      ]),
    );
  }

  /// 归一化证书公钥指纹。
  ///
  /// 不合法时**直接报错而不是丢掉**：丢掉指纹等于悄悄放弃用户显式要求的
  /// 证书固定（一次安全降级），而报错只让他改一次链接。这与 OpenVPN 那边
  /// 「认不出的加密套件名直接剔除」不同——剔除只影响协商范围。
  static String _normalizePin(String raw) {
    var value = raw.trim().replaceAll('-', '+').replaceAll('_', '/');
    // URL-safe base64 常省略补齐的 `=`。
    while (value.length % 4 != 0) {
      value = '$value=';
    }
    final List<int> bytes;
    try {
      bytes = base64.decode(value);
    } on FormatException {
      throw VpnConfigException('证书指纹 pinSHA256 不是合法的 base64：$raw');
    }
    if (bytes.length != 32) {
      throw VpnConfigException(
        '证书指纹 pinSHA256 应为 32 字节（SHA-256），实际是 ${bytes.length} 字节',
      );
    }
    return value;
  }

  /// 把 `443` / `8443-9443` 归一化成内核要求的 `a:b` 区间。
  ///
  /// 内核**只接受区间形式**：实测 `server_ports: ["443"]` 会报
  /// `bad port range: 443` 并拒绝启动，写成 `"443:443"` 才行。
  static String _normalizePortRange(String raw) {
    final parts = raw.split(RegExp(r'[-:]'));
    final start = int.tryParse(parts.first.trim());
    if (start == null) {
      throw VpnConfigException('无法识别的端口写法「$raw」');
    }
    final end = parts.length > 1 ? int.tryParse(parts[1].trim()) : start;
    if (end == null) {
      throw VpnConfigException('无法识别的端口写法「$raw」');
    }
    for (final p in <int>[start, end]) {
      if (p < 1 || p > 65535) {
        throw VpnConfigException('端口 $p 超出 1–65535 的范围（来自「$raw」）');
      }
    }
    // 写反了（`9443-8443`）当作笔误直接换回来：语义无歧义，报错只会让人多改一次。
    final low = start <= end ? start : end;
    final high = start <= end ? end : start;
    return '$low:$high';
  }

  /// 拆分 `host:port` / `host:port,8443-9443` / `[fd00::1]:443`。
  static (String, int, List<String>) _splitServerSpec(String spec) {
    final trimmed = spec.trim();
    // 逗号之后是端口跳跃的附加区间。
    final comma = trimmed.indexOf(',');
    final head = comma == -1 ? trimmed : trimmed.substring(0, comma);
    final tail = comma == -1 ? '' : trimmed.substring(comma + 1);

    final (host, port) = _splitHostPort(head, defaultPort: 443);
    final ports = <String>[];
    for (final part in tail.split(',')) {
      if (part.trim().isEmpty) continue;
      ports.add(_normalizePortRange(part.trim()));
    }
    return (host, port, ports);
  }

  /// 拆分 `host:port`，兼容 `[fd00::1]:443` 与裸 IPv6。
  static (String, int) _splitHostPort(String raw, {required int defaultPort}) {
    final value = raw.trim();
    if (value.isEmpty) return ('', defaultPort);
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close == -1) return (value, defaultPort);
      final host = value.substring(1, close);
      final rest = value.substring(close + 1);
      if (rest.startsWith(':') && rest.length > 1) {
        return (host, int.tryParse(rest.substring(1)) ?? defaultPort);
      }
      return (host, defaultPort);
    }
    // 裸 IPv6（多个冒号）视为没有端口。
    if (value.indexOf(':') != value.lastIndexOf(':')) {
      return (value, defaultPort);
    }
    final idx = value.lastIndexOf(':');
    if (idx == -1) return (value, defaultPort);
    final port = int.tryParse(value.substring(idx + 1));
    if (port == null) return (value, defaultPort);
    return (value.substring(0, idx), port);
  }

  /// 解析 `a=1&b=2` 形式的查询串，键名统一小写。
  static Map<String, String> _parseQuery(String? query) {
    final result = <String, String>{};
    if (query == null || query.isEmpty) return result;
    for (final pair in query.split('&')) {
      if (pair.trim().isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq == -1) {
        result[pair.trim().toLowerCase()] = '';
        continue;
      }
      final key = pair.substring(0, eq).trim().toLowerCase();
      result[key] = _decodeSafe(pair.substring(eq + 1));
    }
    return result;
  }

  /// 百分比解码。分享链接里的密码常含 `@`、`/`、`:`，面板会转义。
  static String _decodeSafe(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } on FormatException {
      // 转义写坏了（例如单独的 `%`）时原样使用，总好过整条链接导入失败。
      return raw;
    }
  }

  static bool _isTruthy(String value) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }

  /// 解析 `30s` / `30` / `1m` 形式的时长，返回秒数。
  static int? _parseDurationSeconds(Object? value, {required String field}) {
    if (value == null) return null;
    if (value is int) return value;
    final text = value.toString().trim().toLowerCase();
    if (text.isEmpty) return null;
    final match = RegExp(r'^(\d+(?:\.\d+)?)\s*(ms|s|m|h)?$').firstMatch(text);
    if (match == null) {
      throw VpnConfigException('无法识别 $field 的取值「$value」：需要形如 30s 的时长');
    }
    final n = double.parse(match.group(1)!);
    final seconds = switch (match.group(2)) {
      'ms' => n / 1000,
      'm' => n * 60,
      'h' => n * 3600,
      _ => n,
    };
    // 内核要的是「带单位的时长」，适配器统一按秒下发；毫秒级的值向上取整到 1 秒。
    return seconds < 1 ? 1 : seconds.round();
  }

  /// 取字符串开头处的整数，用于 `up: 100 mbps` 这类带单位的写法。
  static int? _parseLeadingInt(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^\s*(\d+)').firstMatch(value);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// 键名归一化：小写并去掉 `-` / `_`，让 `pinSHA256`、`pin_sha256`、
  /// `pin-sha256` 指向同一个键。
  static String _normalizeKey(String key) =>
      key.trim().toLowerCase().replaceAll(RegExp(r'[-_]'), '');

  // -------------------------------------------------- YAML 子集解析（见下）

  static Map<String, Object?> _parseYamlMap(String text) {
    final entries = <({int indent, String text, int line})>[];
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final stripped = _stripYamlComment(lines[i]);
      if (stripped.trim().isEmpty) continue;
      final content = stripped.trim();
      if (content.startsWith('- ')) {
        throw VpnConfigException('第 ${i + 1} 行是列表项，这份配置的写法不受支持：$content');
      }
      entries.add((
        indent: stripped.length - stripped.trimLeft().length,
        text: content,
        line: i + 1,
      ));
    }
    if (entries.isEmpty) return <String, Object?>{};

    var index = 0;
    Map<String, Object?> parseBlock(int indent) {
      final map = <String, Object?>{};
      while (index < entries.length) {
        final entry = entries[index];
        if (entry.indent < indent) break;
        if (entry.indent > indent) {
          throw VpnConfigException('第 ${entry.line} 行缩进不一致：${entry.text}');
        }
        final colon = entry.text.indexOf(':');
        if (colon <= 0) {
          throw VpnConfigException(
            '第 ${entry.line} 行不是 key: value 形式：${entry.text}',
          );
        }
        final key = entry.text.substring(0, colon).trim();
        final value = entry.text.substring(colon + 1).trim();
        index++;
        if (value.isEmpty) {
          // 值在当前行，内容在缩进更深的后续行里。
          if (index < entries.length && entries[index].indent > indent) {
            map[key] = parseBlock(entries[index].indent);
          } else {
            map[key] = null;
          }
        } else {
          map[key] = _parseYamlScalar(value);
        }
      }
      return map;
    }

    return parseBlock(entries.first.indent);
  }

  static Object? _parseYamlScalar(String value) {
    var text = value.trim();
    // 行尾注释（值不在引号内时才可能是注释，这里已经由 _stripYamlComment 处理）。
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1);
    }
    if (text.startsWith('[') && text.endsWith(']')) {
      return text
          .substring(1, text.length - 1)
          .split(',')
          .map((e) => e.trim().replaceAll(RegExp(r'''^["']|["']$'''), ''))
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    final lower = text.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
    if (lower == 'null' || text == '~') return null;
    return text;
  }

  /// 去掉 YAML 注释，`#` 出现在引号里时不动它。
  static String _stripYamlComment(String line) {
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (ch == '#' && !inSingle && !inDouble) {
        if (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t') {
          return line.substring(0, i);
        }
      }
    }
    return line;
  }
}

/// Hysteria2 配置的协议无关视图。
class Hysteria2Profile implements ParsedProfile {
  const Hysteria2Profile(this.conf);

  final Hysteria2Conf conf;

  @override
  VpnProtocol get protocol => VpnProtocol.hysteria2;

  @override
  String get serverDisplay {
    final hopping = conf.hasPortHopping
        ? '（端口跳跃 ${conf.serverPorts.join('、')}）'
        : '';
    return '${conf.server}:${conf.port}$hopping';
  }

  /// 流式代理没有隧道地址：目的地址由服务端去连接。
  @override
  String get addressDisplay => '—';

  @override
  String get dnsDisplay => '内置策略';

  /// Hysteria2 的配置里没有 DNS 声明。
  @override
  List<String> get declaredDns => const <String>[];

  @override
  bool get hasIpv6 => false;

  /// 不收紧成 ipv4_only：Hysteria2 没有隧道本地地址，
  /// 「解析出 AAAA 却无处可用」这个前提在这里不成立，收紧反而会让
  /// IPv6-only 的站点直接失败。
  @override
  bool get needsIpv4OnlyDns => false;

  /// Hysteria2 没有握手里程碑要读，保持 warn。
  @override
  bool get wantsDebugLogs => false;

  @override
  bool get requiresCredentials => false;

  /// 流式代理没有隧道 MTU 的概念。
  @override
  int? get declaredMtu => null;

  @override
  List<({String label, String value})> get details =>
      <({String label, String value})>[
        (label: '服务器', value: serverDisplay),
        (label: '认证', value: conf.authDisplay),
        (label: '来源', value: conf.source.label),
        (
          label: 'TLS',
          value: conf.sni == null ? '未声明 SNI，按服务器名校验' : 'SNI：${conf.sni}',
        ),
        (
          label: '证书校验',
          value: switch ((conf.insecure, conf.pinSha256)) {
            (true, _) => '已关闭（配置声明 insecure）',
            (false, final String pin) =>
              '固定公钥指纹 ${pin.substring(0, 8)}…（pinSHA256）',
            _ => '系统根证书',
          },
        ),
        (label: '混淆', value: conf.usesObfs ? 'salamander' : '未启用'),
        (
          label: '带宽',
          value: switch ((conf.upMbps, conf.downMbps)) {
            (null, null) => '未声明（内核自动探测）',
            (final int up, final int down) => '上行 $up / 下行 $down Mbps',
            (final int up, null) => '上行 $up Mbps',
            (null, final int down) => '下行 $down Mbps',
          },
        ),
        if (conf.hasPortHopping)
          (
            label: '端口跳跃',
            value: conf.hopIntervalSeconds == null
                ? '已启用（间隔按内核默认）'
                : '每 ${conf.hopIntervalSeconds} 秒切换',
          ),
        if (conf.displayName != null && conf.displayName!.isNotEmpty)
          (label: '备注', value: conf.displayName!),
        if (conf.ignoredFields.isNotEmpty)
          // 忽略的字段要说出来：用户以为「我配了 obfs 却没生效」时，
          // 这里是他唯一能看出原因的地方。
          (label: '未使用字段', value: conf.ignoredFields.join('、')),
      ];
}

// ---------------------------------------------------------------- 取值助手
//
// JSON 解出来的值是 Object?，直接强转会抛 TypeError（面向开发者），
// 而这里需要的是「读不到就当没写」的宽松语义。

Map<String, Object?>? _asMap(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  return null;
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

bool? _asBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final v = value.trim().toLowerCase();
    if (v == 'true' || v == '1' || v == 'yes') return true;
    if (v == 'false' || v == '0' || v == 'no') return false;
  }
  return null;
}

List<String> _asStringList(Object? value) {
  if (value == null) return const <String>[];
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? const <String>[] : <String>[trimmed];
  }
  if (value is List) {
    return value
        .map((e) => e?.toString())
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

String? _firstOrNull(List<String> values) =>
    values.isEmpty ? null : values.first;
