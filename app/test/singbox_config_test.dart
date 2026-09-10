import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';

/// 刻意贴近真实场景：AllowedIPs 只写了 VPN 内网段（很多服务商导出就是这样），
/// DNS 用的是隧道内的公共解析器。
const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.0.0.3/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1380

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = vpn.example.net:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
''';

Map<String, Object?> _build({SplitMode mode = SplitMode.smart}) {
  return SingBoxConfigBuilder.build(
    profile: WireGuardProfile(WireGuardConf.parse(_conf)),
    splitMode: mode,
    ruleSetDir: r'C:\Users\test\XVPN\rulesets',
  );
}

/// 便捷取值，避免测试里到处都是强制转换。
Map<String, Object?> _map(Object? value) => (value! as Map<Object?, Object?>).cast<String, Object?>();
List<Object?> _list(Object? value) => value! as List<Object?>;

void main() {
  group('WireGuard 出站', () {
    test('翻译为 sing-box 1.11+ 的 wireguard endpoint', () {
      final endpoint = _map(_list(_build()['endpoints'])[0]);
      expect(endpoint['type'], 'wireguard');
      expect(endpoint['tag'], 'vpn');
      expect(endpoint['mtu'], 1380);
      expect(endpoint['address'], <String>['10.0.0.3/32']);
      expect(endpoint['private_key'], 'aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=');
    });

    test('peer 的地址与端口被拆开', () {
      final endpoint = _map(_list(_build()['endpoints'])[0]);
      final peer = _map(_list(endpoint['peers'])[0]);
      expect(peer['address'], 'vpn.example.net');
      expect(peer['port'], 51820);
      expect(peer['persistent_keepalive_interval'], 25);
    });

    test('忽略 .conf 的 AllowedIPs，出站方向覆盖全部地址', () {
      // 这是零配置分流的命门：若沿用 10.0.0.0/24，被墙的地址根本进不了隧道。
      final endpoint = _map(_list(_build()['endpoints'])[0]);
      final peer = _map(_list(endpoint['peers'])[0]);
      expect(peer['allowed_ips'], <String>['0.0.0.0/0', '::/0']);
    });

    test('未声明 MTU 时使用 1420 兜底', () {
      final conf = WireGuardConf.parse('''
[Interface]
PrivateKey = k
Address = 10.0.0.3/32

[Peer]
PublicKey = p
Endpoint = 1.2.3.4:51820
''');
      final config = SingBoxConfigBuilder.build(
        profile: WireGuardProfile(conf),
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
      );
      final endpoint = _map(_list(config['endpoints'])[0]);
      expect(endpoint['mtu'], 1420);
    });
  });

  group('DNS 分流', () {
    test('国内 DNS 走 direct 出站，隧道内 DNS 走 vpn', () {
      final dns = _map(_build()['dns']);
      final servers = _list(dns['servers']).map(_map).toList();

      final cn = servers.firstWhere((s) => s['tag'] == 'dns-cn');
      expect(cn['server'], '223.5.5.5');
      expect(cn['detour'], 'direct');

      final remote = servers.firstWhere((s) => s['tag'] == 'dns-remote');
      expect(remote['detour'], 'vpn');
      // 沿用 .conf 里声明的解析器
      expect(remote['server'], '8.8.8.8');
    });

    test('direct 出站带域解析器，否则 detour 指向它会被内核拒绝', () {
      // 实测：sing-box 1.14 会报
      // 「detour to an empty direct outbound makes no sense」并拒绝启动。
      final outbounds = _list(_build()['outbounds']).map(_map).toList();
      final direct = outbounds.firstWhere((o) => o['tag'] == 'direct');
      final resolver = _map(direct['domain_resolver']);
      expect(resolver['server'], 'dns-cn');
    });

    test('国内域名交给国内 DNS，其余交给隧道内 DNS', () {
      final dns = _map(_build()['dns']);
      final rules = _list(dns['rules']).map(_map).toList();
      expect(rules, hasLength(1));
      expect(rules.first['rule_set'], <String>['geosite-cn']);
      expect(rules.first['server'], 'dns-cn');
      expect(dns['final'], 'dns-remote');
    });

    test('.conf 未声明 DNS 时回退到 1.1.1.1', () {
      final conf = WireGuardConf.parse('''
[Interface]
PrivateKey = k
Address = 10.0.0.3/32

[Peer]
PublicKey = p
Endpoint = 1.2.3.4:51820
''');
      final dns = _map(SingBoxConfigBuilder.build(
        profile: WireGuardProfile(conf),
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
      )['dns']);
      final remote = _list(dns['servers']).map(_map).firstWhere((s) => s['tag'] == 'dns-remote');
      expect(remote['server'], '1.1.1.1');
    });
  });

  group('路由', () {
    test('默认走隧道，国内域名与国内 IP 直连', () {
      final route = _map(_build()['route']);
      expect(route['final'], 'vpn');

      final rules = _list(route['rules']).map(_map).toList();
      final cnRule = rules.firstWhere((r) => r['rule_set'] != null);
      expect(cnRule['rule_set'], <String>['geosite-cn', 'geoip-cn']);
      expect(cnRule['outbound'], 'direct');

      // 局域网直连，避免把内网流量塞进隧道
      expect(rules.any((r) => r['ip_is_private'] == true), isTrue);
      // 嗅探域名，IP 形式的连接也能按域名规则判定
      expect(rules.any((r) => r['action'] == 'sniff'), isTrue);
    });

    test('全局直连模式不做国内规则，全部直连', () {
      final route = _map(_build(mode: SplitMode.globalDirect)['route']);
      expect(route['final'], 'direct');
      final rules = _list(route['rules']).map(_map).toList();
      expect(rules.any((r) => r['rule_set'] != null), isFalse);
    });

    test('规则集路径使用正斜杠，Windows 反斜杠会被 sing-box 当成转义', () {
      final route = _map(_build()['route']);
      final sets = _list(route['rule_set']).map(_map).toList();
      for (final s in sets) {
        expect(s['format'], 'binary');
        expect(s['path'], contains('/'));
        expect(s['path'], isNot(contains(r'\')));
      }
      expect(sets[0]['path'], 'C:/Users/test/XVPN/rulesets/geosite-cn.srs');
      expect(sets[1]['path'], 'C:/Users/test/XVPN/rulesets/geoip-cn.srs');
    });
  });

  group('入站与观测', () {
    test('本地混合入站监听 127.0.0.1:2080', () {
      final inbound = _map(_list(_build()['inbounds'])[0]);
      expect(inbound['type'], 'mixed');
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['listen_port'], 2080);
    });

    test('开启 Clash API 以便界面读取实时连接', () {
      final exp = _map(_build()['experimental']);
      final api = _map(exp['clash_api']);
      expect(api['external_controller'], '127.0.0.1:2081');
    });
  });

  test('序列化结果是合法 JSON 且带缩进', () {
    final text = SingBoxConfigBuilder.encode(_build());
    expect(text, contains('\n  '));
    expect(text, contains('"type": "wireguard"'));
  });
}
