/// WireGuard .conf 解析器（wg-quick 格式）。
///
/// 这是「傻瓜式」的入口：用户只需导入一个 .conf，其余全部由 App 推导。
/// 解析器只做纯文本处理，不依赖任何平台能力，因此可以完整单元测试。
///
/// 注意：[WireGuardConf.allowedIps] 会被解析出来，但**不会**用于生成路由。
/// 分流由内置规则库决定。
library;

import 'parsed_profile.dart';
import 'vpn_protocol.dart';

class WireGuardPeer {
  const WireGuardPeer({
    this.publicKey,
    this.presharedKey,
    this.endpoint,
    this.allowedIps = const <String>[],
    this.persistentKeepalive,
  });

  final String? publicKey;
  final String? presharedKey;
  final String? endpoint;
  final List<String> allowedIps;
  final int? persistentKeepalive;
}

class WireGuardConf {
  const WireGuardConf({
    required this.privateKey,
    required this.addresses,
    required this.dns,
    required this.mtu,
    required this.listenPort,
    required this.peers,
    required this.ignoredKeys,
  });

  final String? privateKey;

  /// 隧道地址，可能同时含 IPv4 与 IPv6，例如 10.7.0.2/32 与 fd00::2/128。
  final List<String> addresses;

  /// .conf 声明的解析器。仅作参考，实际解析策略由内置规则决定。
  final List<String> dns;

  final int? mtu;
  final int? listenPort;
  final List<WireGuardPeer> peers;

  /// 被忽略的字段名（Table / PreUp / PostUp 等），用于向用户解释。
  final Map<String, String> ignoredKeys;

  WireGuardPeer? get primaryPeer => peers.isEmpty ? null : peers.first;

  /// 端点主机，例如 203.0.113.42。
  String? get endpointHost {
    final ep = primaryPeer?.endpoint;
    if (ep == null) return null;
    return _splitEndpoint(ep).$1;
  }

  /// 端点端口。.conf 未写端口时 WireGuard 默认 51820。
  int? get endpointPort {
    final ep = primaryPeer?.endpoint;
    if (ep == null) return null;
    return _splitEndpoint(ep).$2 ?? 51820;
  }

  /// 隧道地址里的第一个 IPv4 主机地址，用于界面展示。
  String? get primaryAddressV4 {
    for (final a in addresses) {
      final host = a.split('/').first.trim();
      if (!host.contains(':')) return host;
    }
    return null;
  }

