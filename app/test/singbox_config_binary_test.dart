import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/app_presets.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/rulesets.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/host_platform.dart';

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
  final exe = hostCoreBinary;
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

    test('自定义规则集 · 智能分流 · mixed 能通过 sing-box check', () async {
      // 用户新增的规则集会作为额外的 local rule_set 写进配置，并参与路由。
      // 内核的 JSON 解码是严格的，新增一个 rule_set 条目属于新形状，因此要
      // 在真实内核上过一遍——「配置长什么样」不等于「内核认不认」。
      final dir = Directory.systemTemp.createTempSync('xvpn-rs-custom');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      for (final name in <String>['geosite-cn.srs', 'geoip-cn.srs']) {
        File(
          '${rulesets.absolute.path}${Platform.pathSeparator}$name',
        ).copySync('${dir.path}${Platform.pathSeparator}$name');
      }
      // 用一份真实规则集的内容冒充自定义规则集：内核只按魔数解析。
      File(
        '${rulesets.absolute.path}${Platform.pathSeparator}geosite-cn.srs',
      ).copySync('${dir.path}${Platform.pathSeparator}custom-cn.srs');

      final parsed = VpnProtocolFactory.parse(_wireGuard, 'test.conf');
      final config = SingBoxConfigBuilder.build(
        profile: parsed,
        splitMode: SplitMode.smart,
        ruleSetDir: dir.path,
        inboundMode: InboundMode.mixed,
        ruleSets: <RuleSetSpec>[
          ...SingBoxConfigBuilder.defaultRuleSets,
          const RuleSetSpec(tag: 'custom-cn', fileName: 'custom-cn.srs'),
        ],
      );
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'xvpn-check-custom.json',
      );
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      final result = await Process.run(exe.absolute.path, <String>[
        'check',
        '-c',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: '内核拒绝了带自定义规则集的配置：\n${result.stdout}${result.stderr}',
      );
    });

    test('应用直连预置 · 智能分流 · mixed 能通过 sing-box check', () async {
      // 预置走 AutoRouteTable 这**一个**决策来源，因此这里同时覆盖两种新形状：
      //   * 路由里一条带 `domain` + `domain_suffix`、没有 `rule_set` 的规则；
      //   * **DNS 规则**里按域名指定解析器的规则（F1：DNS 跟随路由决策）。
      // 内核的 JSON 解码是严格的，新形状必须在真实内核上过一遍——
      // 「配置长什么样」不等于「内核认不认」。
      final table = AutoRouteTable();
      for (final preset in AppPresets.all) {
        table.setPreset(preset, enabled: true);
      }
      final parsed = VpnProtocolFactory.parse(_wireGuard, 'test.conf');
      final config = SingBoxConfigBuilder.build(
        profile: parsed,
        splitMode: SplitMode.smart,
        ruleSetDir: rulesets.absolute.path,
        inboundMode: InboundMode.mixed,
        autoRoute: table,
      );
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'xvpn-check-presets.json',
      );
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      final result = await Process.run(exe.absolute.path, <String>[
        'check',
        '-c',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: '内核拒绝了带直连白名单的配置：\n${result.stdout}${result.stderr}',
      );
    });
    test('出厂默认配置能通过 sing-box check', () async {
      // 用**真正出货的那份规则集清单**过一遍内核。这是唯一同时覆盖以下三件事的
      // 地方，而它们各自都是「配置长什么样 ≠ 内核认不认」的类型：
      //   * 三条 rule_set 的定义与路由引用；
      //   * DNS 规则里引用**两个**域名类 rule_set（新形状）；
      //   * 用户 → 内网 → 学到 分三段后的路由顺序。
      final specs = <RuleSetSpec>[
        for (final BuiltinRuleSet b in RuleSetStore.builtins)
          RuleSetSpec(
            tag: b.name,
            fileName: b.fileName,
            domainRuleSet: b.isDomainRuleSet,
          ),
      ];
      final table = AutoRouteTable(promotionThreshold: 1)
        ..setUserRule('mine.example', RoutePreference.forceProxy)
        ..recordDirectFailure('learned.example');

      final config = SingBoxConfigBuilder.build(
        profile: VpnProtocolFactory.parse(_wireGuard, 'test.conf'),
        splitMode: SplitMode.smart,
        ruleSetDir: rulesets.absolute.path,
        inboundMode: InboundMode.mixed,
        autoRoute: table,
        ruleSets: specs,
      );
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'xvpn-check-defaults.json',
      );
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      final result = await Process.run(exe.absolute.path, <String>[
        'check',
        '-c',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: '内核拒绝了出厂默认配置：\n${result.stdout}${result.stderr}',
      );
    });

    test('DNS 规则引用三个域名类规则集也能通过 sing-box check', () async {
      // 用户按「推荐规则集」添加了 cn-large（域名类自定义规则集）之后，DNS 规则里
      // 会出现**三个**域名类标签。这是内核没验证过的新形状——一条 DNS 规则里放
      // 多个 rule_set 属于「配置长什么样 ≠ 内核认不认」那一类。
      final dir = Directory.systemTemp.createTempSync('xvpn-rs-three');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      for (final b in RuleSetStore.builtins) {
        File('${rulesets.absolute.path}${Platform.pathSeparator}${b.fileName}')
            .copySync('${dir.path}${Platform.pathSeparator}${b.fileName}');
      }
      // 用一份真实的域名类规则集内容冒充第三方规则集：内核只按内容解析。
      File('${dir.path}${Platform.pathSeparator}geosite-cn.srs')
          .copySync('${dir.path}${Platform.pathSeparator}cn-large.srs');

      final specs = <RuleSetSpec>[
        for (final b in RuleSetStore.builtins)
          RuleSetSpec(
            tag: b.name,
            fileName: b.fileName,
            domainRuleSet: b.isDomainRuleSet,
          ),
        const RuleSetSpec(
          tag: 'cn-large',
          fileName: 'cn-large.srs',
          domainRuleSet: true,
        ),
      ];
      final config = SingBoxConfigBuilder.build(
        profile: VpnProtocolFactory.parse(_wireGuard, 'test.conf'),
        splitMode: SplitMode.smart,
        ruleSetDir: dir.path,
        inboundMode: InboundMode.mixed,
        ruleSets: specs,
      );
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'xvpn-check-three.json',
      );
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      final result = await Process.run(exe.absolute.path, <String>[
        'check',
        '-c',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: '内核拒绝了带三个域名类规则集的配置：\n${result.stdout}${result.stderr}',
      );
    });

    test('用户关掉国内域名补充后仍能通过 sing-box check', () async {
      // DNS 规则引用的 rule_set 少了之后不能再留下对它的引用——那是内核
      // 直接拒绝启动的硬错误。这条覆盖「只启用原两份」这条回归路径。
      final config = SingBoxConfigBuilder.build(
        profile: VpnProtocolFactory.parse(_wireGuard, 'test.conf'),
        splitMode: SplitMode.smart,
        ruleSetDir: rulesets.absolute.path,
        inboundMode: InboundMode.mixed,
        ruleSets: SingBoxConfigBuilder.defaultRuleSets,
      );
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'xvpn-check-noextra.json',
      );
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      final result = await Process.run(exe.absolute.path, <String>[
        'check',
        '-c',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: '内核拒绝了停用补充规则集后的配置：\n${result.stdout}${result.stderr}',
      );
    });
  }, skip: skipReason);
}
