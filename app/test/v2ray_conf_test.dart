import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/v2ray_adapter.dart';
import 'package:xvpn/protocols/v2ray_conf.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

const _uuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

String _vmessLink({
  String net = 'tcp',
  String tls = 'tls',
  Object aid = 0,
  String id = _uuid,
}) {
  final payload = <String, Object?>{
    'v': '2',
    'ps': 'example',
    'add': 'vmess.example.net',
    'port': '443',
    'id': id,
    'aid': aid,
    'scy': 'auto',
    'net': net,
    'type': 'none',
    'host': 'vmess.example.net',
    'path': '/ws',
    'tls': tls,
    'sni': 'vmess.example.net',
  };
  return 'vmess://${base64Encode(utf8.encode(jsonEncode(payload)))}';
}

const _vlessLink =
    'vless://$_uuid@vless.example.net:443?type=ws&security=tls'
    '&sni=vless.example.net&path=%2Fpath&host=vless.example.net#example';

const _trojanLink =
    'trojan://testpassword@trojan.example.net:443?security=tls'
    '&sni=trojan.example.net&type=tcp#example';

const _vmessJson = '''
{
  "type": "vmess",
  "tag": "vpn",
  "server": "vmess.example.net",
  "server_port": 443,
  "uuid": "$_uuid",
  "security": "auto",
  "tls": { "enabled": true, "server_name": "vmess.example.net" }
}
''';

