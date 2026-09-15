import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

/// 内核日志级别必须按协议下发。
///
/// 这一条锁定的是一条**两端共用**的链路：WireGuard 握手状态只存在于 DEBUG 级
/// 的端点日志里（sing-box 把 wireguard-go 的 `Verbosef` 映射到 `Logger.Debug`），
/// 而配置生成器此前把 `log.level` 写死成 `warn`——于是哪怕解析器完全正确，
/// 两端也永远读不到握手行，界面只能停在「正在读取内核握手状态…」。
///
/// 反过来，其余协议没有这个需求：把它们的日志也调成 debug 只会让 500 行的
/// 内核日志缓冲被噪声刷掉，而那正是排查问题时唯一的原材料。
const _wireGuard = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ==
Address = 10.0.0.3/32

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = vpn.example.net:51820
AllowedIPs = 0.0.0.0/0
''';

const _openVpn = '''
client
dev tun
proto udp
remote ovpn.example.net 1194
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

const _hysteria2 =
    'hysteria2://testpassword@hy2.example.net:443/?sni=hy2.example.net';

const _shadowsocks = 'ss://aes-256-gcm:testpassword@ss.example.net:8388';

Map<String, Object?> _logOf(String text, String fileName) {
  final profile = VpnProtocolFactory.parse(text, fileName);
  final config = SingBoxConfigBuilder.build(
    profile: profile,
    splitMode: SplitMode.smart,
    ruleSetDir: r'C:\Users\test\XVPN\rulesets',
  );
  return (config['log']! as Map<Object?, Object?>).cast<String, Object?>();
}

void main() {
  group('内核日志级别按协议下发', () {
    test('WireGuard 下发 debug：握手行是 DEBUG 级，否则永远读不到', () {
      expect(_logOf(_wireGuard, 'wg.conf')['level'], 'debug');
      expect(
        VpnProtocolFactory.parse(_wireGuard, 'wg.conf').wantsDebugLogs,
        isTrue,
      );
    });

    test('OpenVPN 保持 warn：不需要为它打开 DEBUG 噪声', () {
      expect(_logOf(_openVpn, 'ovpn.conf')['level'], 'warn');
      expect(
        VpnProtocolFactory.parse(_openVpn, 'ovpn.conf').wantsDebugLogs,
        isFalse,
      );
    });

    test('Hysteria2 保持 warn：它没有握手里程碑要读', () {
      expect(_logOf(_hysteria2, 'node.txt')['level'], 'warn');
      expect(
        VpnProtocolFactory.parse(_hysteria2, 'node.txt').wantsDebugLogs,
        isFalse,
      );
    });

    test('Shadowsocks 保持 warn：流式代理没有握手里程碑', () {
      expect(_logOf(_shadowsocks, 'ss.txt')['level'], 'warn');
      expect(
        VpnProtocolFactory.parse(_shadowsocks, 'ss.txt').wantsDebugLogs,
        isFalse,
      );
    });

    test('VLESS 保持 warn：流式代理没有握手里程碑', () {
      const link =
          'vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@vless.example.net:443'
          '?type=tcp&security=tls&sni=vless.example.net';
      expect(_logOf(link, 'node.txt')['level'], 'warn');
      expect(VpnProtocolFactory.parse(link, 'node.txt').wantsDebugLogs, isFalse);
    });
  });
}
