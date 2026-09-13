import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/startup_self_check.dart';

/// 用可控的探针结果构造自检器。
StartupSelfCheck _check({
  required int? direct,
  required int? tunnel,
  List<String> domesticAnswers = const <String>['192.0.2.148'],
  List<String> coreAnswers = const <String>['198.51.100.14'],
}) {
  return StartupSelfCheck(
    directProbe: () async => direct,
    tunnelProbe: () async => tunnel,
    coreResolve: (String domain) async => coreAnswers,
    domesticResolve: (String domain) async => domesticAnswers,
  );
}

void main() {
  group('两条腿的区分', () {
    test('两条都通 → 配置正常', () async {
      final report = await _check(direct: 12, tunnel: 180).run();

      expect(report.conclusion, '两条路径都正常');
      expect(report.hasFailures, isFalse);
      expect(report.probeNamed(StartupSelfCheck.directName)!.millis, 12);
      expect(report.probeNamed(StartupSelfCheck.tunnelName)!.millis, 180);
    });

    test('直连不通、隧道通 → 问题在本地网络或 DNS，不在节点', () async {
      final report = await _check(direct: null, tunnel: 180).run();

      expect(report.conclusion, contains('直连这条腿不通'));
      expect(
        report.advice,
        contains('不在节点'),
        reason: '这是最容易被误判成「节点坏了」的情况，必须说清楚',
      );
    });

    test('直连通、隧道不通 → 问题在节点，改规则没用', () async {
      final report = await _check(direct: 12, tunnel: null).run();

      expect(report.conclusion, '隧道这条腿不通');
      expect(report.advice, contains('更换节点'));
      expect(
        report.advice,
        contains('调整分流规则不会有帮助'),
        reason: '用户最可能的错误动作就是去翻分流规则，要明确劝阻',
      );
    });

    test('两条都不通 → 本机网络可能完全不可用', () async {
      final report = await _check(direct: null, tunnel: null).run();

      expect(report.conclusion, '两条路径都不通');
      expect(report.advice, contains('确认这台设备本身能上网'));
    });
  });

  group('失败原因进入详情', () {
    test('失败时给出可操作的目标地址', () async {
      final report = await _check(direct: null, tunnel: null).run();
      final direct = report.probeNamed(StartupSelfCheck.directName)!;
      expect(direct.status, ProbeStatus.failed);
      expect(direct.detail, contains('www.baidu.com:443'));
      expect(direct.millis, isNull);
    });

    test('探针抛异常被吞掉，转成失败结论而不是让自检崩掉', () async {
      final check = StartupSelfCheck(
        directProbe: () async => throw StateError('socket 炸了'),
        tunnelProbe: () async => 100,
        coreResolve: (String d) async => <String>[],
        domesticResolve: (String d) async => <String>['1.2.3.4'],
      );
      final report = await check.run();

      final direct = report.probeNamed(StartupSelfCheck.directName)!;
      expect(direct.status, ProbeStatus.failed);
      expect(direct.detail, contains('socket 炸了'));
    });
  });

  group('DNS 探针', () {
    test('两条解析路径都拿到答案 → 正常', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: <String>['192.0.2.148'],
        coreAnswers: <String>['198.51.100.14'],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(dns.passed, isTrue);
      expect(dns.detail, contains('192.0.2.148'));
      expect(dns.detail, contains('198.51.100.14'));
    });

    test('两组答案不同不算异常——域名本来就有两套部署', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: <String>['192.0.2.1'],
        coreAnswers: <String>['198.51.100.1'],
      ).run();

      expect(report.probeNamed(StartupSelfCheck.dnsName)!.passed, isTrue);
      expect(report.conclusion, '两条路径都正常');
    });

    test('直连解析失败 → DNS 报异常', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: const <String>[],
        coreAnswers: <String>['1.2.3.4'],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(dns.failed, isTrue);
      expect(dns.detail, contains('直连解析失败'));
    });

    test('两条解析都失败 → 直指 DNS 是根源', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: const <String>[],
        coreAnswers: const <String>[],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(dns.failed, isTrue);
      expect(dns.detail, contains('DNS 可能是问题根源'));
      expect(report.conclusion, 'DNS 解析异常');
    });

    test('直连解析正常但经隧道解析失败 → 单独报「隧道不通 DNS」', () async {
      // 这是原先的探测盲区：那条 DNS 探针用 www.baidu.com，命中 geosite-cn
      // 因而走直连解析器，从未碰过隧道解析器。而所有非规则集域名（即全部境外
      // 站点）都走隧道解析器——它坏了表现为「连上了却什么都打不开」。
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: <String>['192.0.2.148'],
        coreAnswers: const <String>[],
      ).run();

      final tunnelDns = report.probeNamed(StartupSelfCheck.tunnelDnsName)!;
      expect(tunnelDns.failed, isTrue);
      expect(report.conclusion, '隧道不通 DNS');
      expect(
        report.advice,
        contains('UDP/53'),
        reason: '最常见的成因是节点不允许 UDP/53 出站，要直接说出来',
      );
      expect(
        report.advice,
        isNot(contains('更换节点')),
        reason: '先给可达的 DNS 才是对的处置顺序',
      );
    });

    test('隧道不通时隧道 DNS 的失败不抢归因', () async {
      // 隧道本身就不通时，隧道 DNS 必然也失败。此时主因是节点不通，
      // 结论应当是「隧道这条腿不通」，而不是被 DNS 那条分支抢走。
      final report = await _check(
        direct: 12,
        tunnel: null,
        coreAnswers: const <String>[],
      ).run();

      expect(report.conclusion, '隧道这条腿不通');
    });

    test('内核没有返回独立答案时不误报——该域名可能被判为直连', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: <String>['192.0.2.148'],
        coreAnswers: const <String>[],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(
        dns.passed,
        isTrue,
        reason: 'baidu 命中 geosite-cn，内核按 DNS 规则用直连解析器解析是正确行为',
      );
      expect(dns.detail, contains('判定为直连'));
    });
  });

  group('报告结构', () {
    test('四条探针都在，且顺序稳定', () async {
      final report = await _check(direct: 12, tunnel: 180).run();
      expect(report.probes.map((ProbeResult p) => p.name).toList(), <String>[
        StartupSelfCheck.directName,
        StartupSelfCheck.tunnelName,
        StartupSelfCheck.dnsName,
        StartupSelfCheck.tunnelDnsName,
      ]);
      expect(report.checkedAt.year, greaterThan(2000));
    });

    test('未探测时的占位结果都是 pending', () {
      final pending = StartupSelfCheck.pendingProbes();
      expect(pending, hasLength(4));
      for (final probe in pending) {
        expect(probe.status, ProbeStatus.pending);
        expect(probe.status.label, '待检测');
        expect(probe.passed, isFalse);
        expect(probe.failed, isFalse);
      }
    });

    test('report getter 保留上一次结果，供界面在重跑期间继续显示', () async {
      final check = _check(direct: 12, tunnel: 180);
      expect(check.report, isNull);
      final first = await check.run();
      expect(check.report, same(first));
    });

    test('状态标签覆盖全部取值', () {
      expect(ProbeStatus.passed.label, '正常');
      expect(ProbeStatus.failed.label, '异常');
      expect(ProbeStatus.pending.label, '待检测');
    });
  });
}
