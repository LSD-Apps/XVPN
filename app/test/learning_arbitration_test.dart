import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';

/// 三个学习方向之间的**仲裁**。
///
/// 本轮引入了三种证据，而它们各有自己的累积计数：
///
///   1. 直连失效 / 挂死 → 走隧道（阈值 3）
///   2. 直连解析落在国内网段 → 走直连（阈值 2）
///   3. 交付速率偏慢 → 走隧道（阈值 3，带冷却）
///
/// 三个方向**独立累积**，因此必须明确「谁能否决谁」。否则一个同时满足多条的
/// 域名会让规则来回翻转——也就是用户最直接感受到的「分流时好时坏」。
///
/// 这个文件先**复现**那个缺陷，再锁定修好后的仲裁规则。留此记录是因为
/// 「三套独立计数放在一个状态机上」这类问题不会自己消失：每加一个方向就多一组
/// 可能的冲突，只有把规则写成断言才守得住。
void main() {
  const host = 'flip.example';

  /// 喂 n 次「直连解析落在国内网段」。
  void feedDomestic(AutoRouteTable table, {int times = 2}) {
    for (var i = 0; i < times; i++) {
      table.recordDomesticAnswer(host);
    }
  }

  /// 喂 n 次「判为直连但失败」。
  void feedFailure(AutoRouteTable table, {int times = 3}) {
    for (var i = 0; i < times; i++) {
      table.recordDirectFailure(host, reason: '连接超时');
    }
  }

  group('强证据能否决弱证据', () {
    test('观测到的失败不被「解析落在国内」翻回直连', () {
      // 「解析到国内地址」是**推断**（该地址可能并不可达）；
      // 「直连失败」是**观测**。观测应当压过推断。
      final table = AutoRouteTable();
      feedDomestic(table);
      expect(table.match(host)!.preference, RoutePreference.forceDirect);

      feedFailure(table);
      expect(table.match(host)!.preference, RoutePreference.forceProxy);

      // 关键一步：国内解析继续给出正面证据（它在隧道里也能被观察到）。
      feedDomestic(table, times: 5);
      expect(
        table.match(host)!.preference,
        RoutePreference.forceProxy,
        reason: '既然直连**实测不通**，再多的「解析落在国内」也不该把它放回直连——'
            '否则就是观测被推断反复推翻，规则来回翻转',
      );
    });

    test('速率学到的走隧道也不被「解析落在国内」翻回直连', () {
      final table = AutoRouteTable();
      feedDomestic(table);
      expect(table.match(host)!.preference, RoutePreference.forceDirect);

      // 直连很慢（1 MB/s 基准下 10 KB/s 为明显偏慢）。
      for (var i = 0; i < 8; i++) {
        table.recordDeliveryRate(
          'ref-$i.example',
          direct: true,
          bytes: 1024 * 1024,
          duration: const Duration(seconds: 1),
        );
      }
      for (var i = 0; i < 3; i++) {
        table.recordDeliveryRate(
          host,
          direct: true,
          bytes: 100 * 1024,
          duration: const Duration(seconds: 10),
        );
      }
      final entry = table.match(host)!;
      expect(entry.preference, RoutePreference.forceProxy);
      expect(entry.byRate, isTrue);

      feedDomestic(table, times: 5);
      expect(
        table.match(host)!.preference,
        RoutePreference.forceProxy,
        reason: '速率证据也是观测；它的回滚应当只走「隧道同样慢」那条路',
      );
    });

    test('两个方向交替喂证据时，稳定后不再翻转', () {
      // 复现原先的翻转：国内 → 失败 → 国内 → 失败 …
      //
      // 断言的是**每一步**的状态，而不只是每轮结束时的状态：上一版只看轮末，
      // 于是「中间翻了一轮又翻回来」这种情形被漏掉了——而用户感受到的正是中间那一下。
      final table = AutoRouteTable();
      final steps = <RoutePreference?>[];
      for (var round = 0; round < 6; round++) {
        feedDomestic(table);
        steps.add(table.match(host)?.preference);
        feedFailure(table);
        steps.add(table.match(host)?.preference);
      }
      // 第一次失败攒够阈值之后（第 3 步起）应当一直稳定在走隧道。
      for (var i = 2; i < steps.length; i++) {
        expect(
          steps[i],
          RoutePreference.forceProxy,
          reason: '第 ${i + 1} 步翻成了 ${steps[i]}——观测一旦确定，'
              '后续的正面推断不该再把它推翻',
        );
      }
    });

    test('任何一次翻转都需要各自的连续证据，不可能由单次证据触发', () {
      final table = AutoRouteTable();
      feedDomestic(table);
      expect(table.match(host)!.preference, RoutePreference.forceDirect);

      // 单次失败不足以翻（阈值 3）。
      table.recordDirectFailure(host, reason: '连接超时');
      expect(
        table.match(host)!.preference,
        RoutePreference.forceDirect,
        reason: '一次抖动就改路由，会让用户觉得「时好时坏」',
      );
      // 再补两次才翻。
      table.recordDirectFailure(host, reason: '连接超时');
      table.recordDirectFailure(host, reason: '连接超时');
      expect(table.match(host)!.preference, RoutePreference.forceProxy);
    });

    test('单次国内解析不足以建规则（阈值 2）', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('fresh.example');
      expect(
        table.match('fresh.example'),
        isNull,
        reason: '一次推断不该产生任何路由规则',
      );
      table.recordDomesticAnswer('fresh.example');
      expect(
        table.match('fresh.example')!.preference,
        RoutePreference.forceDirect,
      );
    });

    test('直连正常工作时，直连规则不会被「成功」撤掉（它本来就对）', () {
      // forceDirect 与 forceProxy 的撤销条件**不同**，这是有意的：
      //   * forceProxy 撤于「直连连续交付」或「隧道同样慢」——两条都需要观测；
      //   * forceDirect 无需撤销，因为它描述的正是直连能用。
      //     只有**观测到失效**（连续失败）或时间衰减才会让它消失。
      final table = AutoRouteTable();
      feedDomestic(table);
      for (var i = 0; i < 5; i++) {
        table.recordDirectSuccess(host);
      }
      expect(
        table.match(host)!.preference,
        RoutePreference.forceDirect,
        reason: '直连能用不是撤销它的理由；撤销它的理由只有「实测不通」或衰减',
      );
    });
  });

  group('反向仍要能工作（不能为了稳定把学习关掉）', () {
    test('直连真的恢复后，走隧道可以被撤销', () {
      final table = AutoRouteTable();
      feedFailure(table);
      expect(table.match(host)!.preference, RoutePreference.forceProxy);

      // 「确实交付」连续三次 → 撤销。
      for (var i = 0; i < 3; i++) {
        table.recordDirectSuccess(host);
      }
      expect(
        table.match(host),
        isNull,
        reason: '反证优先：直连既然真的交付了内容，当初的判断就不成立',
      );
    });

    test('撤销之后「解析落在国内」可以重新把它学成直连', () {
      final table = AutoRouteTable();
      feedFailure(table);
      for (var i = 0; i < 3; i++) {
        table.recordDirectSuccess(host);
      }
      expect(table.match(host), isNull);

      feedDomestic(table);
      expect(
        table.match(host)!.preference,
        RoutePreference.forceDirect,
        reason: '没有规则时，正向学习应当照常生效',
      );
    });

    test('没有观测性负面证据时，「解析落在国内」可以覆盖规则库的走隧道判定', () {
      // 这是反方向纠正的本职：白名单式直连下，不在规则库里的国内域名必然走隧道。
      final table = AutoRouteTable();
      feedDomestic(table);
      expect(table.match(host)!.preference, RoutePreference.forceDirect);
      expect(table.match(host)!.source, RouteRuleSource.learned);
    });
  });
}
