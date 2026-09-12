import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/startup_self_check.dart';

/// 用可控的探针结果构造自检器。
StartupSelfCheck _check({
  required int? direct,
  required int? tunnel,
  List<String> domesticAnswers = const <String>['220.181.38.148'],
  List<String> coreAnswers = const <String>['142.250.72.14'],
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
        domesticAnswers: <String>['220.181.38.148'],
        coreAnswers: <String>['142.250.72.14'],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(dns.passed, isTrue);
      expect(dns.detail, contains('220.181.38.148'));
      expect(dns.detail, contains('142.250.72.14'));
    });

    test('两组答案不同不算异常——域名本来就有国内外双部署', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: <String>['114.230.1.1'],
        coreAnswers: <String>['104.18.0.1'],
      ).run();

      expect(report.probeNamed(StartupSelfCheck.dnsName)!.passed, isTrue);
      expect(report.conclusion, '两条路径都正常');
    });

    test('国内解析失败 → DNS 报异常', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: const <String>[],
        coreAnswers: <String>['1.2.3.4'],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(dns.failed, isTrue);
      expect(dns.detail, contains('国内直接解析失败'));
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

    test('内核没有返回独立答案时不误报——该域名可能被判为国内直连', () async {
      final report = await _check(
        direct: 12,
        tunnel: 180,
        domesticAnswers: <String>['220.181.38.148'],
        coreAnswers: const <String>[],
      ).run();

      final dns = report.probeNamed(StartupSelfCheck.dnsName)!;
      expect(
        dns.passed,
        isTrue,
        reason: 'baidu 命中 geosite-cn，内核按 DNS 规则用国内解析器解析是正确行为',
      );
      expect(dns.detail, contains('国内直连'));
    });
  });

  group('报告结构', () {
    test('三条探针都在，且顺序稳定', () async {
      final report = await _check(direct: 12, tunnel: 180).run();
      expect(report.probes.map((ProbeResult p) => p.name).toList(), <String>[
        StartupSelfCheck.directName,
        StartupSelfCheck.tunnelName,
        StartupSelfCheck.dnsName,
      ]);
      expect(report.checkedAt.year, greaterThan(2000));
    });

    test('未探测时的占位结果都是 pending', () {
      final pending = StartupSelfCheck.pendingProbes();
      expect(pending, hasLength(3));
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
