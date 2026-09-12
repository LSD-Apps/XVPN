import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/dns_monitor.dart';
import 'package:xvpn/core/domain_check.dart';
import 'package:xvpn/models.dart';

SplitRecord _record(
  String target, {
  RouteKind kind = RouteKind.proxy,
  String rule = 'final',
}) {
  return SplitRecord(
    time: DateTime(2026, 2, 14, 12, 0),
    target: target,
    kind: kind,
    rule: rule,
    outbound: kind == RouteKind.proxy ? 'vpn' : 'direct',
  );
}

void main() {
  group('查证：汇总已有的证据', () {
    test('什么都没观察到时如实说明，并提示下一步', () {
      final check = buildDomainCheck(
        domain: 'never.example.com',
        records: const <SplitRecord>[],
      );

      expect(check.observed, isFalse);
      expect(check.conclusion, contains('任何记录'));
      expect(
        check.conclusion,
        contains('never.example.com'),
        reason: '结论里要点名是哪个域名',
      );
      expect(check.conclusion, contains('访问一次'), reason: '光说没有记录没用，要告诉用户怎么办');
    });

    test('只统计这个域名的记录，并按主机名匹配（记录里带端口）', () {
      final check = buildDomainCheck(
        domain: 'www.example.com',
        records: <SplitRecord>[
          _record('www.example.com:443'),
          _record('www.example.com:80', kind: RouteKind.direct),
          _record('other.example.com:443'),
          _record('8.8.8.8:53'),
        ],
      );

      expect(check.records, hasLength(2));
      expect(check.records.first.target, 'www.example.com:443');
    });

    test('最近一次实际走了哪条路，说得出来', () {
      final check = buildDomainCheck(
        domain: 'a.example.com',
        records: <SplitRecord>[
          _record('a.example.com:443', kind: RouteKind.direct),
        ],
      );

      expect(check.lastRoute, RouteKind.direct);
      expect(check.conclusion, contains('直连'));
      expect(check.conclusion, contains('没有专门规则'), reason: '顺带说清是规则判的还是规则库判的');
    });

    test('有规则时把「谁定的」说清楚', () {
      final table = AutoRouteTable();
      table.setUserRule('a.example.com', RoutePreference.forceProxy);
      final rule = table.match('a.example.com');

      final check = buildDomainCheck(
        domain: 'a.example.com',
        records: <SplitRecord>[_record('a.example.com:443')],
        rule: rule,
      );

      expect(check.conclusion, contains('强制代理'));
      expect(
        check.facts.any((f) => f.value.contains('手工指定')),
        isTrue,
        reason: '手工指定的规则不会被程序改，与程序学到的必须区分开',
      );
    });

    test('后缀规则也算覆盖：子域名会被匹配上', () {
      final table = AutoRouteTable();
      table.setUserRule('example.com', RoutePreference.forceProxy);

      expect(
        table.match('deep.sub.example.com'),
        isNotNull,
        reason: '后缀规则命中子域名，因此查证子域名时也应当显示「有规则」',
      );
    });

    test('域名会被归一化：大小写与前后空白不影响匹配', () {
      final check = buildDomainCheck(
        domain: '  WWW.Example.COM  ',
        records: <SplitRecord>[_record('www.example.com:443')],
      );

      expect(check.domain, 'www.example.com');
      expect(check.observed, isTrue);
    });

    test('无法归一化的输入（IP、空串）也给出结论，不抛异常', () {
      for (final input in <String>['8.8.8.8', '', '   ']) {
        final check = buildDomainCheck(
          domain: input,
          records: const <SplitRecord>[],
        );
        expect(check.conclusion, isNotEmpty, reason: '输入 "$input" 不该让界面拿到一句空话');
      }
    });

    test('输入 IP 时仍然能匹配到它的记录', () {
      // 归一化会把 IP 变成空串（IP 不参与按域名的分流），如果用空串去比对记录，
      // 明明有记录也会答「没有观察到」——那是在说假话。分流记录页的搜索框本来
      // 就同时接受域名与 IP，查证没有理由不认。
      final check = buildDomainCheck(
        domain: '8.8.8.8',
        records: <SplitRecord>[
          _record('8.8.8.8:53', kind: RouteKind.direct),
          _record('www.example.com:443'),
        ],
      );

      expect(check.records, hasLength(1));
      expect(check.conclusion, contains('直连'), reason: 'IP 目标的记录同样要认出来');
    });
  });

  group('查证：DNS 对照的呈现', () {
    test('尚未探测时如实标注，而不是假装一致', () {
      final check = buildDomainCheck(
        domain: 'a.example.com',
        records: const <SplitRecord>[],
      );

      expect(
        check.facts.firstWhere((f) => f.label == 'DNS 对照').value,
        '尚未探测',
        reason: '没探测就写「一致」是在编结论',
      );
    });

    test('疑似污染时结论直接点破，并说明该怎么办', () {
      final check = buildDomainCheck(
        domain: 'blocked.example.com',
        records: const <SplitRecord>[],
        dns: const DnsCrossCheck(
          domain: 'blocked.example.com',
          domesticAnswers: <String>['127.0.0.1'],
          domesticMillis: 12,
          tunnelAnswers: <String>['93.184.216.34'],
          tunnelMillis: 180,
          verdict: DnsVerdict.suspectPoisoning,
        ),
      );

      expect(check.conclusion, contains('可疑'));
      expect(check.conclusion, contains('污染'));
      expect(check.conclusion, contains('隧道'), reason: '要说清这类域名必须走隧道解析');
    });

    test('两路答案都列出来，用户能自己看', () {
      final check = buildDomainCheck(
        domain: 'a.example.com',
        records: const <SplitRecord>[],
        dns: const DnsCrossCheck(
          domain: 'a.example.com',
          domesticAnswers: <String>['1.2.3.4', '5.6.7.8'],
          domesticMillis: 12,
          tunnelAnswers: <String>['9.9.9.9'],
          tunnelMillis: 180,
          verdict: DnsVerdict.dualStack,
        ),
      );

      expect(
        check.facts.firstWhere((f) => f.label == '国内解析').value,
        '1.2.3.4、5.6.7.8',
      );
      expect(check.facts.firstWhere((f) => f.label == '隧道解析').value, '9.9.9.9');
    });

    test('解析器没给答案时写「无结果」，不留空白', () {
      final check = buildDomainCheck(
        domain: 'a.example.com',
        records: const <SplitRecord>[],
        dns: const DnsCrossCheck(
          domain: 'a.example.com',
          domesticAnswers: <String>[],
          domesticMillis: null,
          tunnelAnswers: <String>[],
          tunnelMillis: null,
          verdict: DnsVerdict.directResolverDown,
        ),
      );

      expect(check.facts.firstWhere((f) => f.label == '国内解析').value, '无结果');
    });
  });

  group('查证：不预测分流结果', () {
    test('没有记录时不编造「会走哪条路」', () {
      // geosite-cn 是二进制规则集，Dart 侧读不了（没有 zlib），因此
      // 「这个域名会不会命中规则库」在客户端根本答不出来。与其编一个看起来
      // 像预测的结论，不如只说已经发生的事实。
      final check = buildDomainCheck(
        domain: 'unknown.example.com',
        records: const <SplitRecord>[],
      );

      expect(check.lastRoute, isNull);
      expect(check.conclusion, isNot(contains('会走')));
      expect(check.conclusion, isNot(contains('将走')));
    });
  });
}
