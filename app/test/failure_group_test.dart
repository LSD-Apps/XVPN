import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_log.dart';

ConnectionFailure _failure({
  required String target,
  String outbound = 'direct',
  String reason = 'dial tcp: i/o timeout',
  int minute = 0,
}) {
  return ConnectionFailure(
    time: DateTime(2026, 2, 14, 12, minute),
    target: target,
    outbound: outbound,
    reason: reason,
  );
}

void main() {
  group('失败分组', () {
    test('同一目标同一路径归为一组，并记下次数', () {
      final groups = groupFailures(<ConnectionFailure>[
        _failure(target: 'a.example.com:443'),
        _failure(target: 'a.example.com:8443'),
        _failure(target: 'b.example.com:443'),
      ]);

      expect(groups, hasLength(2));
      expect(groups.first.host, 'a.example.com');
      expect(groups.first.count, 2, reason: '同一站点不同端口是同一个问题');
      expect(groups.last.host, 'b.example.com');
    });

    test('同一目标走了不同的路要分成两组', () {
      // 这是分组的关键：判为直连而失败和走隧道而失败处置方式相反
      // （前者可能该改规则，后者只能换节点）。混成一组就把最有用的区别抹掉了。
      final groups = groupFailures(<ConnectionFailure>[
        _failure(target: 'a.example.com:443'),
        _failure(target: 'a.example.com:443', outbound: 'vpn'),
      ]);

      expect(groups, hasLength(2));
      expect(groups.map((FailureGroup g) => g.proxied).toSet(), <bool>{
        false,
        true,
      });
      expect(groups.first.directionLabel, '直连');
      expect(groups.last.directionLabel, '走隧道');
    });

    test('最近的失败排在最前，组内也是', () {
      // 用户打开这个列表想知道的是「现在什么坏了」，而不是「历史上什么坏得最多」。
      final groups = groupFailures(<ConnectionFailure>[
        _failure(target: 'new.example.com:443', minute: 9),
        _failure(target: 'old.example.com:443', minute: 5),
        _failure(target: 'new.example.com:80', minute: 8),
      ]);

      expect(groups.first.host, 'new.example.com');
      expect(groups.first.latest.time.minute, 9, reason: '取最近一次的原因');
      expect(
        groups.first.failures.map((ConnectionFailure f) => f.time.minute),
        <int>[9, 8],
      );
    });

    test('只有判为直连的域名失败才算「疑似规则未覆盖」', () {
      final directDomain = groupFailures(<ConnectionFailure>[
        _failure(target: 'blocked.example.com:443'),
      ]).single;
      expect(directDomain.suggestsMissingRule, isTrue);

      final proxied = groupFailures(<ConnectionFailure>[
        _failure(target: 'blocked.example.com:443', outbound: 'vpn'),
      ]).single;
      expect(
        proxied.suggestsMissingRule,
        isFalse,
        reason: '走隧道也失败说明是节点问题，改规则没用',
      );

      final ip = groupFailures(<ConnectionFailure>[
        _failure(target: '8.8.8.8:53'),
      ]).single;
      expect(
        ip.suggestsMissingRule,
        isFalse,
        reason: 'IP 目标本来就管不到，对 IP 谈规则没意义',
      );
      expect(ip.isIpTarget, isTrue);

      final dns = groupFailures(<ConnectionFailure>[
        _failure(
          target: 'x.example.com:443',
          reason: 'lookup x.example.com: no such host',
        ),
      ]).single;
      expect(dns.suggestsMissingRule, isFalse, reason: '解析失败是 DNS 层的事，与分流规则无关');
    });

    test('组内只要有一条构成证据就算可疑', () {
      final group = groupFailures(<ConnectionFailure>[
        _failure(
          target: 'a.example.com:443',
          reason: 'lookup a.example.com: no such host',
        ),
        _failure(target: 'a.example.com:443', reason: 'dial tcp: i/o timeout'),
      ]).single;

      expect(group.count, 2);
      expect(group.suggestsMissingRule, isTrue);
    });

    test('空列表得到空结果', () {
      expect(groupFailures(const <ConnectionFailure>[]), isEmpty);
    });
  });

  group('失败报告', () {
    test('空记录也说清楚，而不是给一段空白', () {
      expect(failureReport(const <ConnectionFailure>[]), contains('暂无失败记录'));
    });

    test('报告里有总数、方向拆分、可疑域名与每组的原始原因', () {
      final report = failureReport(<ConnectionFailure>[
        _failure(target: 'blocked.example.com:443', minute: 9),
        _failure(target: 'blocked.example.com:443', minute: 8),
        _failure(
          target: '8.8.8.8:53',
          outbound: 'vpn',
          reason: 'connection refused',
        ),
      ]);

      expect(report, contains('共计 3 条'));
      expect(report, contains('直连 2'));
      expect(report, contains('隧道 1'));
      expect(
        report,
        contains('疑似规则未覆盖：blocked.example.com'),
        reason: '接手排查的人最先要看的就是这一行',
      );
      expect(report, contains('blocked.example.com · 2 次 · 直连'));
      expect(report, contains('8.8.8.8 · 1 次 · 走隧道'));
      // 原始原因要留着：归类会丢掉细节，而细节往往才是问题所在。
      expect(report, contains('最后原因：dial tcp: i/o timeout'));
    });

    test('没有可疑域名时不出现那一行', () {
      final report = failureReport(<ConnectionFailure>[
        _failure(target: '8.8.8.8:53', outbound: 'vpn'),
      ]);
      expect(report, isNot(contains('疑似规则未覆盖')));
    });

    test('末尾不留空行', () {
      final report = failureReport(<ConnectionFailure>[
        _failure(target: 'a.com:443'),
      ]);
      expect(report, isNot(endsWith('\n')));
    });
  });
}
