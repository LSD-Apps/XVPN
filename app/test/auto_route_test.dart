import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';

void main() {
  group('域名归一化', () {
    test('小写、去端口、去尾部点', () {
      expect(
        AutoRouteTable.normalizeDomain('WWW.Example.COM'),
        'www.example.com',
      );
      expect(AutoRouteTable.normalizeDomain('example.com:443'), 'example.com');
      expect(AutoRouteTable.normalizeDomain('example.com.'), 'example.com');
      expect(AutoRouteTable.normalizeDomain('  example.com  '), 'example.com');
    });

    test('IP 目标与单标签主机名不参与自动纠正', () {
      // IP 层面的失败与域名分流规则无关，把 IP 写进域名规则是错的。
      expect(AutoRouteTable.normalizeDomain('1.2.3.4'), '');
      expect(AutoRouteTable.normalizeDomain('1.2.3.4:443'), '');
      expect(AutoRouteTable.normalizeDomain('2400:cb00::1'), '');
      expect(AutoRouteTable.normalizeDomain('localhost'), '');
      expect(AutoRouteTable.normalizeDomain('router'), '');
      expect(AutoRouteTable.normalizeDomain(''), '');
    });

    test('识别 IP 字面量', () {
      expect(AutoRouteTable.isIpLiteral('8.8.8.8'), isTrue);
      expect(AutoRouteTable.isIpLiteral('2001:db8::1'), isTrue);
      expect(AutoRouteTable.isIpLiteral('8.8.8'), isFalse);
      expect(AutoRouteTable.isIpLiteral('www.example.com'), isFalse);
    });
  });

  group('匹配规则', () {
    test('精确命中优先于后缀命中', () {
      final table = AutoRouteTable();
      table.setUserRule('example.com', RoutePreference.forceProxy);
      table.setUserRule('direct.example.com', RoutePreference.forceDirect);

      expect(
        table.match('example.com')!.preference,
        RoutePreference.forceProxy,
      );
      expect(
        table.match('direct.example.com')!.preference,
        RoutePreference.forceDirect,
        reason: '更具体的域名必须赢',
      );
      expect(
        table.match('www.example.com')!.preference,
        RoutePreference.forceProxy,
      );
    });

    test('后缀匹配落在标签边界上，不误伤相似域名', () {
      final table = AutoRouteTable();
      table.setUserRule('example.com', RoutePreference.forceProxy);

      expect(table.match('a.example.com'), isNotNull);
      expect(table.match('a.b.example.com'), isNotNull);
      expect(
        table.match('notexample.com'),
        isNull,
        reason: 'notexample.com 不该被 example.com 命中',
      );
      expect(table.match('example.com.evil.net'), isNull);
    });

    test('没有规则时返回 null，交给内核按常规判定', () {
      final table = AutoRouteTable();
      expect(table.match('www.unknown.com'), isNull);
      expect(table.match(''), isNull);
      expect(table.match('1.2.3.4'), isNull);
    });

    test('多层后缀里取最具体的那条', () {
      final table = AutoRouteTable();
      table.setUserRule('example.com', RoutePreference.forceProxy);
      table.setUserRule('api.example.com', RoutePreference.forceDirect);
      // 走 sub.api.example.com：应该命中 api.example.com（更具体）
      expect(table.match('sub.api.example.com')!.domain, 'api.example.com');
    });
  });

  group('从失败证据里学习', () {
    test('连续失败达到阈值才纠正', () {
      final table = AutoRouteTable(promotionThreshold: 3);

      final first = table.recordDirectFailure(
        'blocked.example',
        reason: '连接超时',
      );
      expect(first.added, isFalse);
      expect(
        first.entry!.preference,
        RoutePreference.forceProxy,
        reason: '内部倾向已经记下，但还没对外生效',
      );
      expect(table.match('blocked.example'), isNotNull);

      table.recordDirectFailure('blocked.example');
      expect(table.length, 1);

      final third = table.recordDirectFailure('blocked.example');
      expect(third.added, isFalse, reason: '条目在第一次失败时就存在了');
      expect(third.reason, contains('连续 3 次'));
    });

    test('一次抖动不会改路由', () {
      final table = AutoRouteTable(promotionThreshold: 3);
      table.recordDirectFailure('flaky.example');
      final decision = table.recordDirectFailure('flaky.example');
      expect(decision.reason, contains('继续观察'));
      expect(decision.reason, contains('2/3'));
    });

    test('疑似投毒时一次失败即纠正', () {
      final table = AutoRouteTable(promotionThreshold: 3);
      final decision = table.recordDirectFailure(
        'poisoned.example',
        reason: '连接超时',
        dnsVerdict: 'suspectPoisoning',
      );
      expect(decision.reason, contains('投毒'));
      expect(decision.entry!.dnsVerdict, 'suspectPoisoning');
    });

    test('曾经直连成功过就不纠正——失败计数会被清零', () {
      final table = AutoRouteTable(promotionThreshold: 2);
      table.recordDirectFailure('cdn.example');
      table.recordDirectSuccess('cdn.example');
      // 清零之后又失败一次，仍然不到阈值。
      final decision = table.recordDirectFailure('cdn.example');
      expect(decision.reason, contains('继续观察'));
    });

    test('直连成功两次会撤销程序学到的强制代理', () {
      final table = AutoRouteTable(promotionThreshold: 1);
      table.recordDirectFailure('maybe.example');
      expect(
        table.match('maybe.example')!.preference,
        RoutePreference.forceProxy,
      );

      table.recordDirectSuccess('maybe.example');
      table.recordDirectSuccess('maybe.example');
      expect(
        table.match('maybe.example'),
        isNull,
        reason: '既然直连真的跑出了流量，说明当初的判断不成立',
      );
    });

    test('记录成功返回 true，表里没有该域名时返回 false', () {
      // 返回值决定了上层能否正确去重：只有确实记账了才该把域名标记为
      // 「已处理」。否则一个先失败、后成功的域名，它那次真正的成功会被
      // 当成重复而丢掉，「直连其实能通」这个关键反证就永远记不上。
      final table = AutoRouteTable();
      expect(
        table.recordDirectSuccess('never-seen.example'),
        isFalse,
        reason: '表里没有条目时不该谎报成功，否则上层会错误地去重',
      );

      table.recordDirectFailure('known.example');
      expect(table.recordDirectSuccess('known.example'), isTrue);
    });

    test('先失败后成功的顺序下，反证仍然生效', () {
      final table = AutoRouteTable(promotionThreshold: 3);
      table.recordDirectFailure('flappy.example');
      table.recordDirectFailure('flappy.example');
      // 第三次失败之前直连通了：失败计数应立即清零。
      expect(table.recordDirectSuccess('flappy.example'), isTrue);
      expect(table.match('flappy.example')!.consecutiveFailures, 0);

      // 之后即使再失败两次也不该达到阈值。
      table.recordDirectFailure('flappy.example');
      final decision = table.recordDirectFailure('flappy.example');
      expect(decision.reason, contains('继续观察'));
    });

    test('用户规则永远不被自动改写', () {
      final table = AutoRouteTable(promotionThreshold: 1);
      table.setUserRule('mine.example', RoutePreference.forceDirect);
      for (var i = 0; i < 10; i++) {
        table.recordDirectFailure('mine.example', reason: '连接超时');
      }
      final entry = table.match('mine.example')!;
      expect(entry.preference, RoutePreference.forceDirect);
      expect(entry.source, RouteRuleSource.user);
      expect(entry.directFailures, 10, reason: '失败仍要被记录，只是不改变分流');
    });

    test('IP 目标不产生规则', () {
      final table = AutoRouteTable(promotionThreshold: 1);
      final decision = table.recordDirectFailure('203.0.113.5:443');
      expect(decision.added, isFalse);
      expect(table.isEmpty, isTrue);
    });

    test('累计代理字节用于判断规则是否真在用', () {
      final table = AutoRouteTable(promotionThreshold: 1);
      table.recordDirectFailure('busy.example');
      table.recordProxiedBytes('busy.example', 4096);
      table.recordProxiedBytes('busy.example', 1024);
      expect(table.match('busy.example')!.proxiedBytes, 5120);
      // 负数或零不累加。
      table.recordProxiedBytes('busy.example', 0);
      expect(table.match('busy.example')!.proxiedBytes, 5120);
    });
  });

  group('容量与衰减', () {
    test('超出容量时淘汰证据最弱的条目', () {
      final table = AutoRouteTable(capacity: 3, promotionThreshold: 1);
      table.recordDirectFailure('weak.example'); // 1 次失败
      table.recordDirectFailure('strong.example');
      table.recordDirectFailure('strong.example');
      table.recordDirectFailure('strong.example');
      table.recordDirectFailure('medium.example');
      table.recordDirectFailure('medium.example');
      table.recordDirectFailure('newest.example');

      expect(table.length, lessThanOrEqualTo(3));
      expect(table.match('strong.example'), isNotNull, reason: '证据最强的要保留');
      expect(table.match('weak.example'), isNull, reason: '证据最弱的先淘汰');
    });

    test('过期的学习规则被淘汰，但跑过流量的保留', () {
      final table = AutoRouteTable(
        promotionThreshold: 1,
        decayAfter: const Duration(days: 7),
      );
      table.recordDirectFailure('stale.example');
      table.recordDirectFailure('useful.example');
      table.recordProxiedBytes('useful.example', 8192);

      // 两条规则的 lastHitAt 都是「现在」，用一个更晚的时间点触发淘汰。
      final removed = table.evictStale(
        now: DateTime.now().add(const Duration(days: 30)),
      );
      expect(removed, contains('stale.example'));
      expect(removed, isNot(contains('useful.example')));
      expect(table.match('useful.example'), isNotNull);
    });

    test('用户规则不受衰减影响', () {
      final table = AutoRouteTable(decayAfter: Duration.zero);
      table.setUserRule('mine.example', RoutePreference.forceProxy);
      final removed = table.evictStale(
        now: DateTime.now().add(const Duration(days: 1)),
      );
      expect(removed, isEmpty);
      expect(table.match('mine.example'), isNotNull);
    });

    test('remove 删除规则，clear 清空全部', () {
      final table = AutoRouteTable();
      table.setUserRule('a.example', RoutePreference.forceProxy);
      table.setUserRule('b.example', RoutePreference.forceProxy);

      expect(table.remove('a.example'), isTrue);
      expect(table.remove('a.example'), isFalse);
      expect(table.match('a.example'), isNull);
      // 后缀索引也要一起清干净，否则会从桶里又被匹配到。
      expect(table.match('sub.a.example'), isNull);

      table.clear();
      expect(table.isEmpty, isTrue);
      expect(table.match('b.example'), isNull);
    });
  });

  group('生成内核路由规则', () {
    test('把学到的域名下发成高优先级规则', () {
      final table = AutoRouteTable(promotionThreshold: 1);
      table.recordDirectFailure('blocked.example');
      table.recordDirectFailure('other.example');

      final rules = table.buildRouteRules();
      expect(rules, hasLength(1));
      expect(rules.first['outbound'], 'vpn');
      expect(rules.first['domain'], contains('blocked.example'));
      expect(rules.first['domain'], contains('other.example'));
      expect(
        rules.first['domain_suffix'],
        contains('blocked.example'),
        reason: 'sing-box 的 domain 是精确匹配，必须同时下发后缀才能覆盖子域',
      );
    });

    test('代理规则排在直连规则之前', () {
      final table = AutoRouteTable(promotionThreshold: 1);
      table.setUserRule('direct.example', RoutePreference.forceDirect);
      table.recordDirectFailure('proxy.example');

      final rules = table.buildRouteRules();
      expect(rules, hasLength(2));
      expect(rules[0]['outbound'], 'vpn');
      expect(rules[1]['outbound'], 'direct');
    });

    test('域名数量很多时拆成多条规则，避免单条过长', () {
      final table = AutoRouteTable(capacity: 2000, promotionThreshold: 1);
      for (var i = 0; i < 1200; i++) {
        table.recordDirectFailure('host-$i.example');
      }
      final rules = table.buildRouteRules();
      expect(rules.length, greaterThan(1));
      // 每条规则的域名数都不超过上限。
      final perRule = AutoRouteTable.domainsPerRule;
      for (final rule in rules) {
        final domains = (rule['domain'] as List?)?.length ?? 0;
        expect(domains, lessThanOrEqualTo(perRule));
      }
      // 所有域名都下发到了。
      final all = <String>{};
      for (final rule in rules) {
        for (final domain in (rule['domain'] as List?) ?? const <Object?>[]) {
          all.add(domain.toString());
        }
      }
      expect(all, hasLength(1200));
    });

    test('空表生成空规则，不产生空对象', () {
      expect(AutoRouteTable().buildRouteRules(), isEmpty);
    });
  });

  group('持久化', () {
    test('导出再导入后证据与来源都保留', () {
      final original = AutoRouteTable(promotionThreshold: 1);
      original.recordDirectFailure('learned.example', reason: '连接超时');
      original.setUserRule('mine.example', RoutePreference.forceDirect);
      original.recordProxiedBytes('learned.example', 4096);

      final restored = AutoRouteTable()..loadFrom(original.toJson());

      expect(restored.length, 2);
      final learned = restored.match('learned.example')!;
      expect(learned.source, RouteRuleSource.learned);
      expect(learned.preference, RoutePreference.forceProxy);
      expect(learned.proxiedBytes, 4096);
      expect(learned.lastFailureReason, '连接超时');

      final mine = restored.match('mine.example')!;
      expect(mine.source, RouteRuleSource.user);
      expect(mine.preference, RoutePreference.forceDirect);
    });

    test('损坏的条目被跳过，不让整张表失效', () {
      final table = AutoRouteTable()
        ..loadFrom(<Object?>[
          <String, Object?>{'domain': 'good.example'},
          'not a map',
          <String, Object?>{'domain': ''},
          <String, Object?>{'domain': 'ok.example', 'preference': 'direct'},
        ]);
      expect(table.length, 2);
      expect(table.match('good.example'), isNotNull);
      expect(
        table.match('ok.example')!.preference,
        RoutePreference.forceDirect,
      );
    });

    test('非列表输入不会抛异常', () {
      final table = AutoRouteTable();
      table.loadFrom(null);
      table.loadFrom('nonsense');
      table.loadFrom(<int>[1, 2, 3]);
      expect(table.isEmpty, isTrue);
    });

    test('恢复时也会重建后缀索引', () {
      final original = AutoRouteTable(promotionThreshold: 1);
      original.recordDirectFailure('example.com');
      final restored = AutoRouteTable()..loadFrom(original.toJson());
      expect(restored.match('www.example.com'), isNotNull);
    });
  });
}
