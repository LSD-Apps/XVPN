/// WireGuard .conf 解析器（wg-quick 格式）。
///
/// 这是「傻瓜式」的入口：用户只需导入一个 .conf，其余全部由 App 推导。
/// 解析器只做纯文本处理，不依赖任何平台能力，因此可以完整单元测试。
///
/// 注意：[WireGuardConf.allowedIps] 会被解析出来，但**不会**用于生成路由。
/// 分流由内置规则库决定。
library;

import 'parsed_profile.dart';
import 'protocol_tuning.dart';
import 'vpn_protocol.dart';
import 'wireguard_adapter.dart';

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
      throw VpnConfigException(
        '缺少 [Interface] PrivateKey，这不是一个完整的 WireGuard 配置',
      );
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
class WireGuardProfile extends ParsedProfile {
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

  /// 隧道里没有 IPv6 地址时收紧成 ipv4_only，理由见 [ParsedProfile.needsIpv4OnlyDns]。
  @override
  bool get needsIpv4OnlyDns => !hasIpv6;

  /// WireGuard 需要 DEBUG 级日志：握手状态只存在于 DEBUG 级的端点日志里，
  /// 而它是「连不上」时唯一能把「未被服务端受理」与「数据面问题」分开的证据。
  @override
  bool get wantsDebugLogs => true;

  @override
  bool get requiresCredentials => false;

  /// 配置里写的原始 MTU。
  ///
  /// 刻意返回**原始值**而不是 [sanitizeMtu] 之后的值：调用方要判断的是
  /// 「用户写的这个数行不行」，回退后的值永远落在合理区间里，拿它去校验等于
  /// 永远通过。真正下发给内核的值另有其人（见 [WireGuardAdapter.buildEndpoint]）。
  @override
  int? get declaredMtu => conf.mtu;

  @override
  List<({String label, String value})>
  get details => <({String label, String value})>[
    (label: 'DNS', value: dnsDisplay),
    if (tunnelDnsRemappedFromLocalPreference)
      (
        label: '隧道 DNS',
        value: '配置中的解析器仅适合直连场景，隧道内已改用公共解析器',
      ),
    (
      label: 'MTU',
      value:
          '${sanitizeMtu(conf.mtu) ?? WireGuardAdapter.defaultMtu}'
          '${sanitizeMtu(conf.mtu) == null && conf.mtu != null ? '（配置里的 ${conf.mtu} 超出合理范围，已回退）' : ''}',
    ),
    (
      label: '保活',
      value: switch (conf.primaryPeer?.persistentKeepalive) {
        final int seconds when seconds > 0 => '$seconds 秒',
        _ => '未启用',
      },
    ),
  ];

  @override
  List<String> get unusedKeys {
    if (conf.ignoredKeys.isEmpty) return const <String>[];
    final keys = conf.ignoredKeys.keys.toList()..sort();
    return keys;
  }

  @override
  List<ProfileNotice> get notices {
    final items = <ProfileNotice>[];
    if (looksLikeAmnezia) {
      items.add(
        const ProfileNotice.warn(
          '这份配置含 AmneziaWG 混淆参数，内核不支持，无法连接',
        ),
      );
    }
    if (tunnelDnsRemappedFromLocalPreference) {
      items.add(
        const ProfileNotice.info(
          '配置 DNS 为直连侧解析器（如 223.5.5.5），隧道内海外域名已改用公共解析器，'
          '避免经节点回问导致卡顿',
        ),
      );
    }
    final keepalive = conf.primaryPeer?.persistentKeepalive;
    if (keepalive == null || keepalive <= 0) {
      items.add(
        const ProfileNotice.info(
          '未启用 PersistentKeepalive。长距离或运营商 NAT 下映射可能失效，'
          '可在 Peer 中声明秒数（常见为 25）',
        ),
      );
    }
    return items;
  }

  /// 配置里只声明了本地偏好 DNS（如 223.5.5.5），隧道内已改用公共解析器。
  bool get tunnelDnsRemappedFromLocalPreference {
    if (conf.dns.isEmpty) return false;
    var sawLocal = false;
    for (final entry in conf.dns) {
      final value = entry.trim();
      if (value.isEmpty) continue;
      if (isLocalPreferenceDns(value)) {
        sawLocal = true;
        continue;
      }
      return false;
    }
    return sawLocal;
  }

  /// 这份配置是否用到了 AmneziaWG 的混淆参数。
  bool get looksLikeAmnezia => looksLikeAmneziaWireGuard(conf.ignoredKeys);
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
