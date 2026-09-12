import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/hysteria2_adapter.dart';
import 'package:xvpn/protocols/hysteria2_conf.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

/// 32 字节（SHA-256）公钥指纹的合法 base64。
const _validPin = 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=';

/// 面板给出的分享链接：带 SNI、混淆与 insecure。
const _link =
    'hysteria2://mypassword@hy2.example.net:443/?sni=hy2.example.net'
    '&insecure=1&obfs=salamander&obfs-password=obfspass#%E6%96%B0%E5%8A%A0%E5%9D%A1';

/// 官方 Hysteria2 客户端的 config.yaml（字段名与官方文档一致）。
const _yaml = '''
# Hysteria2 客户端配置
server: hy2.example.net:443
auth: mypassword
tls:
  sni: hy2.example.net
  insecure: false
obfs:
  type: salamander
  password: obfspass
up: 50 mbps
down: 200 mbps
fastOpen: true
''';

const _json = '''
{
  "type": "hysteria2",
  "tag": "vpn",
  "server": "hy2.example.net",
  "server_port": 443,
  "password": "mypassword",
  "tls": { "enabled": true, "server_name": "hy2.example.net" }
}
''';

Map<String, Object?> _map(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();
List<Object?> _list(Object? value) => value! as List<Object?>;

void main() {
  group('按内容识别', () {
    final adapter = Hysteria2Adapter();

    test('认识两种分享链接前缀', () {
      expect(adapter.canParse('hysteria2://pw@a.example.net:443', 'x.txt'), isTrue);
      expect(adapter.canParse('hy2://pw@a.example.net:443', 'x.txt'), isTrue);
      // 面板导出的文件常带前后空白与换行
      expect(
        adapter.canParse('\n  hysteria2://pw@a.example.net:443\n', 'x.txt'),
        isTrue,
      );
    });

    test('认识 sing-box 出站 JSON，但不会把随便一份 JSON 认成 Hysteria2', () {
      expect(adapter.canParse(_json, 'x.json'), isTrue);
      expect(adapter.canParse('{"type": "shadowsocks", "server": "a"}', 'x.json'), isFalse);
      expect(adapter.canParse('{"foo": "hysteria2"}', 'x.json'), isFalse);
    });

    test('认识官方 YAML，但要求出现 Hysteria2 专有键', () {
      expect(adapter.canParse(_yaml, 'config.yaml'), isTrue);
      // 只有 server: 的 YAML 不该被吞掉——那可能是任何东西
      expect(adapter.canParse('server: a.example.net:443\n', 'x.yaml'), isFalse);
    });

    test('不会把 WireGuard / OpenVPN 配置认成 Hysteria2', () {
      const wg = '[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n'
          '\n[Peer]\nPublicKey = p\nEndpoint = a.example.net:51820\n';
      const ovpn = 'client\ndev tun\nremote a.example.net 1194\n';
      expect(adapter.canParse(wg, 'x.conf'), isFalse);
      expect(adapter.canParse(ovpn, 'x.ovpn'), isFalse);
    });

    test('链接前面带注释行时仍然认得出来（面板与自存文件就是这样）', () {
      // 这是被 testdata 里那份示例逼出来的回归：注释行开头的文件
      // 一度完全导入不进来，因为识别用的是「整段文本 startsWith」。
      const withHeader = '''
# 节点说明
# 由面板导出

hysteria2://pw@a.example.net:443
''';
      expect(adapter.canParse(withHeader, 'node.txt'), isTrue);
      expect(Hysteria2Conf.parse(withHeader).server, 'a.example.net');
    });

    test('工厂按内容分发到 Hysteria2；导入只看内容，约定的扩展名另算', () {
      // 分享链接即使存成 .txt 也照样导入——协议判定按内容，不看扩展名。
      final profile = VpnProtocolFactory.parse(_link, 'node.txt');
      expect(profile.protocol, VpnProtocol.hysteria2);
      expect(profile, isA<Hysteria2Profile>());
      // 但约定的扩展名只有 YAML：文件选择器的过滤按这套命名。
      expect(VpnProtocolFactory.looksSupported('config.yaml'), isTrue);
      expect(VpnProtocolFactory.looksSupported('config.yml'), isTrue);
      expect(VpnProtocolFactory.looksSupported('node.txt'), isFalse);
      // 未实现的协议仍然不给入口
      expect(VpnProtocol.hysteria2.isImportable, isTrue);
      expect(VpnProtocol.shadowsocks.isImportable, isFalse);
    });
  });

  group('分享链接', () {
    test('拆出凭据、服务器、SNI、混淆与备注名', () {
      final conf = Hysteria2Conf.parse(_link);
      expect(conf.server, 'hy2.example.net');
      expect(conf.port, 443);
      expect(conf.auth, 'mypassword');
      expect(conf.sni, 'hy2.example.net');
      expect(conf.insecure, isTrue, reason: 'insecure=1 必须被识别，否则校验开着会握手失败');
      expect(conf.obfsPassword, 'obfspass');
      expect(conf.usesObfs, isTrue);
      expect(conf.displayName, '新加坡', reason: '链接里 # 后面是 URL 编码的备注名');
      expect(conf.source, Hysteria2Source.link);
    });

    test('密码里的转义字符被还原', () {
      final conf = Hysteria2Conf.parse('hysteria2://p%40ss%3Aword@a.example.net:8443');
      expect(conf.auth, 'p@ss:word');
      expect(conf.port, 8443);
    });

    test('密码里出现未转义的 @ 时，按最后一个 @ 切分', () {
      // 一些面板生成的就是这种链接；按第一个 @ 切会把密码截断，
      // 用户只会看到「认证失败」，而原因在解析这一步。
      final conf = Hysteria2Conf.parse('hysteria2://user@host@a.example.net:443');
      expect(conf.auth, 'user@host');
      expect(conf.server, 'a.example.net');
    });

    test('未写端口时按 Hysteria2 的惯例用 443', () {
      expect(Hysteria2Conf.parse('hysteria2://pw@a.example.net').port, 443);
    });

    test('端口跳跃 mport 归一化成内核要求的 a:b 区间', () {
      // 实测：内核只接受区间写法，写单端口会报 bad port range 并拒绝启动。
      final conf = Hysteria2Conf.parse(
        'hysteria2://pw@a.example.net:443?mport=20000-30000',
      );
      expect(conf.serverPorts, <String>['20000:30000']);
      expect(conf.hasPortHopping, isTrue);
    });

    test('mport 写反了按笔误换回来，单端口补成区间', () {
      final reversed = Hysteria2Conf.parse(
        'hysteria2://pw@a.example.net:443?mport=9443-8443',
      );
      expect(reversed.serverPorts, <String>['8443:9443']);

      final single = Hysteria2Conf.parse(
        'hysteria2://pw@a.example.net:443?mport=8443',
      );
      expect(single.serverPorts, <String>['8443:8443']);
    });

    test('缺凭据直接报错，而不是留一个连不上的节点', () {
      expect(
        () => Hysteria2Conf.parse('hysteria2://a.example.net:443'),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('认证凭据'),
          ),
        ),
      );
    });

    test('不支持的混淆类型直接报错', () {
      expect(
        () => Hysteria2Conf.parse(
          'hysteria2://pw@a.example.net:443?obfs=whatever&obfs-password=x',
        ),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('salamander'),
          ),
        ),
      );
    });

    test('声明了混淆却没给密码时报错——不能悄悄丢掉这层伪装', () {
      expect(
        () => Hysteria2Conf.parse('hysteria2://pw@a.example.net:443?obfs=salamander'),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('混淆密码'),
          ),
        ),
      );
    });

    test('指纹必须是 32 字节的 base64，不合法就报错而不是丢掉', () {
      // 丢掉指纹 = 悄悄放弃用户显式要求的证书固定，属于安全降级；
      // 报错只让他改一次链接。这与「认不出的加密套件直接剔除」不同。
      expect(
        () => Hysteria2Conf.parse(
          'hysteria2://pw@a.example.net:443?pinSHA256=AAAA',
        ),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('32 字节'),
          ),
        ),
      );
    });

    test('省略补齐符的 URL-safe 指纹会被补回标准 base64', () {
      final noPadding = _validPin.replaceAll('=', '');
      final conf = Hysteria2Conf.parse(
        'hysteria2://pw@a.example.net:443?pinSHA256=$noPadding',
      );
      expect(conf.pinSha256, _validPin);
    });
  });

  group('官方 YAML', () {
    test('读齐字段，并识别 up/down 的单位写法', () {
      final conf = Hysteria2Conf.parse(_yaml);
      expect(conf.server, 'hy2.example.net');
      expect(conf.port, 443);
      expect(conf.auth, 'mypassword');
      expect(conf.sni, 'hy2.example.net');
      expect(conf.insecure, isFalse);
      expect(conf.obfsPassword, 'obfspass');
      expect(conf.upMbps, 50, reason: '官方 YAML 写的是 `up: 50 mbps`');
      expect(conf.downMbps, 200);
      expect(conf.source, Hysteria2Source.yaml);
      // 与本 App 无关的字段要说出来，而不是默默无视
      expect(conf.ignoredFields, contains('fastOpen'));
    });

    test('server 支持带端口跳跃的写法', () {
      final conf = Hysteria2Conf.parse(
        'server: a.example.net:443,8443-9443\nauth: pw\n',
      );
      expect(conf.server, 'a.example.net');
      expect(conf.port, 443);
      expect(conf.serverPorts, <String>['8443:9443']);
    });

    test('混淆也支持 `obfs: salamander` + `obfs-password` 的面板写法', () {
      final conf = Hysteria2Conf.parse(
        'server: a.example.net:443\nauth: pw\nobfs: salamander\n'
        'obfs-password: obfspass\n',
      );
      expect(conf.obfsPassword, 'obfspass');
      expect(conf.usesObfs, isTrue);
    });

    test('tls 段里的 sni / insecure / alpn / pinSHA256 都能读出来', () {
      final conf = Hysteria2Conf.parse('''
server: a.example.net:443
auth: pw
tls:
  sni: real.example.net
  insecure: true
  alpn: [h3, h2]
  pinSHA256: $_validPin
''');
      expect(conf.sni, 'real.example.net');
      expect(conf.insecure, isTrue);
      expect(conf.alpn, <String>['h3', 'h2']);
      expect(conf.pinSha256, _validPin);
    });

    test('注释与引号不会破坏解析', () {
      final conf = Hysteria2Conf.parse('''
# 顶层注释
server: "a.example.net:8443"   # 行尾注释
auth: 'pw#not-a-comment'
''');
      expect(conf.server, 'a.example.net');
      expect(conf.port, 8443);
      expect(conf.auth, 'pw#not-a-comment', reason: '引号里的 # 是密码的一部分');
    });

    test('tls / obfs 段里用不到的键要报出来，不能静默丢弃', () {
      // `tls.utls`（指纹伪装）或 `tls.ca`（自定义根证书）被悄悄忽略，
      // 用户只会看到「握手失败」或「能用但特征明显」，而界面上看不出原因。
      final conf = Hysteria2Conf.parse('''
server: a.example.net:443
auth: pw
tls:
  sni: a.example.net
  utls:
    enabled: true
    fingerprint: chrome
obfs:
  type: salamander
  password: obfspass
  extra: x
''');
      expect(conf.ignoredFields, contains('tls.utls'));
      expect(conf.ignoredFields, contains('obfs.extra'));
    });

    test('JSON 的 tls 段里用不到的键同样要报出来', () {
      final conf = Hysteria2Conf.parse('''
{"type":"hysteria2","server":"a.example.net","server_port":443,
 "password":"pw",
 "tls":{"enabled":true,"server_name":"a.example.net",
        "utls":{"enabled":true,"fingerprint":"chrome"}}}
''');
      expect(conf.ignoredFields, contains('tls.utls'));
    });

    test('缺 server 时报错', () {
      expect(
        () => Hysteria2Conf.parse('auth: pw\n'),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('不支持的列表写法明确报错并给出行号，而不是猜着解析', () {
      // 悄悄解析错一份 YAML 的后果是「导入成功但连不上」，
      // 比直接报错糟糕得多。
      expect(
        () => Hysteria2Conf.parse(
          'server: a.example.net:443\nauth: pw\nalpn:\n  - h3\n',
        ),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('第 4 行'),
          ),
        ),
      );
    });
  });

  group('sing-box 出站 JSON', () {
    test('单个出站可直接导入', () {
      final conf = Hysteria2Conf.parse(_json);
      expect(conf.server, 'hy2.example.net');
      expect(conf.port, 443);
      expect(conf.auth, 'mypassword');
      expect(conf.sni, 'hy2.example.net');
      expect(conf.source, Hysteria2Source.json);
    });

    test('整份配置里能挑出 hysteria2 出站', () {
      final conf = Hysteria2Conf.parse('''
{
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "hysteria2", "tag": "vpn", "server": "a.example.net",
      "server_port": 8443, "password": "pw",
      "server_ports": ["443:443"], "hop_interval": "30s" }
  ]
}
''');
      expect(conf.server, 'a.example.net');
      expect(conf.port, 8443);
      expect(conf.serverPorts, <String>['443:443']);
      expect(conf.hopIntervalSeconds, 30);
    });

    test('出站类型不是 hysteria2 时报错', () {
      expect(
        () => Hysteria2Conf.parse(
          '{"outbounds": [{"type": "direct", "tag": "direct"}]}',
        ),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('JSON 语法错误给出可读说明', () {
      expect(
        () => Hysteria2Conf.parse('{ "type": "hysteria2", '),
        throwsA(
          isA<VpnConfigException>().having(
            (e) => e.message,
            'message',
            contains('JSON'),
          ),
        ),
      );
    });
  });

  group('生成内核出站片段', () {
    Map<String, Object?> build(String text, {String fileName = 'node.txt'}) {
      final profile = VpnProtocolFactory.parse(text, fileName);
      final adapter = VpnProtocolFactory.adapterForProtocol(profile.protocol);
      return adapter.buildEndpoint(
        profile,
        const OutboundContext(tag: 'vpn', resolverTag: 'dns-cn'),
      );
    }

    test('Hysteria2 属于 outbounds 而不是 endpoints', () {
      // 实测：放进 endpoints 会被内核拒绝并报 unknown endpoint type: hysteria2。
      expect(Hysteria2Adapter().placement, FragmentPlacement.outbound);
    });

    test('基本字段与 TLS 段', () {
      final out = build(_link);
      expect(out['type'], 'hysteria2');
      expect(out['tag'], 'vpn');
      expect(out['server'], 'hy2.example.net');
      expect(out['server_port'], 443);
      expect(out['password'], 'mypassword');

      final tls = _map(out['tls']);
      // 内核要求 tls 必须存在（否则 TLS required），
      // 且 server_name 与 insecure 至少有一个。
      expect(tls['enabled'], isTrue);
      expect(tls['server_name'], 'hy2.example.net');
      expect(tls['insecure'], isTrue);
    });

    test('未声明 SNI 时用服务器名兜底，否则内核报 missing server_name', () {
      final out = build(_yaml.replaceAll('  sni: hy2.example.net\n', ''));
      final tls = _map(out['tls']);
      expect(tls['server_name'], 'hy2.example.net');
      expect(tls.containsKey('insecure'), isFalse, reason: '没声明就不替用户关校验');
    });

    test('混淆、端口跳跃与带宽按内核的字段名下发', () {
      final out = build('''
server: a.example.net:443
auth: pw
obfs:
  type: salamander
  password: obfspass
up: 100 mbps
down: 300 mbps
''');
      final obfs = _map(out['obfs']);
      expect(obfs['type'], 'salamander');
      expect(obfs['password'], 'obfspass');
      expect(out['up_mbps'], 100);
      expect(out['down_mbps'], 300);
    });

    test('hop_interval 必须带单位', () {
      // 实测：写 `30` 会报 missing unit in duration "30" 并拒绝启动。
      final out = build(
        'hysteria2://pw@a.example.net:443?mport=2000-3000&hop-interval=30',
      );
      expect(out['server_ports'], <String>['2000:3000']);
      expect(out['hop_interval'], '30s');
    });

    test('证书指纹映射到 certificate_public_key_sha256', () {
      final out = build(
        'hysteria2://pw@a.example.net:443?pinSHA256=$_validPin',
      );
      final tls = _map(out['tls']);
      expect(tls['certificate_public_key_sha256'], <String>[_validPin]);
    });

    test('服务端域名用直连解析器，避免隧道建立前的死锁', () {
      final out = build(_link);
      expect(_map(out['domain_resolver'])['server'], 'dns-cn');
    });

    test('TUN 的 MTU 取 1500：流式代理没有隧道 MTU 需要对齐', () {
      expect(Hysteria2Adapter().tunMtu(Hysteria2Profile(Hysteria2Conf.parse(_link))), 1500);
    });
  });

  group('配置生成', () {
    Map<String, Object?> build({SplitMode mode = SplitMode.smart}) {
      return SingBoxConfigBuilder.build(
        profile: VpnProtocolFactory.parse(_link, 'node.txt'),
        splitMode: mode,
        ruleSetDir: r'C:\Users\test\XVPN\rulesets',
      );
    }

    test('出站片段落在 outbounds，endpoints 整个不出现', () {
      final config = build();
      final outbounds = _list(config['outbounds']).map(_map).toList();
      expect(outbounds.map((o) => o['type']), contains('hysteria2'));
      expect(outbounds.map((o) => o['tag']), contains('direct'));
      expect(
        config.containsKey('endpoints'),
        isFalse,
        reason: '给流式代理下发空的 endpoints 没有意义，内核也不需要这个键',
      );
    });

    test('DNS 与路由仍然指向 vpn 标签，分流策略不变', () {
      final config = build();
      final dns = _map(config['dns']);
      final servers = _list(dns['servers']).map(_map).toList();
      expect(
        servers.firstWhere((s) => s['tag'] == 'dns-remote')['detour'],
        'vpn',
      );
      expect(_map(config['route'])['final'], 'vpn');
    });

    test('DNS 策略不收紧成 ipv4_only（流式代理没有隧道地址）', () {
      final dns = _map(build()['dns']);
      expect(dns['strategy'], 'prefer_ipv4');
    });

    test('全局直连模式不把流量送进隧道', () {
      final route = _map(build(mode: SplitMode.globalDirect)['route']);
      expect(route['final'], 'direct');
    });

    test('TUN 入站的 MTU 是 1500，不是内核默认的 9000', () {
      final config = SingBoxConfigBuilder.build(
        profile: VpnProtocolFactory.parse(_link, 'node.txt'),
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
        inboundMode: InboundMode.tun,
      );
      expect(_map(_list(config['inbounds'])[0])['mtu'], 1500);
    });
  });

  group('仓库里的示例数据', () {
    // 这两份文件是给人看、也是给「导入即用」当样例的，因此直接拿它们跑一遍：
    // 示例与实际解析行为不一致，是文档最容易腐烂的地方。
    test('testdata 的分享链接与官方 YAML 示例都能解析', () {
      final link = File('../testdata/hysteria2-node.txt');
      final yaml = File('../testdata/hysteria2-config.yaml');
      if (!link.existsSync() || !yaml.existsSync()) {
        markTestSkipped('未找到 testdata 示例文件');
        return;
      }

      final fromLink = VpnProtocolFactory.parse(
        link.readAsStringSync(),
        link.path,
      );
      expect(fromLink.protocol, VpnProtocol.hysteria2);
      expect(fromLink.serverDisplay, contains('hy2.example.net'));
      expect(fromLink.declaredMtu, isNull);

      final fromYaml = VpnProtocolFactory.parse(
        yaml.readAsStringSync(),
        yaml.path,
      );
      expect(fromYaml.protocol, VpnProtocol.hysteria2);
      expect(fromYaml.serverDisplay, contains('hy2.example.net'));
      final obfs = fromYaml.details.firstWhere((d) => d.label == '混淆');
      expect(obfs.value, 'salamander');
    });
  });

  group('展示字段', () {
    test('凭据不回显，「配置文件」页可以放心截图', () {
      final profile = Hysteria2Profile(Hysteria2Conf.parse(_link));
      final auth = profile.details.firstWhere((d) => d.label == '认证').value;
      expect(auth, '密码');
      expect(auth, isNot(contains('mypassword')));
    });

    test('用户+密码形式的认证要区分出来', () {
      final profile = Hysteria2Profile(
        Hysteria2Conf.parse('hysteria2://user:pass@a.example.net:443'),
      );
      expect(
        profile.details.firstWhere((d) => d.label == '认证').value,
        '用户 + 密码',
      );
    });

    test('流式代理没有隧道地址与 MTU', () {
      final profile = Hysteria2Profile(Hysteria2Conf.parse(_link));
      expect(profile.addressDisplay, '—');
      expect(profile.declaredMtu, isNull);
      expect(profile.declaredDns, isEmpty);
      expect(profile.requiresCredentials, isFalse);
      expect(profile.needsIpv4OnlyDns, isFalse);
    });

    test('服务器展示串带上端口跳跃信息', () {
      final profile = Hysteria2Profile(
        Hysteria2Conf.parse('hysteria2://pw@a.example.net:443?mport=2000-3000'),
      );
      expect(profile.serverDisplay, contains('a.example.net:443'));
      expect(profile.serverDisplay, contains('2000:3000'));
    });

    test('证书校验状态如实展示', () {
      final insecure = Hysteria2Profile(Hysteria2Conf.parse(_link));
      expect(
        insecure.details.firstWhere((d) => d.label == '证书校验').value,
        contains('已关闭'),
      );

      final pinned = Hysteria2Profile(
        Hysteria2Conf.parse('hysteria2://pw@a.example.net:443?pinSHA256=$_validPin'),
      );
      expect(
        pinned.details.firstWhere((d) => d.label == '证书校验').value,
        contains('pinSHA256'),
      );
    });
  });
}
