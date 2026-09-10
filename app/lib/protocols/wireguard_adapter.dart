import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'vpn_protocol.dart';
import 'wireguard_conf.dart';

/// WireGuard 适配器。
class WireGuardAdapter implements VpnProtocolAdapter {
  @override
  VpnProtocol get protocol => VpnProtocol.wireGuard;

  /// 按内容识别：只要有 `[Interface]` + `PrivateKey`，就是 WireGuard。
  /// 不能只看扩展名——`.conf` 同样可能是 OpenVPN 配置。
  @override
  bool canParse(String text, String fileName) {
    final lower = text.toLowerCase();
    if (lower.contains('[interface]') && lower.contains('privatekey')) {
      return true;
    }
    // 极简配置可能省略段名大小写或顺序，这里再用 Peer 字段兜底。
    return lower.contains('[peer]') && lower.contains('publickey') && lower.contains('endpoint');
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
  Map<String, Object?> buildEndpoint(ParsedProfile profile, OutboundContext context) {
    if (profile is! WireGuardProfile) {
      throw VpnConfigException('内部错误：配置与协议不匹配');
    }
    final conf = profile.conf;
    final peer = conf.primaryPeer!;

    return <String, Object?>{
      'type': 'wireguard',
      'tag': context.tag,
      'mtu': conf.mtu ?? 1420,
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
          'persistent_keepalive_interval': peer.persistentKeepalive ?? 25,
        },
      ],
    };
  }
}
