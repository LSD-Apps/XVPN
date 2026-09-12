import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';

/// 一个典型的 wg-quick 导出配置，含注释、多余空行与行尾注释。
const _sample = '''
# 由 WireGuard 客户端导出
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32, fd00::2/128
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420
ListenPort = 51820
Table = auto          # 本 App 自行管理路由，忽略此项
PostUp = wg-quick rules

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
PresharedKey = cHNrIHZhbHVlIGdvZXMgaGVyZSBwYWRkZWQgISE=
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

void main() {
  group('WireGuardConf.parse', () {
    test('解析 Interface 段', () {
      final conf = WireGuardConf.parse(_sample);
      expect(conf.privateKey, isNotNull);
      expect(conf.addresses, <String>['10.7.0.2/32', 'fd00::2/128']);
      expect(conf.dns, <String>['1.1.1.1', '8.8.8.8']);
      expect(conf.mtu, 1420);
      expect(conf.listenPort, 51820);
      expect(conf.primaryAddressV4, '10.7.0.2');
    });

    test('解析 Peer 段', () {
      final conf = WireGuardConf.parse(_sample);
      expect(conf.peers, hasLength(1));
      final peer = conf.primaryPeer!;
      expect(peer.endpoint, '203.0.113.42:51820');
      expect(peer.allowedIps, <String>['0.0.0.0/0', '::/0']);
      expect(peer.persistentKeepalive, 25);
      expect(peer.presharedKey, isNotNull);
    });

    test('拆出端点主机与端口', () {
      final conf = WireGuardConf.parse(_sample);
      expect(conf.endpointHost, '203.0.113.42');
      expect(conf.endpointPort, 51820);
    });

    test('域名端点与 IPv6 端点的端口解析', () {
      String confWith(String endpoint) =>
          '''
[Interface]
PrivateKey = a2V5
Address = 10.0.0.2/32

[Peer]
PublicKey = cHVi
Endpoint = $endpoint
''';
      expect(
        WireGuardConf.parse(confWith('vpn.example.com:51820')).endpointHost,
        'vpn.example.com',
      );
      expect(
        WireGuardConf.parse(confWith('vpn.example.com:51820')).endpointPort,
        51820,
      );

      final v6 = WireGuardConf.parse(confWith('[fd00::1]:51821'));
      expect(v6.endpointHost, 'fd00::1');
      expect(v6.endpointPort, 51821);

      // 未写端口时按 WireGuard 默认值 51820 处理
      final noPort = WireGuardConf.parse(confWith('vpn.example.com'));
      expect(noPort.endpointHost, 'vpn.example.com');
      expect(noPort.endpointPort, 51820);
    });

    test('忽略 wg-quick 专属字段但记录下来', () {
      final conf = WireGuardConf.parse(_sample);
      expect(conf.ignoredKeys.keys, contains('table'));
      expect(conf.ignoredKeys.keys, contains('postup'));
    });

    test('缺失 PrivateKey 时给出可读的中文原因', () {
      expect(
        () => WireGuardConf.parse(
          '[Interface]\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = x\nEndpoint = 1.2.3.4:5',
        ),
        throwsA(
          isA<VpnConfigException>().having(
            (VpnConfigException e) => e.message,
            'message',
            contains('PrivateKey'),
          ),
        ),
      );
    });

    test('缺失 [Peer] 段时抛错', () {
      expect(
        () => WireGuardConf.parse(
          '[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32',
        ),
        throwsA(isA<VpnConfigException>()),
      );
    });
  });
}
