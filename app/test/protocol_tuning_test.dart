import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/protocols/openvpn_adapter.dart';
import 'package:xvpn/protocols/openvpn_conf.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/protocol_tuning.dart';
import 'package:xvpn/protocols/wireguard_adapter.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';

/// 本文件锁定的是**实测确认过**的内核行为。
///
/// 每一条都对应一次真实的 `sing-box check` 结果；内核版本是随包分发的
/// 1.14.0（`assets/bin/sing-box.exe`）。复核命令：
///
/// ```
/// dart run tool/build_singbox_config.dart <conf> build/out.json
/// assets/bin/sing-box.exe check -c build/out.json
/// ```
///
/// 之所以要写成测试：这些坑的共同点是**失败信息完全面向开发者**
/// （「must use a canonical OpenVPN cipher name」），而用户看到的是
/// 「连不上」，没有任何线索。回归一次就是一次用户侧的疑难故障。
void main() {
  const context = OutboundContext(tag: 'vpn', resolverTag: 'dns-cn');

  group('加密套件名归一化', () {
    test('小写会被归一化成规范大写——写小写会让内核直接启动失败', () {
      // 实测：data_ciphers 里写 "aes-256-gcm" 会得到
      //   FATAL initialize endpoint[0]: ClientOptions.DataChannel.Ciphers[0]
      //         must use a canonical OpenVPN cipher name
      expect(canonicalizeCipher('aes-256-gcm'), 'AES-256-GCM');
      expect(canonicalizeCipher('aes-128-gcm'), 'AES-128-GCM');
      expect(canonicalizeCipher('chacha20-poly1305'), 'CHACHA20-POLY1305');
      expect(canonicalizeCipher('bf-cbc'), 'BF-CBC');
    });

    test('容忍下划线与多余空白', () {
      expect(canonicalizeCipher('  AES_256_CBC '), 'AES-256-CBC');
      expect(canonicalizeCipher('chacha20poly1305'), 'CHACHA20-POLY1305');
    });

    test('不认识的名字返回 null，由调用方剔除', () {
      // 实测：任何内核不认识的名字都会让端点初始化失败。
      expect(canonicalizeCipher('totally-not-a-cipher'), isNull);
      expect(canonicalizeCipher('AES-999-XYZ'), isNull);
      expect(canonicalizeCipher(''), isNull);
    });

    test('列表归一化同时剔除不认识的项并报告', () {
      final result = canonicalizeCipherList(<String>[
        'aes-256-gcm',
        'bogus-cipher',
        'AES-128-GCM',
        'aes-256-gcm', // 重复
        '',
      ]);
      expect(result.ciphers, <String>['AES-256-GCM', 'AES-128-GCM']);
      expect(result.rejected, <String>['bogus-cipher']);
    });

    test('摘要名同样规范化——sha256 会让内核失败', () {
      // 实测：auth "sha256" 会得到
      //   FATAL ... DataChannel.Auth must use a canonical OpenVPN auth name
      expect(canonicalizeAuth('sha256'), 'SHA256');
      expect(canonicalizeAuth('SHA512'), 'SHA512');
      expect(canonicalizeAuth('md5'), 'MD5');
      expect(canonicalizeAuth('not-a-digest'), isNull);
    });

    test('GCM 类套件排在 CBC 之前，但同档内保持原顺序', () {
      final ordered = preferFastCiphersFirst(<String>[
        'AES-256-CBC',
        'AES-128-GCM',
        'AES-192-CBC',
        'AES-256-GCM',
        'CHACHA20-POLY1305',
      ]);
      // GCM/POLY1305 一档，CTR 一档，CFB/OFB 一档，CBC 最后一档。
      expect(ordered.sublist(0, 3), <String>[
        'AES-128-GCM',
        'AES-256-GCM',
        'CHACHA20-POLY1305',
      ]);
      expect(ordered.sublist(3), <String>['AES-256-CBC', 'AES-192-CBC']);
    });

    test('排序是稳定的：同档内不改变用户写的顺序', () {
      final ordered = preferFastCiphersFirst(<String>[
        'AES-256-GCM',
        'AES-128-GCM',
      ]);
      expect(ordered, <String>['AES-256-GCM', 'AES-128-GCM']);
    });
  });

  group('MTU 合理性', () {
    test('合理区间内的值原样保留', () {
      expect(sanitizeMtu(1420), 1420);
      expect(sanitizeMtu(1280), 1280);
      expect(sanitizeMtu(1500), 1500);
    });

    test('超出区间的值被拒绝，由调用方回退到默认值', () {
      // 低于 1280 违反 IPv6 最小 MTU；高于 1500 超出以太网帧。
      // 两者都会让隧道时通时断，而且完全看不出原因。
      expect(sanitizeMtu(1000), isNull);
      expect(sanitizeMtu(9000), isNull);
      expect(sanitizeMtu(-1), isNull);
      expect(sanitizeMtu(null), isNull);
    });
  });

  group('AmneziaWG 识别', () {
    test('识别出混淆参数', () {
      expect(
        looksLikeAmneziaWireGuard(<String, String>{'jc': '4', 'jmin': '40'}),
        isTrue,
      );
      expect(looksLikeAmneziaWireGuard(<String, String>{'H1': '1'}), isTrue);
      expect(
        looksLikeAmneziaWireGuard(<String, String>{'mtu': '1420'}),
        isFalse,
      );
      expect(looksLikeAmneziaWireGuard(const <String, String>{}), isFalse);
    });
  });

  group('本地偏好 DNS', () {
    test('直连侧解析器被识别，隧道不得沿用', () {
      expect(isLocalPreferenceDns('223.5.5.5'), isTrue);
      expect(isLocalPreferenceDns(' 119.29.29.29 '), isTrue);
      expect(isLocalPreferenceDns('1.1.1.1'), isFalse);
      expect(isLocalPreferenceDns('8.8.8.8'), isFalse);
      expect(localPreferenceDnsServers, contains('223.5.5.5'));
    });
  });

  group('WireGuard 端点生成', () {
    const conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
''';

    test('保活只在配置显式声明时才下发', () {
      final endpoint = WireGuardAdapter().buildEndpoint(
        WireGuardProfile(_parseWg(conf)),
        context,
      );
      final peers = endpoint['peers']! as List<Object?>;
      final peer = peers.first! as Map<String, Object?>;
      expect(peer['persistent_keepalive_interval'], 25);
    });

    test('没写保活就不下发，交给内核默认（0 = 不主动发包）', () {
      final withoutKeepalive = conf.replaceAll('PersistentKeepalive = 25', '');
      final endpoint = WireGuardAdapter().buildEndpoint(
        WireGuardProfile(_parseWg(withoutKeepalive)),
        context,
      );
      final peer =
          (endpoint['peers']! as List<Object?>).first! as Map<String, Object?>;

      // 老实现写的是 `?? 25`，会给所有配置硬塞 25 秒保活：
      // 移动网络上是实打实的耗电与流量，而配置作者显然不需要它。
      expect(
        peer.containsKey('persistent_keepalive_interval'),
        isFalse,
        reason: '配置没声明保活就不该替它决定，内核默认值是 0',
      );
    });

    test('不合理的 MTU 被换成默认值', () {
      final bogus = conf.replaceAll('MTU = 1420', 'MTU = 9000');
      final profile = WireGuardProfile(_parseWg(bogus));
      final endpoint = WireGuardAdapter().buildEndpoint(profile, context);
      expect(endpoint['mtu'], WireGuardAdapter.defaultMtu);
      expect(
        WireGuardAdapter().tunMtu(profile),
        endpoint['mtu'],
        reason: 'TUN 与端点 MTU 必须同值，否则表现为能连但很慢',
      );
    });

    test('合理 MTU 原样保留', () {
      final custom = conf.replaceAll('MTU = 1420', 'MTU = 1380');
      final endpoint = WireGuardAdapter().buildEndpoint(
        WireGuardProfile(_parseWg(custom)),
        context,
      );
      expect(endpoint['mtu'], 1380);
    });

    test('未声明 MTU 时用 1420（wg-quick 默认值）', () {
      final withoutMtu = conf.replaceAll('MTU = 1420', '');
      final endpoint = WireGuardAdapter().buildEndpoint(
        WireGuardProfile(_parseWg(withoutMtu)),
        context,
      );
      expect(endpoint['mtu'], WireGuardAdapter.defaultMtu);
    });

    test('出站方向始终覆盖全部地址，与配置里的 AllowedIPs 无关', () {
      final narrow = conf.replaceAll(
        'AllowedIPs = 0.0.0.0/0',
        'AllowedIPs = 10.0.0.0/24',
      );
      final endpoint = WireGuardAdapter().buildEndpoint(
        WireGuardProfile(_parseWg(narrow)),
        context,
      );
      final peer =
          (endpoint['peers']! as List<Object?>).first! as Map<String, Object?>;
      expect(peer['allowed_ips'], <String>['0.0.0.0/0', '::/0']);
    });

    test('端点域名用直连解析器，避免引导死锁', () {
      final endpoint = WireGuardAdapter().buildEndpoint(
        WireGuardProfile(_parseWg(conf)),
        context,
      );
      expect(endpoint['domain_resolver'], <String, Object?>{
        'server': 'dns-cn',
      });
    });
  });

  group('OpenVPN 端点生成', () {
    const conf = '''
client
dev tun
proto udp
remote ovpn.example.net 1194
remote-cert-tls server
data-ciphers AES-256-GCM:aes-128-GCM:bogus-cipher
data-ciphers-fallback aes-256-cbc
auth sha256
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

    Map<String, Object?> build(String text) => OpenVpnAdapter().buildEndpoint(
      OpenVpnProfile(_parseOvpn(text)),
      context,
    );

    test('不认识的套件被剔除，小写被归一化', () {
      final endpoint = build(conf);
      expect(endpoint['data_ciphers'], <String>['AES-256-GCM', 'AES-128-GCM']);
    });

    test('fallback 单独下发，不并进协商列表', () {
      final endpoint = build(conf);
      // 实测 data_ciphers_fallback 生效且必须是规范名。
      expect(endpoint['data_ciphers_fallback'], 'AES-256-CBC');
      expect(
        (endpoint['data_ciphers']! as List<Object?>).contains('AES-256-CBC'),
        isFalse,
        reason: '把兜底套件并进协商列表，严格服务端会直接拒绝协商',
      );
    });

    test('摘要名被规范化成大写', () {
      expect(build(conf)['auth'], 'SHA256');
    });

    test('remote-cert-tls server 映射为服务端证书校验', () {
      // 这条指令几乎必然出现在客户端配置里；不映射等于悄悄放弃身份校验。
      final endpoint = build(conf);
      final tls = endpoint['tls']! as Map<String, Object?>;
      expect(tls['remote_certificate_tls'], 'server');
    });

    test('没有 remote-cert-tls 时不下发该校验', () {
      final without = conf.replaceAll('remote-cert-tls server', '');
      final tls = build(without)['tls']! as Map<String, Object?>;
      expect(tls.containsKey('remote_certificate_tls'), isFalse);
    });

    test('没有可用套件时不下发 data_ciphers，而不是下发空列表', () {
      final onlyBogus = conf
          .replaceAll(
            'data-ciphers AES-256-GCM:aes-128-GCM:bogus-cipher',
            'data-ciphers bogus-a:bogus-b',
          )
          .replaceAll('data-ciphers-fallback aes-256-cbc', '');
      final endpoint = build(onlyBogus);
      expect(endpoint.containsKey('data_ciphers'), isFalse);
      expect(endpoint.containsKey('data_ciphers_fallback'), isFalse);
    });

    test('老式 cipher 指令在没有 data-ciphers 时作为协商列表', () {
      final legacy = conf
          .replaceAll(
            'data-ciphers AES-256-GCM:aes-128-GCM:bogus-cipher',
            'cipher AES-256-CBC',
          )
          .replaceAll('data-ciphers-fallback aes-256-cbc', '');
      final endpoint = build(legacy);
      expect(endpoint['data_ciphers'], <String>['AES-256-CBC']);
      // 只有一个候选时它就是协商列表本身，不该再作为兜底重复下发。
      expect(endpoint.containsKey('data_ciphers_fallback'), isFalse);
    });

    test('老式 cipher 与 data-ciphers 并存时，cipher 作为兜底', () {
      final both = conf
          .replaceAll(
            'data-ciphers AES-256-GCM:aes-128-GCM:bogus-cipher',
            'cipher BF-CBC\ndata-ciphers AES-256-GCM',
          )
          .replaceAll('data-ciphers-fallback aes-256-cbc', '');
      final endpoint = build(both);
      expect(endpoint['data_ciphers'], <String>['AES-256-GCM']);
      expect(endpoint['data_ciphers_fallback'], 'BF-CBC');
    });

    test('未知摘要被剔除而不是原样下发', () {
      final bad = conf.replaceAll('auth sha256', 'auth sha9999');
      expect(build(bad).containsKey('auth'), isFalse);
    });
  });
}

/// 用真实的解析器解析测试配置，避免手工构造绕过校验。
WireGuardConf _parseWg(String text) => WireGuardConf.parse(text);

OpenVpnConf _parseOvpn(String text) => OpenVpnConf.parse(text);
