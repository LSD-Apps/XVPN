import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/protocols/openvpn_adapter.dart';
import 'package:xvpn/protocols/openvpn_conf.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

const _ca = '''-----BEGIN CERTIFICATE-----
MIIBkTCB+wIJAJ1l0YQFakeFakeCertForUnitTestOnly0000000000000000000000
-----END CERTIFICATE-----''';

const _staticKey = '''-----BEGIN OpenVPN Static key V1-----
000102030405060708090a0b0c0d0e0f
101112131415161718191a1b1c1d1e1f
-----END OpenVPN Static key V1-----''';

/// 一份典型客户端配置：tls-auth + 内联 CA + 老式 cipher。
const _ovpn =
    '''
client
dev tun
proto udp
remote ovpn.example.net 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
key-direction 1
verb 3
<ca>
$_ca
</ca>
<tls-auth>
$_staticKey
</tls-auth>
''';

void main() {
  group('OpenVpnConf.parse', () {
    test('解析 remote / proto / 加密套件', () {
      final conf = OpenVpnConf.parse(_ovpn);
      expect(conf.remoteHost, 'ovpn.example.net');
      expect(conf.remotePort, 1194);
      expect(conf.network, 'udp');
      expect(conf.cipher, 'AES-256-CBC');
      expect(conf.auth, 'SHA256');
      expect(conf.keyDirection, 1);
    });

    test('解析内联证书块', () {
      final conf = OpenVpnConf.parse(_ovpn);
      expect(conf.ca, contains('BEGIN CERTIFICATE'));
      expect(conf.tlsAuth, contains('BEGIN OpenVPN Static key V1'));
      expect(conf.usesTlsCrypt, isFalse);
      // 只有 CA 与 tls-auth，没有客户端证书
      expect(conf.hasInlineCredentials, isFalse);
    });

    test('proto 的各种写法归一化为 udp / tcp', () {
      String withProto(String proto) =>
          '''
client
dev tun
proto $proto
remote vpn.example.net 443
''';
      expect(OpenVpnConf.parse(withProto('udp')).network, 'udp');
      expect(OpenVpnConf.parse(withProto('udp6')).network, 'udp');
      expect(OpenVpnConf.parse(withProto('tcp')).network, 'tcp');
      expect(OpenVpnConf.parse(withProto('tcp-client')).network, 'tcp');
    });

    test('端口可写在 remote 行，也可省略（按协议取默认值）', () {
      final noPort = OpenVpnConf.parse(
        'client\nproto udp\nremote vpn.example.net\n',
      );
      expect(noPort.remotePort, 1194);
      final tcpNoPort = OpenVpnConf.parse(
        'client\nproto tcp\nremote vpn.example.net\n',
      );
      expect(tcpNoPort.remotePort, 443);
    });

    test('auth-user-pass 会标记为需要凭据', () {
      final conf = OpenVpnConf.parse(
        'client\nremote vpn.example.net 1194\nauth-user-pass\n',
        username: 'u',
        password: 'p',
      );
      expect(conf.requiresCredentials, isTrue);
      expect(conf.username, 'u');
    });

    test('需要凭据但没提供时：解析仍然成功，只是标记出来等用户补填', () {
      // 刻意不抛错。抛错会导致「凭据取不回来 → 重新解析失败 → 恢复流程跳过
      // 这份配置」，用户看到的是配置不见了。现在的契约是：配置保留，
      // 由上层提示补填账号密码。
      final conf = OpenVpnConf.parse(
        'client\nremote vpn.example.net 1194\nauth-user-pass\n',
      );
      expect(conf.requiresCredentials, isTrue);
      expect(conf.username, isNull);
      expect(conf.password, isNull);
      expect(conf.remoteHost, 'vpn.example.net', reason: '其余字段照常解析出来');
    });

    test('缺少 remote 时抛错', () {
      expect(
        () => OpenVpnConf.parse('client\ndev tun\nproto udp\n'),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('有证书却缺私钥时抛错', () {
      expect(
        () => OpenVpnConf.parse('''
client
remote vpn.example.net 1194
<cert>
$_ca
</cert>
'''),
        throwsA(
          isA<VpnConfigException>().having(
            (VpnConfigException e) => e.message,
            'message',
            contains('私钥'),
          ),
        ),
      );
    });
  });

  group('OpenVpnAdapter 识别', () {
    final adapter = OpenVpnAdapter();

    test('按内容识别 OpenVPN，即使扩展名是 .conf', () {
      expect(adapter.canParse(_ovpn, 'client.conf'), isTrue);
      expect(adapter.canParse(_ovpn, 'client.ovpn'), isTrue);
    });

    test('不会把 WireGuard 配置误判为 OpenVPN', () {
      const wg =
          '[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = p\nEndpoint = 1.2.3.4:51820\n';
      expect(adapter.canParse(wg, 'wg.conf'), isFalse);
    });

    test('普通文本不会被误判', () {
      expect(adapter.canParse('hello world', 'notes.txt'), isFalse);
    });
  });

  group('OpenVpnAdapter 生成内核端点', () {
    late Map<String, Object?> endpoint;

    setUp(() {
      final adapter = OpenVpnAdapter();
      final profile = adapter.parse(_ovpn, 'client.ovpn');
      endpoint = adapter.buildEndpoint(
        profile,
        const OutboundContext(tag: 'vpn', resolverTag: 'dns-cn'),
      );
    });

    test('端点类型是 openvpn-client（不是 openvpn）', () {
      // 实测：写成 `openvpn` 会被内核拒绝——unknown endpoint type。
      expect(endpoint['type'], 'openvpn-client');
      expect(endpoint['tag'], 'vpn');
      expect(endpoint['server'], 'ovpn.example.net');
      expect(endpoint['server_port'], 1194);
      expect(endpoint['network'], 'udp');
    });

    test('CA 证书放进 tls.certificate', () {
      final tls = endpoint['tls']! as Map<String, Object?>;
      expect(tls['certificate'], isA<List<Object?>>());
      expect(
        (tls['certificate']! as List<Object?>).first.toString(),
        contains('BEGIN CERTIFICATE'),
      );
      expect(tls['server_name'], 'ovpn.example.net');
    });

    test('tls-auth 走 control_wrap，type 用下划线且 direction 映射为 client', () {
      // 实测：type 写成 `tls-auth` 会被拒绝——unknown control wrap type；
      // direction 只接受 server / client。
      final tls = endpoint['tls']! as Map<String, Object?>;
      final wrap = tls['control_wrap']! as Map<String, Object?>;
      expect(wrap['type'], 'tls_auth');
      expect(wrap['direction'], 'client');
      expect(
        (wrap['key']! as List<Object?>).first.toString(),
        contains('Static key'),
      );
    });

    test('老式 cipher 并入 data_ciphers，不使用顶层 cipher', () {
      // 实测：TLS 模式下顶层 cipher 会被拒绝。
      expect(endpoint.containsKey('cipher'), isFalse);
      expect(endpoint['data_ciphers'], <String>['AES-256-CBC']);
    });

    test('不再输出被 TLS 模式拒绝的 static_key / key_direction', () {
      expect(endpoint.containsKey('static_key'), isFalse);
      expect(endpoint.containsKey('key_direction'), isFalse);
    });
  });

  group('协议工厂', () {
    test('按内容自动分发到正确的协议', () {
      const wg =
          '[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = p\nEndpoint = 1.2.3.4:51820\n';
      expect(
        VpnProtocolFactory.parse(wg, 'wg.conf').protocol,
        VpnProtocol.wireGuard,
      );
      expect(
        VpnProtocolFactory.parse(_ovpn, 'c.conf').protocol,
        VpnProtocol.openVpn,
      );
    });

    test('无法识别时给出列出支持格式的中文提示', () {
      expect(
        () => VpnProtocolFactory.parse('这不是配置', 'x.txt'),
        throwsA(
          isA<VpnConfigException>().having(
            (VpnConfigException e) => e.message,
            'message',
            allOf(contains('无法识别'), contains('WireGuard'), contains('OpenVPN')),
          ),
        ),
      );
    });

    test('空文件被拒绝', () {
      expect(
        () => VpnProtocolFactory.parse('   \n  ', 'empty.conf'),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('已注册的适配器覆盖全部可导入协议', () {
      final registered = VpnProtocolFactory.adapters
          .map((a) => a.protocol)
          .toSet();
      for (final p in importableProtocols) {
        expect(registered, contains(p), reason: '${p.label} 缺少适配器');
      }
    });

    test('可导入协议的扩展名可用于文件过滤', () {
      expect(allSupportedExtensions, contains('conf'));
      expect(allSupportedExtensions, contains('ovpn'));
      expect(VpnProtocolFactory.looksSupported('client.ovpn'), isTrue);
      expect(VpnProtocolFactory.looksSupported('client.conf'), isTrue);
      expect(VpnProtocolFactory.looksSupported('photo.png'), isFalse);
    });
  });
}
