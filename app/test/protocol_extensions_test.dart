import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

/// 这份文件锁定「每个协议一个扩展名」的**声明式约定**：
///   * 每个扩展名只属于一个协议（否则操作系统「打开方式」会指错协议）；
///   * 协议判定始终按内容，扩展名不匹配的文件照样能导入——
///     后者是这个约定的护栏，防止有人把命名约定升级成功能要求。

/// 示例值，非真实服务器（见 CONTRIBUTING「不要把真实会话数据写进代码」）。
const String _wireGuard = '''
[Interface]
PrivateKey = AQIDBAUGBwgJAAECAwQFBgcICQABAgMEBQYHCAk=
Address = 10.7.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = ISIjJCUmJygpSy0uLzAxMjM0NTY3ODk6Ozw9Pj8=
Endpoint = vpn.example.net:51820
AllowedIPs = 0.0.0.0/0, ::/0
''';

const String _ca = '''-----BEGIN CERTIFICATE-----
MIIBkTCB+wIJAJ1l0YQFakeFakeCertForUnitTestOnly0000000000000000000000
-----END CERTIFICATE-----''';

/// `client` + `remote` + 内联证书，足以按内容识别为 OpenVPN。
const String _openVpn = '''
client
dev tun
proto udp
remote ovpn.example.net 1194
<ca>
$_ca
</ca>
''';

const String _hysteria2 = 'hysteria2://pw@hy2.example.net:443/?sni=hy2.example.net';

void main() {
  group('声明的扩展名：一个扩展名只属于一个协议', () {
    test('可导入协议的扩展名恰好是约定的那些', () {
      expect(VpnProtocol.wireGuard.fileExtensions, <String>['conf']);
      // OpenVPN 让出 `.conf`（2.x 默认导出的正是它），只保留 `.ovpn`。
      expect(VpnProtocol.openVpn.fileExtensions, <String>['ovpn']);
      expect(VpnProtocol.shadowsocks.fileExtensions, <String>['json', 'txt']);
      expect(VpnProtocol.vmess.fileExtensions, isEmpty);
      expect(VpnProtocol.vless.fileExtensions, isEmpty);
      expect(VpnProtocol.trojan.fileExtensions, isEmpty);
      expect(VpnProtocol.hysteria2.fileExtensions, <String>['yaml', 'yml']);
    });

    test('没有任何扩展名被两个协议同时声明', () {
      final seen = <String, VpnProtocol>{};
      for (final protocol in importableProtocols) {
        for (final ext in protocol.fileExtensions) {
          expect(
            seen.containsKey(ext),
            isFalse,
            reason:
                '.$ext 同时属于 ${seen[ext]?.label} 与 ${protocol.label}；'
                '扩展名必须唯一，否则文件关联会指向错误的协议',
          );
          seen[ext] = protocol;
        }
      }
    });

    test('可导入扩展名的并集恰为约定集合（去重后）', () {
      expect(
        allSupportedExtensions.toSet(),
        <String>{'conf', 'ovpn', 'json', 'txt', 'yaml', 'yml'},
      );
      // 文件选择器直接消费这个列表，重复项会让过滤项出现两遍。
      expect(allSupportedExtensions.length, allSupportedExtensions.toSet().length);
    });
  });

  group('解析仍以内容为准，扩展名只是约定', () {
    test('命名为 .conf 的 OpenVPN 配置解析为 OpenVPN', () {
      // 本约定的核心护栏：`.conf` 不再是 OpenVPN 的约定扩展名，
      // 但内容识别必须照旧接受它，否则约定就变成了功能回退。
      expect(
        VpnProtocolFactory.parse(_openVpn, 'client.conf').protocol,
        VpnProtocol.openVpn,
      );
    });

    test('命名为 .ovpn 的 WireGuard 配置解析为 WireGuard', () {
      expect(
        VpnProtocolFactory.parse(_wireGuard, 'tunnel.ovpn').protocol,
        VpnProtocol.wireGuard,
      );
    });

    test('命名为 .txt 的 Shadowsocks 分享链接解析为 Shadowsocks', () {
      expect(
        VpnProtocolFactory.parse(
          'ss://aes-256-gcm:pw@ss.example.net:8388',
          'node.txt',
        ).protocol,
        VpnProtocol.shadowsocks,
      );
    });

    test('命名为 .txt 的 Hysteria2 分享链接解析为 Hysteria2', () {
      expect(
        VpnProtocolFactory.parse(_hysteria2, 'node.txt').protocol,
        VpnProtocol.hysteria2,
      );
    });

    test('命名为 .txt 的 VLESS 分享链接解析为 VLESS', () {
      expect(
        VpnProtocolFactory.parse(
          'vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@vless.example.net:443'
          '?type=tcp&security=tls&sni=vless.example.net',
          'node.txt',
        ).protocol,
        VpnProtocol.vless,
      );
    });

    test('扩展名完全不在约定集合里也能导入（改名不影响解析）', () {
      expect(
        VpnProtocolFactory.parse(_openVpn, 'client.backup').protocol,
        VpnProtocol.openVpn,
      );
    });
  });
}