  /// 从端点串中拆出主机与端口，兼容三种写法：
  /// `1.2.3.4:51820`、`example.com:51820`、`[fd00::1]:51820`。
  static (String, int?) _splitEndpoint(String raw) {
    final value = raw.trim();
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close == -1) return (value, null);
      final host = value.substring(1, close);
      final rest = value.substring(close + 1);
      if (rest.startsWith(':') && rest.length > 1) {
        return (host, int.tryParse(rest.substring(1)));
      }
      return (host, null);
    }
    // 未加方括号的裸 IPv6 视为无端口；IPv4/域名取最后一个冒号。
    if (value.indexOf(':') != value.lastIndexOf(':')) return (value, null);
    final idx = value.lastIndexOf(':');
    if (idx == -1) return (value, null);
    final port = int.tryParse(value.substring(idx + 1));
    if (port == null) return (value, null);
    return (value.substring(0, idx), port);
  }

  /// 解析 .conf 文本。字段名不区分大小写，容忍行尾注释与多余空行。
  static WireGuardConf parse(String text) {
    String? privateKey;
    final addresses = <String>[];
    final dns = <String>[];
    int? mtu;
    int? listenPort;
    final peers = <WireGuardPeer>[];

    var section = '';
    var current = _PeerBuilder();
    final ignored = <String, String>{};

    void flushPeer() {
      if (current.isNotEmpty) {
        peers.add(current.build());
      }
      current = _PeerBuilder();
    }

    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = _stripComment(rawLine).trim();
      if (line.isEmpty) continue;

      if (line.startsWith('[') && line.endsWith(']')) {
        final name = line.substring(1, line.length - 1).trim().toLowerCase();
        if (section == 'peer' && name != 'peer') flushPeer();
        section = name;
        continue;
      }

      final eq = line.indexOf('=');
      if (eq == -1) continue;
      final key = line.substring(0, eq).trim().toLowerCase();
      final value = line.substring(eq + 1).trim();
      if (value.isEmpty) continue;

      switch (section) {
        case 'interface':
          switch (key) {
            case 'privatekey':
              privateKey = value;
            case 'address':
              addresses.addAll(_splitList(value));
            case 'dns':
              dns.addAll(_splitList(value));
            case 'mtu':
              mtu = int.tryParse(value);
            case 'listenport':
              listenPort = int.tryParse(value);
            default:
              // Table / PreUp / PostUp 等由 wg-quick 在系统层执行；
              // 本 App 自行管理路由，因此忽略，但仍记录以便向用户说明。
              ignored[key] = value;
          }
        case 'peer':
          switch (key) {
            case 'publickey':
              current.publicKey = value;
            case 'presharedkey':
              current.presharedKey = value;
            case 'endpoint':
              current.endpoint = value;
            case 'allowedips':
              current.allowedIps.addAll(_splitList(value));
            case 'persistentkeepalive':
              current.persistentKeepalive = int.tryParse(value);
            default:
              ignored[key] = value;
          }
        default:
          ignored[key] = value;
      }
    }
    flushPeer();

    final conf = WireGuardConf(
      privateKey: privateKey,
      addresses: addresses,
      dns: dns,
      mtu: mtu,
      listenPort: listenPort,
      peers: peers,
      ignoredKeys: ignored,
    );
    conf.validate();
    return conf;
  }

  /// 校验必须字段。缺失时抛出可读的中文说明，供界面直接展示。
  void validate() {
    if (privateKey == null || privateKey!.isEmpty) {
      throw VpnConfigException('缺少 [Interface] PrivateKey，这不是一个完整的 WireGuard 配置');
    }
    if (addresses.isEmpty) {
      throw VpnConfigException('缺少 [Interface] Address，无法确定隧道地址');
    }
    if (peers.isEmpty) {
      throw VpnConfigException('缺少 [Peer] 段，配置中没有任何服务器');
    }
    final peer = peers.first;
    if (peer.publicKey == null || peer.publicKey!.isEmpty) {
      throw VpnConfigException('缺少 [Peer] PublicKey');
    }
    if (peer.endpoint == null || peer.endpoint!.isEmpty) {
      throw VpnConfigException('缺少 [Peer] Endpoint，无法定位服务器');
    }
    if (endpointPort == null) {
      throw VpnConfigException('Endpoint 端口无法解析：${peer.endpoint}');
    }
  }

  static List<String> _splitList(String value) => value
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);

  static String _stripComment(String line) {
    final hash = line.indexOf('#');
    return hash == -1 ? line : line.substring(0, hash);
  }
}

/// WireGuard 配置的协议无关视图。
class WireGuardProfile implements ParsedProfile {
  const WireGuardProfile(this.conf);

  final WireGuardConf conf;

  @override
  VpnProtocol get protocol => VpnProtocol.wireGuard;

  @override
  String get serverDisplay {
    final host = conf.endpointHost ?? '—';
    final port = conf.endpointPort;
    return port == null ? host : '$host:$port';
  }

  @override
  String get addressDisplay {
    if (conf.addresses.isEmpty) return '—';
    return conf.addresses.map((a) => a.split('/').first).join(', ');
  }

  @override
  String get dnsDisplay => conf.dns.isEmpty ? '内置策略' : conf.dns.join(', ');

  @override
  List<String> get declaredDns => conf.dns;

  @override
  bool get hasIpv6 => conf.addresses.any((a) => a.contains(':'));

  @override
  bool get requiresCredentials => false;

  @override
  List<({String label, String value})> get details => <({String label, String value})>[
        (label: 'DNS', value: dnsDisplay),
        if (conf.mtu != null) (label: 'MTU', value: '${conf.mtu}'),
        (
          label: '保活',
          value: '${conf.primaryPeer?.persistentKeepalive ?? 25} 秒',
        ),
      ];
}

class _PeerBuilder {
  String? publicKey;
  String? presharedKey;
  String? endpoint;
  final List<String> allowedIps = <String>[];
  int? persistentKeepalive;

  bool get isNotEmpty =>
      publicKey != null ||
      presharedKey != null ||
      endpoint != null ||
      allowedIps.isNotEmpty ||
      persistentKeepalive != null;

  WireGuardPeer build() => WireGuardPeer(
        publicKey: publicKey,
        presharedKey: presharedKey,
        endpoint: endpoint,
        allowedIps: List<String>.unmodifiable(allowedIps),
        persistentKeepalive: persistentKeepalive,
      );
}
