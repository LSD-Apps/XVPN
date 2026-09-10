/// OpenVPN .ovpn 解析器。
///
/// 目标是覆盖「客户端导出的、可直接使用」的那一类配置：`remote` + `proto` +
/// 内联证书（`<ca>` / `<cert>` / `<key>` / `<tls-auth>` / `<tls-crypt>`）。
/// 只做纯文本处理，可完整单元测试。
library;

import 'parsed_profile.dart';
import 'vpn_protocol.dart';

class OpenVpnConf {
  const OpenVpnConf({
    required this.remoteHost,
    required this.remotePort,
    required this.network,
    required this.cipher,
    required this.dataCiphers,
    required this.auth,
    required this.ca,
    required this.cert,
    required this.key,
    required this.tlsAuth,
    required this.tlsCrypt,
    required this.keyDirection,
    required this.requiresCredentials,
    required this.username,
    required this.password,
    required this.ingoredDirectives,
  });

  final String? remoteHost;
  final int? remotePort;

  /// `udp` 或 `tcp`。OpenVPN 的 `udp4` / `tcp-client` 等写法会被归一化。
  final String network;

  final String? cipher;
  final List<String> dataCiphers;
  final String? auth;

  /// 内联的根证书（PEM）。
  final String? ca;

  /// 内联的客户端证书与私钥（PEM）。
  final String? cert;
  final String? key;

  /// `<tls-auth>` 与 `<tls-crypt>` 的内联内容，二者互斥。
  final String? tlsAuth;
  final String? tlsCrypt;
  final int? keyDirection;

  /// 配置声明了 `auth-user-pass`，需要用户额外提供账号密码。
  final bool requiresCredentials;
  final String? username;
  final String? password;

  /// 读到但不影响本 App 行为的指令，仅作记录。
  final List<String> ingoredDirectives;

  /// 客户端是否自带了完整凭据（内联证书齐全）。
  bool get hasInlineCredentials =>
      cert != null && cert!.isNotEmpty && key != null && key!.isNotEmpty;

  /// 是否使用 tls-crypt（比 tls-auth 更强的控制通道加密）。
  bool get usesTlsCrypt => tlsCrypt != null && tlsCrypt!.isNotEmpty;

