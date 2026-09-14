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
Map<String, Object?> _map(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();
List<Object?> _list(Object? value) => value! as List<Object?>;

void main() {
  group('WireGuard 出站', () {
    test('翻译为 sing-box 1.11+ 的 wireguard endpoint', () {
      final endpoint = _map(_list(_build()['endpoints'])[0]);
      expect(endpoint['type'], 'wireguard');
      expect(endpoint['tag'], 'vpn');
      expect(endpoint['mtu'], 1380);
      expect(endpoint['address'], <String>['10.0.0.3/32']);
      expect(
        endpoint['private_key'],
        'aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=',
      );
    });

    test('peer 的地址与端口被拆开', () {
      final endpoint = _map(_list(_build()['endpoints'])[0]);
      final peer = _map(_list(endpoint['peers'])[0]);
      expect(peer['address'], 'vpn.example.net');
      expect(peer['port'], 51820);
      expect(peer['persistent_keepalive_interval'], 25);
    });

    test('忽略 .conf 的 AllowedIPs，出站方向覆盖全部地址', () {
      // 这是零配置分流的命门：若沿用 10.0.0.0/24，未命中规则集的地址根本进不了隧道。
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
    test('直连 DNS 走 direct 出站，隧道内 DNS 走 vpn', () {
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

    test('命中规则集的域名交给直连 DNS，其余交给隧道内 DNS', () {
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
      final dns = _map(
        SingBoxConfigBuilder.build(
          profile: WireGuardProfile(conf),
          splitMode: SplitMode.smart,
          ruleSetDir: '/tmp/rs',
        )['dns'],
      );
      final remote = _list(
        dns['servers'],
      ).map(_map).firstWhere((s) => s['tag'] == 'dns-remote');
      expect(remote['server'], '1.1.1.1');
    });

    test('配置里只有本地偏好 DNS 时，隧道内改用公共解析器', () {
      // 223.5.5.5 适合直连侧；经隧道拿去解析海外域名只会更卡。
      final conf = WireGuardConf.parse('''
[Interface]
PrivateKey = k
Address = 10.0.0.3/32
DNS = 223.5.5.5, 119.29.29.29

[Peer]
PublicKey = p
Endpoint = 1.2.3.4:51820
''');
      final profile = WireGuardProfile(conf);
      expect(profile.tunnelDnsRemappedFromLocalPreference, isTrue);
      final dns = _map(
        SingBoxConfigBuilder.build(
          profile: profile,
          splitMode: SplitMode.smart,
          ruleSetDir: '/tmp/rs',
        )['dns'],
      );
      final remote = _list(
        dns['servers'],
      ).map(_map).firstWhere((s) => s['tag'] == 'dns-remote');
      expect(remote['server'], '1.1.1.1');
    });

    test('本地偏好 DNS 与公网 DNS 并存时沿用公网那一个', () {
      final conf = WireGuardConf.parse('''
[Interface]
PrivateKey = k
Address = 10.0.0.3/32
DNS = 223.5.5.5, 8.8.8.8

[Peer]
PublicKey = p
Endpoint = 1.2.3.4:51820
''');
      final profile = WireGuardProfile(conf);
      expect(profile.tunnelDnsRemappedFromLocalPreference, isFalse);
      final dns = _map(
        SingBoxConfigBuilder.build(
          profile: profile,
          splitMode: SplitMode.smart,
          ruleSetDir: '/tmp/rs',
        )['dns'],
      );
      final remote = _list(
        dns['servers'],
      ).map(_map).firstWhere((s) => s['tag'] == 'dns-remote');
      expect(remote['server'], '8.8.8.8');
    });
  });

  group('路由', () {
    test('默认走隧道，命中规则集的域名与 IP 直连', () {
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

    test('全局直连模式不做规则集判定，全部直连', () {
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

  group('TUN 入站 MTU', () {
    /// 取 TUN 入站的 MTU。桌面端走混合入站，因此这里显式指定 tun 模式。
    int tunMtuOf(String confText, {SplitMode mode = SplitMode.smart}) {
      final config = SingBoxConfigBuilder.build(
        profile: WireGuardProfile(WireGuardConf.parse(confText)),
        splitMode: mode,
        ruleSetDir: '/tmp/rs',
        inboundMode: InboundMode.tun,
      );
      return _map(_list(config['inbounds'])[0])['mtu']! as int;
    }

    test('TUN 的 MTU 跟随配置声明的隧道 MTU', () {
      // 上面的 _conf 声明了 MTU = 1380。
      //
      // 这一条是速率问题的核心：sing-box 的 tun 入站默认 MTU 是 9000，
      // 而隧道只能装下 1380 字节的 IP 包。两者不一致时系统栈会组出 9000 的
      // 大包，进隧道后被迫在 IP 层分片，一个大包裂成七个 UDP 包——吞吐下降、
      // 延迟抖动，而且内核不会报任何错，只是「慢」。
      expect(tunMtuOf(_conf), 1380);
    });

    test('未声明 MTU 时 TUN 用 wg-quick 默认值 1420，而不是内核默认的 9000', () {
      final noMtu = _conf.replaceAll('MTU = 1380', '');
      expect(tunMtuOf(noMtu), 1420);
    });

    test('超出合理区间的 MTU 被回退，端点与 TUN 用同一个回退值', () {
      final bogus = _conf.replaceAll('MTU = 1380', 'MTU = 9000');
      final config = SingBoxConfigBuilder.build(
        profile: WireGuardProfile(WireGuardConf.parse(bogus)),
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
        inboundMode: InboundMode.tun,
      );
      final endpointMtu = _map(_list(config['endpoints'])[0])['mtu'];
      final tunMtu = _map(_list(config['inbounds'])[0])['mtu'];
      expect(tunMtu, 1420);
      expect(tunMtu, endpointMtu, reason: '两端不一致正是分片的来源，必须由同一个函数算出');
    });

    test('混合入站不带 mtu 字段（该字段只对 tun 有意义）', () {
      final inbound = _map(_list(_build()['inbounds'])[0]);
      expect(inbound.containsKey('mtu'), isFalse, reason: '给混合入站塞 mtu 是无效配置');
    });
  });

  test('序列化结果是合法 JSON 且带缩进', () {
    final text = SingBoxConfigBuilder.encode(_build());
    expect(text, contains('\n  '));
    expect(text, contains('"type": "wireguard"'));
  });
}