void main() {
  group('按内容识别', () {
    test('三种分享链接前缀互不抢', () {
      expect(VmessAdapter().canParse(_vmessLink(), 'x.txt'), isTrue);
      expect(VmessAdapter().canParse(_vlessLink, 'x.txt'), isFalse);
      expect(VlessAdapter().canParse(_vlessLink, 'x.txt'), isTrue);
      expect(TrojanAdapter().canParse(_trojanLink, 'x.txt'), isTrue);
      expect(TrojanAdapter().canParse(_vlessLink, 'x.txt'), isFalse);
    });

    test('认识 sing-box JSON，不会把其它出站认成自己', () {
      expect(VmessAdapter().canParse(_vmessJson, 'x.json'), isTrue);
      expect(
        VmessAdapter().canParse(
          '{"type": "shadowsocks", "server": "a"}',
          'x.json',
        ),
        isFalse,
      );
      expect(VlessAdapter().canParse(_vmessJson, 'x.json'), isFalse);
    });

    test('工厂按内容分发', () {
      expect(
        VpnProtocolFactory.parse(_vmessLink(), 'n.txt').protocol,
        VpnProtocol.vmess,
      );
      expect(
        VpnProtocolFactory.parse(_vlessLink, 'n.txt').protocol,
        VpnProtocol.vless,
      );
      expect(
        VpnProtocolFactory.parse(_trojanLink, 'n.txt').protocol,
        VpnProtocol.trojan,
      );
    });
  });

  group('VMess 解析', () {
    test('aid 既接受数字也接受字符串', () {
      expect(V2RayConf.parse(_vmessLink(aid: 0), V2RayKind.vmess).alterId, 0);
      expect(V2RayConf.parse(_vmessLink(aid: '4'), V2RayKind.vmess).alterId, 4);
    });

    test('WebSocket + TLS 映射到内核字段', () {
      final conf = V2RayConf.parse(_vmessLink(net: 'ws'), V2RayKind.vmess);
      expect(conf.transport.kind, V2RayTransportKind.ws);
      expect(conf.transport.path, '/ws');
      expect(conf.tls?.security, V2RaySecurity.tls);
      final outbound = conf.toOutbound(tag: 'vpn', resolverTag: 'dns-direct');
      expect(outbound['type'], 'vmess');
      expect((outbound['transport']! as Map)['type'], 'ws');
      expect((outbound['tls']! as Map)['enabled'], isTrue);
    });

    test('不支持的传输在解析阶段拒绝', () {
      expect(
        () => V2RayConf.parse(_vmessLink(net: 'kcp'), V2RayKind.vmess),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('不支持的传输方式'),
          ),
        ),
      );
    });

    test('非法 UUID 拒绝', () {
      expect(
        () => V2RayConf.parse(_vmessLink(id: 'not-a-uuid'), V2RayKind.vmess),
        throwsA(isA<VpnConfigException>()),
      );
    });
  });

  group('VLESS / Trojan', () {
    test('VLESS 读出 flow 与 ws 参数', () {
      const link =
          'vless://$_uuid@vless.example.net:443?type=tcp&security=reality'
          '&pbk=11111111111111111111111111111111&sid=abcd&fp=chrome'
          '&flow=xtls-rprx-vision#ex';
      final conf = V2RayConf.parse(link, V2RayKind.vless);
      expect(conf.flow, 'xtls-rprx-vision');
      expect(conf.tls?.security, V2RaySecurity.reality);
      expect(conf.tls?.realityPublicKey, isNotEmpty);
      final tls = conf.toOutbound(tag: 'vpn', resolverTag: 'd')['tls'] as Map;
      expect(tls['reality'], isNotNull);
    });

    test('Reality 缺公钥时报错，而不是悄悄丢掉', () {
      const link =
          'vless://$_uuid@vless.example.net:443?type=tcp&security=reality';
      expect(
        () => V2RayConf.parse(link, V2RayKind.vless),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('公钥'),
          ),
        ),
      );
    });

    test('Trojan 未声明 security 时默认启用 TLS', () {
      const link = 'trojan://pw@trojan.example.net:443#x';
      final conf = V2RayConf.parse(link, V2RayKind.trojan);
      expect(conf.tls?.security, V2RaySecurity.tls);
      expect(conf.tls?.serverName, 'trojan.example.net');
    });

    test('VLESS 出站带 packet_encoding=xudp', () {
      final outbound = V2RayConf.parse(
        _vlessLink,
        V2RayKind.vless,
      ).toOutbound(tag: 'vpn', resolverTag: 'd');
      expect(outbound['packet_encoding'], 'xudp');
    });

    test('IPv6 主机与含特殊字符的密码能往返', () {
      const link =
          'trojan://p%40ss%2Fword@[2001:db8::1]:443?security=tls'
          '&sni=trojan.example.net#x';
      final conf = V2RayConf.parse(link, V2RayKind.trojan);
      expect(conf.server, '2001:db8::1');
      expect(conf.secret, 'p@ss/word');
      final round = V2RayConf.parse(conf.toShareLink(), V2RayKind.trojan);
      expect(round.server, '2001:db8::1');
      expect(round.secret, 'p@ss/word');
    });
  });

  group('详情不回显凭据', () {
    test('UUID 与密码都显示占位', () {
      final vmess = V2RayProfile(V2RayConf.parse(_vmessLink(), V2RayKind.vmess));
      expect(vmess.details.any((d) => d.value.contains(_uuid)), isFalse);
      final trojan = V2RayProfile(
        V2RayConf.parse(_trojanLink, V2RayKind.trojan),
      );
      expect(trojan.details.any((d) => d.value.contains('testpassword')), isFalse);
    });
  });

  group('可导入', () {
    test('三个协议都已开放导入', () {
      expect(VpnProtocol.vmess.isImportable, isTrue);
      expect(VpnProtocol.vless.isImportable, isTrue);
      expect(VpnProtocol.trojan.isImportable, isTrue);
    });
  });

  test('生成的出站带 domain_resolver，避免服务端域名解析死锁', () {
    final conf = V2RayConf.parse(_trojanLink, V2RayKind.trojan);
    final outbound = conf.toOutbound(tag: 'vpn', resolverTag: 'dns-direct');
    expect((outbound['domain_resolver']! as Map)['server'], 'dns-direct');
  });

  test('配置生成器把片段放进 outbounds 而不是 endpoints', () {
    final profile = VpnProtocolFactory.parse(_vlessLink, 'n.txt');
    final config = SingBoxConfigBuilder.build(
      profile: profile,
      splitMode: SplitMode.smart,
      inboundMode: InboundMode.mixed,
      ruleSetDir: r'C:\Users\test\XVPN\rulesets',
    );
    final outbounds = config['outbounds']! as List;
    expect(
      outbounds.any((item) => item is Map && item['type'] == 'vless'),
      isTrue,
    );
    final endpoints = config['endpoints'];
    if (endpoints is List) {
      expect(
        endpoints.any((item) => item is Map && item['type'] == 'vless'),
        isFalse,
      );
    }
  });
}
