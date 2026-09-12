import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

/// 用**随包分发的真实内核**校验生成的配置。
///
/// 这是一条与其它测试都不同的防线：其余测试断言的是「配置长什么样」，
/// 而配置长什么样并不等于内核认不认。内核的 JSON 解码是严格的——多一个
/// 不认识的字段就直接 FATAL，表现为用户点了连接却「连不上」，而错误信息
/// 里没有任何他能理解的东西。
///
/// 因此每个新增字段都值得过一遍这里。之前 tun 入站的 mtu 就是这么加上去的。
///
/// 找不到内核二进制时整组跳过：CI 上可能只跑 Dart 侧而不带 80MB 的内核。
const _wireGuard = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
DNS = 8.8.8.8
MTU = 1380

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = vpn.example.net:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
''';

const _openVpn = '''
client
dev tun
proto udp
remote ovpn.example.net 1194
cipher AES-256-CBC
auth SHA256
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

/// Hysteria2 分享链接。带 SNI、salamander 混淆、端口跳跃与带宽声明，
/// 为的是让内核去校验尽可能多的字段名（多一个不认识的字段就直接 FATAL）。
const _hysteria2Link =
    'hysteria2://testpassword@hy2.example.net:443/?sni=hy2.example.net'
    '&obfs=salamander&obfs-password=testobfspass&mport=20000-30000'
    '&hop-interval=30&up=100&down=300#%E6%B5%8B%E8%AF%95%E8%8A%82%E7%82%B9';

void main() {
  final exe = File('assets/bin/sing-box.exe');
  final rulesets = Directory('assets/rulesets');

  /// 内核或规则集缺失时跳过，而不是失败。
  final skipReason = !exe.existsSync()
      ? '未找到 ${exe.path}，跳过内核校验'
      : (!rulesets.existsSync() ? '未找到规则集目录，跳过内核校验' : null);

  /// 生成配置 → 写盘 → 交给内核 check。
  Future<({int code, String output})> checkConfig(
    String text,
    SplitMode mode,
    InboundMode inbound,
  ) async {
    final parsed = VpnProtocolFactory.parse(text, 'test.conf');
    final config = SingBoxConfigBuilder.build(
      profile: parsed,
      splitMode: mode,
      // 用绝对路径：内核的工作目录与测试进程不同。
      ruleSetDir: rulesets.absolute.path,
      inboundMode: inbound,
      logSplits: true,
    );
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'xvpn-check-${mode.name}-${inbound.name}-${parsed.protocol.name}.json',
    );
    // 写完就跑，跑完就删：这些文件是给内核看的中间产物，留在临时目录里
    // 会在每次跑测试时往用户机器上多堆一份。
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    // 关键：必须写不带 BOM 的 UTF-8（Dart 的 writeAsString 默认如此）。
    // 带 BOM 时内核报「invalid character 'ï' looking for beginning of value」，
    // 而那份配置在别的编辑器里看起来完全正常。
    file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

    final result = await Process.run(exe.absolute.path, <String>[
      'check',
      '-c',
      file.path,
    ]);
    return (code: result.exitCode, output: '${result.stdout}${result.stderr}');
  }

  group('内核校验生成的配置', () {
    for (final mode in SplitMode.values) {
      for (final inbound in InboundMode.values) {
        test(
          'WireGuard · ${mode.name} · ${inbound.name} 能通过 sing-box check',
          () async {
            final result = await checkConfig(_wireGuard, mode, inbound);
            expect(
              result.code,
              0,
              reason: '内核拒绝了这份配置，用户会看到「连不上」：\n${result.output}',
            );
          },
        );
      }
    }

    test('OpenVPN · 智能分流 · tun 能通过 sing-box check', () async {
      final result = await checkConfig(
        _openVpn,
        SplitMode.smart,
        InboundMode.tun,
      );
      expect(result.code, 0, reason: '内核拒绝了这份配置：\n${result.output}');
    });

    test('OpenVPN · 智能分流 · mixed 能通过 sing-box check', () async {
      final result = await checkConfig(
        _openVpn,
        SplitMode.smart,
        InboundMode.mixed,
      );
      expect(result.code, 0, reason: '内核拒绝了这份配置：\n${result.output}');
    });

    // Hysteria2 是 outbounds 类协议（放进 endpoints 会被内核拒），
    // 且它的字段名与更新频繁（obfs / server_ports / hop_interval / up_mbps …），
    // 因此两种入站都过一遍真实内核。
    for (final inbound in InboundMode.values) {
      test('Hysteria2 · 智能分流 · ${inbound.name} 能通过 sing-box check', () async {
        final result = await checkConfig(
          _hysteria2Link,
          SplitMode.smart,
          inbound,
        );
        expect(
          result.code,
          0,
          reason: '内核拒绝了这份配置，用户会看到「连不上」：\n${result.output}',
        );
      });
    }
  }, skip: skipReason);
}