  static OpenVpnConf parse(
    String text, {
    String? username,
    String? password,
  }) {
    String? remoteHost;
    int? remotePort;
    String? remoteProto;
    String network = 'udp';
    String? cipher;
    final dataCiphers = <String>[];
    String? auth;
    String? ca;
    String? cert;
    String? key;
    String? tlsAuth;
    String? tlsCrypt;
    int? keyDirection;
    var requiresCredentials = false;
    final ignored = <String>[];

    // 内联块：<tag> ... </tag>
    final inlineBlocks = <String, String>{};
    final inlinePattern = RegExp(r'<(\w[\w-]*)>\s*([\s\S]*?)\s*</\1>');
    for (final match in inlinePattern.allMatches(text)) {
      inlineBlocks[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
    }
    // 指令部分：去掉内联块，避免证书内容被误当成指令。
    final directives = text.replaceAll(inlinePattern, '\n');

    for (final rawLine in directives.split(RegExp(r'\r?\n'))) {
      final line = _stripComment(rawLine).trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      final name = parts.first.toLowerCase();
      final value = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      switch (name) {
        case 'remote':
          // remote host [port] [proto]
          if (parts.length >= 2) remoteHost = parts[1];
          if (parts.length >= 3) remotePort = int.tryParse(parts[2]);
          if (parts.length >= 4) remoteProto = parts[3].toLowerCase();
        case 'proto':
          remoteProto = value.toLowerCase();
        case 'cipher':
          cipher = value;
        case 'data-ciphers':
          dataCiphers
            ..clear()
            ..addAll(value.split(':').map((e) => e.trim()).where((e) => e.isNotEmpty));
        case 'auth':
          auth = value.toUpperCase();
        case 'key-direction':
          keyDirection = int.tryParse(value);
        case 'auth-user-pass':
          // 可能不带参数（交互输入），也可能指向一个文件。
          // 两种情况都需要用户提供凭据：移动端读不到那个文件。
          requiresCredentials = true;
        case 'client':
        case 'dev':
        case 'nobind':
        case 'persist-key':
        case 'persist-tun':
        case 'resolv-retry':
        case 'remote-cert-tls':
        case 'verb':
        case 'tls-client':
        case 'pull':
        case 'redirect-gateway':
          // 这些由内核或本 App 自行处理，无需翻译。
          break;
        default:
          ignored.add(name);
      }
    }

    ca = inlineBlocks['ca'];
    cert = inlineBlocks['cert'];
    key = inlineBlocks['key'];
    tlsAuth = inlineBlocks['tls-auth'];
    tlsCrypt = inlineBlocks['tls-crypt'];

    network = _normalizeNetwork(remoteProto, network);

    final conf = OpenVpnConf(
      remoteHost: remoteHost,
      remotePort: remotePort ?? _defaultPort(network),
      network: network,
      cipher: cipher,
      dataCiphers: List<String>.unmodifiable(dataCiphers),
      auth: auth,
      ca: ca,
      cert: cert,
      key: key,
      tlsAuth: tlsAuth,
      tlsCrypt: tlsCrypt,
      keyDirection: keyDirection,
      requiresCredentials: requiresCredentials,
      username: username,
      password: password,
      ingoredDirectives: List<String>.unmodifiable(ignored.toSet()),
    );
    conf.validate();
    return conf;
  }

  /// 校验。缺失关键信息时给出可读的中文说明。
  void validate() {
    if (remoteHost == null || remoteHost!.isEmpty) {
      throw VpnConfigException('缺少 remote 指令，无法定位 OpenVPN 服务器');
    }
    if (remotePort == null) {
      throw VpnConfigException('remote 端口无法解析：$remoteHost');
    }
    if (cert != null && key == null) {
      throw VpnConfigException('配置里有客户端证书 <cert>，但缺少对应的私钥 <key>');
    }
    if (key != null && cert == null) {
      throw VpnConfigException('配置里有客户端私钥 <key>，但缺少对应的证书 <cert>');
    }
    if (requiresCredentials && (username == null || password == null)) {
      throw VpnConfigException('这份配置需要账号密码（auth-user-pass），请在导入时填写');
    }
  }

  /// udp4 / udp6 / tcp4 / tcp-client 等写法统一成 udp 或 tcp。
  static String _normalizeNetwork(String? proto, String fallback) {
    if (proto == null || proto.isEmpty) return fallback;
    if (proto.startsWith('tcp')) return 'tcp';
    if (proto.startsWith('udp')) return 'udp';
    return fallback;
  }

  static int _defaultPort(String network) => network == 'tcp' ? 443 : 1194;

  static String _stripComment(String line) {
    final hash = line.indexOf('#');
    final semi = line.indexOf(';');
    var cut = line.length;
    if (hash != -1) cut = hash;
    if (semi != -1 && semi < cut) cut = semi;
    return line.substring(0, cut);
  }
}

/// OpenVPN 配置的协议无关视图。
class OpenVpnProfile implements ParsedProfile {
  const OpenVpnProfile(this.conf);

  final OpenVpnConf conf;

  @override
  VpnProtocol get protocol => VpnProtocol.openVpn;

  @override
  String get serverDisplay => '${conf.remoteHost}:${conf.remotePort}';

  /// OpenVPN 的隧道地址由服务端下发，配置里通常没有，因此不展示具体地址。
  @override
  String get addressDisplay => '由服务端下发';

  @override
  String get dnsDisplay => '内置策略';

  /// OpenVPN 的 DNS 由服务端通过 push 下发，配置里没有可用的解析器地址。
  @override
  List<String> get declaredDns => const <String>[];

  /// 服务端下发 IPv6 配置，这里无法预判，保守地按「没有」处理，
  /// 把 DNS 策略收紧为 ipv4_only，避免出现连不通的等待。
  @override
  bool get hasIpv6 => false;

  @override
  bool get requiresCredentials => conf.requiresCredentials;

  @override
  List<({String label, String value})> get details => <({String label, String value})>[
        (label: '传输', value: conf.network.toUpperCase()),
        if (conf.cipher != null) (label: '加密', value: conf.cipher!),
        if (conf.dataCiphers.isNotEmpty)
          (label: '数据加密', value: conf.dataCiphers.join(', ')),
        if (conf.auth != null) (label: '认证', value: conf.auth!),
        (
          label: '控制通道',
          value: conf.usesTlsCrypt
              ? 'tls-crypt'
              : (conf.tlsAuth != null ? 'tls-auth' : '无'),
        ),
        (label: '客户端证书', value: conf.hasInlineCredentials ? '已内联' : '无'),
      ];
}
