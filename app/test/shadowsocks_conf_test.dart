import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/shadowsocks_adapter.dart';
import 'package:xvpn/protocols/shadowsocks_conf.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

const _plain =
    'ss://aes-256-gcm:testpassword@ss.example.net:8388#example';

const _json = '''
{
  "type": "shadowsocks",
  "tag": "ss-out",
  "server": "ss.example.net",
  "server_port": 8388,
  "method": "aes-256-gcm",
  "password": "testpassword"
}
''';

String _sip002({
  required String method,
  required String password,
  required String host,
  int port = 8388,
  String? plugin,
  String? tag,
}) {
  final userinfo = base64Url
      .encode(utf8.encode('$method:$password'))
      .replaceAll('=', '');
  final buffer = StringBuffer('ss://$userinfo@$host:$port');
  if (plugin != null) {
    buffer.write('/?plugin=${Uri.encodeQueryComponent(plugin)}');
  }
  if (tag != null) buffer.write('#${Uri.encodeComponent(tag)}');
  return buffer.toString();
}

Map<String, Object?> _map(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

void main() {
  group('按内容识别', () {
    final adapter = ShadowsocksAdapter();

    test('认识 ss:// 前缀，包括前面带注释的导出文件', () {
      expect(adapter.canParse(_plain, 'x.txt'), isTrue);
      expect(
        adapter.canParse('# 说明\n\nss://aes-256-gcm:pw@a.example.net:1', 'x.txt'),
        isTrue,
      );
      expect(adapter.canParse('SS://aes-256-gcm:pw@a.example.net:1', 'x.txt'), isTrue);
    });

    test('认识 sing-box 出站 JSON，但不会把别的 JSON 认成 Shadowsocks', () {
      expect(adapter.canParse(_json, 'x.json'), isTrue);
      expect(
        adapter.canParse('{"type": "hysteria2", "server": "a"}', 'x.json'),
        isFalse,
      );
      expect(adapter.canParse('{"foo": "shadowsocks"}', 'x.json'), isFalse);
    });

    test('不会把 WireGuard / OpenVPN / Hysteria2 认成 Shadowsocks', () {
      const wg =
          '[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n'
          '\n[Peer]\nPublicKey = p\nEndpoint = a.example.net:51820\n';
      const ovpn = 'client\ndev tun\nremote a.example.net 1194\n';
      const hy2 = 'hysteria2://pw@a.example.net:443';
      expect(adapter.canParse(wg, 'x.conf'), isFalse);
      expect(adapter.canParse(ovpn, 'x.ovpn'), isFalse);
      expect(adapter.canParse(hy2, 'x.txt'), isFalse);
    });

    test('工厂按内容分发到 Shadowsocks；.txt / .json 是约定扩展名', () {
      final profile = VpnProtocolFactory.parse(_plain, 'node.txt');
      expect(profile.protocol, VpnProtocol.shadowsocks);
      expect(profile, isA<ShadowsocksProfile>());
      expect(VpnProtocol.shadowsocks.isImportable, isTrue);
      expect(VpnProtocolFactory.looksSupported('node.txt'), isTrue);
      expect(VpnProtocolFactory.looksSupported('ss.json'), isTrue);
    });
  });

  group('分享链接', () {
    test('明文 userinfo：方法、密码、主机、备注', () {
      final conf = ShadowsocksConf.parse(_plain);
      expect(conf.server, 'ss.example.net');
      expect(conf.port, 8388);
      expect(conf.method, 'aes-256-gcm');
      expect(conf.password, 'testpassword');
      expect(conf.displayName, 'example');
      expect(conf.source, ShadowsocksSource.link);
    });

    test('SIP002：userinfo 为 base64(method:password)', () {
      final link = _sip002(
        method: 'chacha20-ietf-poly1305',
        password: 'p@ss:word',
        host: 'ss.example.net',
        tag: '备注',
      );
      final conf = ShadowsocksConf.parse(link);
      expect(conf.method, 'chacha20-ietf-poly1305');
      expect(conf.password, 'p@ss:word');
      expect(conf.displayName, '备注');
    });

    test('旧式整串 base64(method:password@host:port)', () {
      final inner = utf8.encode(
        'aes-256-gcm:testpassword@ss.example.net:8388',
      );
      final link = 'ss://${base64.encode(inner)}';
      final conf = ShadowsocksConf.parse(link);
      expect(conf.server, 'ss.example.net');
      expect(conf.port, 8388);
      expect(conf.method, 'aes-256-gcm');
      expect(conf.password, 'testpassword');
    });

    test('插件 query 拆成 plugin 与 plugin_opts', () {
      final link = _sip002(
        method: 'aes-256-gcm',
        password: 'pw',
        host: 'ss.example.net',
        plugin: 'obfs-local;obfs=http;obfs-host=www.example.com',
      );
      final conf = ShadowsocksConf.parse(link);
      expect(conf.plugin, 'obfs-local');
      expect(conf.pluginOpts, 'obfs=http;obfs-host=www.example.com');
      expect(conf.usesPlugin, isTrue);
      expect(conf.isKnownPlugin, isTrue);
    });

    test('未写端口时按 Shadowsocks 惯例用 8388', () {
      expect(
        ShadowsocksConf.parse('ss://aes-256-gcm:pw@ss.example.net').port,
        8388,
      );
    });

    test('不认识的加密方法在解析阶段报错，而不是留给内核 FATAL', () {
      expect(
        () => ShadowsocksConf.parse('ss://bf-cfb:pw@ss.example.net:1'),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('不支持的加密方法'),
          ),
        ),
      );
    });

    test('缺少密码时报错', () {
      expect(
        () => ShadowsocksConf.parse('ss://aes-256-gcm:@ss.example.net:1'),
        throwsA(isA<VpnConfigException>()),
      );
    });
  });

  group('JSON', () {
    test('读出 sing-box 出站字段', () {
      final conf = ShadowsocksConf.parse(_json);
      expect(conf.server, 'ss.example.net');
      expect(conf.port, 8388);
      expect(conf.method, 'aes-256-gcm');
      expect(conf.password, 'testpassword');
      expect(conf.source, ShadowsocksSource.json);
      expect(conf.displayName, 'ss-out');
    });

    test('从整份 sing-box 配置里挑第一条 shadowsocks 出站', () {
      const full = '''
{
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "shadowsocks",
      "server": "ss.example.net",
      "server_port": 443,
      "method": "aes-128-gcm",
      "password": "pw"
    }
  ]
}
''';
      final conf = ShadowsocksConf.parse(full);
      expect(conf.method, 'aes-128-gcm');
      expect(conf.port, 443);
    });
  });

  group('内核片段', () {
    test('属于 outbounds，字段名是内核要的那些', () {
      expect(ShadowsocksAdapter().placement, FragmentPlacement.outbound);
      final profile = ShadowsocksProfile(ShadowsocksConf.parse(_plain));
      final fragment = ShadowsocksAdapter().buildEndpoint(
        profile,
        const OutboundContext(tag: 'vpn', resolverTag: 'dns-direct'),
      );
      expect(fragment['type'], 'shadowsocks');
      expect(fragment['server'], 'ss.example.net');
      expect(fragment['server_port'], 8388);
      expect(fragment['method'], 'aes-256-gcm');
      expect(fragment['password'], 'testpassword');
      expect(_map(fragment['domain_resolver'])['server'], 'dns-direct');
      expect(fragment.containsKey('plugin'), isFalse);
    });

    test('插件进入 plugin / plugin_opts，TUN MTU 为 1500', () {
      final link = _sip002(
        method: 'aes-256-gcm',
        password: 'pw',
        host: 'ss.example.net',
        plugin: 'v2ray-plugin;tls;host=ss.example.net',
      );
      final profile = ShadowsocksProfile(ShadowsocksConf.parse(link));
      final fragment = ShadowsocksAdapter().buildEndpoint(
        profile,
        const OutboundContext(tag: 'vpn', resolverTag: 'd'),
      );
      expect(fragment['plugin'], 'v2ray-plugin');
      expect(fragment['plugin_opts'], 'tls;host=ss.example.net');
      expect(ShadowsocksAdapter().tunMtu(profile), 1500);
    });
  });

  group('展示与提示', () {
    test('details 不回显口令', () {
      final profile = ShadowsocksProfile(ShadowsocksConf.parse(_plain));
      expect(profile.conf.passwordDisplay, '已设置');
      expect(
        profile.details.any((e) => e.value.contains('testpassword')),
        isFalse,
      );
      expect(profile.needsIpv4OnlyDns, isFalse);
      expect(profile.notices, isEmpty, reason: 'AEAD 且无插件不应提示');
    });

    test('流密码给出 info；不认识的插件给出 warn', () {
      final stream = ShadowsocksProfile(
        ShadowsocksConf.parse('ss://aes-256-ctr:pw@ss.example.net:1'),
      );
      expect(stream.notices.single.kind, ProfileNoticeKind.info);
      expect(stream.notices.single.message, contains('流密码'));

      final unknown = ShadowsocksProfile(
        ShadowsocksConf.parse(
          _sip002(
            method: 'aes-256-gcm',
            password: 'pw',
            host: 'ss.example.net',
            plugin: 'kcptun;key=x',
          ),
        ),
      );
      expect(unknown.notices.single.kind, ProfileNoticeKind.warn);
      expect(unknown.notices.single.message, contains('kcptun'));
    });
  });

  group('往返', () {
    test('toShareLink 再解析得到相同字段', () {
      final first = ShadowsocksConf.parse(
        _sip002(
          method: 'aes-256-gcm',
          password: 'p@ss word',
          host: 'ss.example.net',
          plugin: 'obfs-local;obfs=http',
          tag: '家',
        ),
      );
      final second = ShadowsocksConf.parse(first.toShareLink());
      expect(second.server, first.server);
      expect(second.port, first.port);
      expect(second.method, first.method);
      expect(second.password, first.password);
      expect(second.plugin, first.plugin);
      expect(second.pluginOpts, first.pluginOpts);
      expect(second.displayName, first.displayName);
    });
  });

  group('完整配置形状', () {
    test('生成的配置含 shadowsocks 出站而不是 endpoint', () {
      final parsed = VpnProtocolFactory.parse(_plain, 'ss.txt');
      final config = SingBoxConfigBuilder.build(
        profile: parsed,
        splitMode: SplitMode.smart,
        ruleSetDir: Directory.systemTemp.path,
        inboundMode: InboundMode.mixed,
        logSplits: false,
      );
      expect(config['outbounds'], isA<List>());
      final vpn = (config['outbounds']! as List).first as Map;
      expect(vpn['type'], 'shadowsocks');
      expect(config['endpoints'], isNull);
      expect(parsed.wantsDebugLogs, isFalse);
    });
  });
}
