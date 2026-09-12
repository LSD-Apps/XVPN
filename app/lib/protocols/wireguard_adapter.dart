import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'protocol_tuning.dart';
import 'vpn_protocol.dart';
import 'wireguard_conf.dart';

/// WireGuard 适配器。
class WireGuardAdapter implements VpnProtocolAdapter {
  @override
  VpnProtocol get protocol => VpnProtocol.wireGuard;

  /// WireGuard 自带隧道地址，属于 sing-box 的 endpoint 类协议。
  @override
  FragmentPlacement get placement => FragmentPlacement.endpoint;

  /// 按内容识别：只要有 `[Interface]` + `PrivateKey`，就是 WireGuard。
  /// 不能只看扩展名——`.conf` 同样可能是 OpenVPN 配置。
  @override
  bool canParse(String text, String fileName) {
    final lower = text.toLowerCase();
    if (lower.contains('[interface]') && lower.contains('privatekey')) {
      return true;
    }
    // 极简配置可能省略段名大小写或顺序，这里再用 Peer 字段兜底。
    return lower.contains('[peer]') &&
        lower.contains('publickey') &&
        lower.contains('endpoint');
  }

  @override
  ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  }) {
    // WireGuard 不需要额外凭据，密钥全部在配置文件里。
    return WireGuardProfile(WireGuardConf.parse(text));
  }

  @override
  Map<String, Object?> buildEndpoint(
    ParsedProfile profile,
    OutboundContext context,
  ) {
    if (profile is! WireGuardProfile) {
      throw VpnConfigException('内部错误：配置与协议不匹配');
    }
    final conf = profile.conf;
    final peer = conf.primaryPeer!;

    // MTU：优先用配置声明的值，但要做一次合理性校验。
    //
    // 超出 1280–1500 的值几乎必然是配置写错了（低于 1280 违反 IPv6 的最小
    // MTU 要求，高于 1500 超出以太网帧），把它原样交给内核只会让隧道
    // 时通时断，而且完全看不出原因。这种情况下回退到默认值更安全。
    final mtu = resolveMtu(conf);

    return <String, Object?>{
      'type': 'wireguard',
      'tag': context.tag,
      'mtu': mtu,
      'address': conf.addresses,
      'private_key': conf.privateKey,
      // 端点域名必须用直连解析器解析，绝不能走隧道。
      //
      // 这是域名型端点的引导问题：隧道还没建立时无法通过隧道解析，
      // 而解析不出来就建不了隧道。实测报错形如
      // 「failed to resolve endpoints: lookup <端点域名>: context deadline exceeded」，
      // 表现为国外站点全部不通、国内站点却正常。
      'domain_resolver': <String, Object?>{'server': context.resolverTag},
      'peers': <Object?>[
        <String, Object?>{
          'address': conf.endpointHost,
          'port': conf.endpointPort,
          'public_key': peer.publicKey,
          if (peer.presharedKey != null && peer.presharedKey!.isNotEmpty)
            'pre_shared_key': peer.presharedKey,
          // 无论 .conf 写了什么，出站方向都要覆盖全部地址：
          // 否则「国外走隧道」根本无从谈起。
          'allowed_ips': <String>['0.0.0.0/0', '::/0'],
          // 保活：只在配置**显式声明**时才下发。
          //
          // 老实现写的是 `peer.persistentKeepalive ?? 25`，也就是给没有声明的
          // 配置硬塞一个 25 秒。这看起来更"稳"，实际有两个反效果：
          //   * 25 秒一次的握手包在移动网络上是实打实的耗电与流量，
          //     而这个配置的作者（服务端）显然并不需要它——否则他会写上；
          //   * 内核自己的默认值是 0（不发保活），也就是「只在需要时由
          //     上层流量自然维持 NAT 映射」，这是 WireGuard 官方推荐的默认。
          // 用户配置里写了 25 就尊重 25，没写就不插手。
          if (peer.persistentKeepalive != null && peer.persistentKeepalive! > 0)
            'persistent_keepalive_interval': peer.persistentKeepalive,
        },
      ],
    };
  }

  /// 未声明 MTU 时的默认值。
  ///
  /// 1420 是 wg-quick 的默认值，也是 WireGuard 社区长期验证过的、
  /// 在 1500 字节以太网上不会分片的保守取值（1500 − 20 IPv4 − 8 UDP − 32 WG 头）。
  static const int defaultMtu = 1420;

  /// 这条隧道内可承载的 IP 包大小。
  ///
  /// 端点与 TUN 入站**必须**用同一个值。抽成一个函数是为了防止两处各自
  /// 计算而漂移：一旦 Tunnel MTU 比 TUN MTU 小，系统栈就会组出装不下的包，
  /// 表现为「能连上但很慢」，排查成本极高。
  static int resolveMtu(WireGuardConf conf) =>
      sanitizeMtu(conf.mtu) ?? defaultMtu;

  /// TUN 入站的 MTU 与端点保持一致。
  @override
  int tunMtu(ParsedProfile profile) {
    if (profile is! WireGuardProfile) return defaultMtu;
    return resolveMtu(profile.conf);
  }
}
