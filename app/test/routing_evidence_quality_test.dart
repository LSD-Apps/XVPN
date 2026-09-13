import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/dns_client.dart';

import 'support/recording_listener.dart';

/// 直连证据的**质量**维度。
///
/// 这一组用例锁的是三个真实缺陷，它们有共同的前提错误：原实现假定「判为直连的
/// 主机要么通、要么不通」。而 2026-09 在深圳对 github.com 的实测表明存在第三种
/// 状态——**握手成功但没有数据**（TLS 几百毫秒就完成，随后连接活着 8–10 秒却
/// 只交付 0 字节）。围绕这个第三态，原生实现有三个漏洞：
///
///   1. 「跑出过任何字节就算成功」，于是零星几百字节被记成成功；
///   2. `recordDirectSuccess` 会清零连续失败计数、并撤销学到的规则，于是那点
///      零星字节足以把刚学到的判断推翻 → 规则反复横跳；
///   3. 晋升条件里有一道 `directSuccesses == 0` 的永久闸门：只要历史上成功过
///      一次，就再也学不会走隧道。
///
/// 实测数据（见 `docs/RULES.md` 与 canvas 分析）：
///   * 成功交付 577,137 字节（一次慢的 448,401 字节 / 12.0s）
///   * 挂死交付 0 字节（存活 8–10 秒）
///   * 同一时段 github.com 10 次里成功 4 次，失败成簇
void main() {
  group('判据：一条已关闭直连连接的质量', () {
    // 判据现在住在 route_learning.dart 的策略对象上，因此这一组不需要构造
    // 路由表、也不需要伪造网络——这正是把它抽成独立模块的收益之一。
    const policy = LearningPolicy();

    test('字节够多 → 确实交付', () {
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: policy.substantiveByteFloor,
          alive: const Duration(milliseconds: 800),
        ),
        DirectOutcome.delivered,
      );
    });

    test('存活久但没字节 → 挂死（这是原先完全看不见的那一类）', () {
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: 0,
          alive: const Duration(seconds: 10),
        ),
        DirectOutcome.stalled,
      );
    });

    test('存活久但字节在门槛之下 → 挂死，而不是成功', () {
      // 这是缺陷①的核心：零星字节（例如只读了响应头就卡住）不算交付。
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: 270,
          alive: const Duration(seconds: 9),
        ),
        DirectOutcome.stalled,
      );
    });

    test('存活久但字节够多 → 交付，不是挂死', () {
      // 实测里有一次 total=12.0s 却交付 448 KB 的「慢但成功」。
      // 只看时长会把它误判成挂死，因此必须联合字节数判断。
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: 448401,
          alive: const Duration(seconds: 12),
        ),
        DirectOutcome.delivered,
      );
    });

    test('存活短且字节少 → 不下结论', () {
      // 可能是一个正常的小响应（实测 raw 的 270 字节就是完整文件），
      // 也可能是一次快速失败——后者由内核日志的 ERROR 行归因，不在这里重复计。
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: 270,
          alive: const Duration(milliseconds: 400),
        ),
        DirectOutcome.pending,
      );
    });

    test('拿不到存活时长时不下「挂死」结论', () {
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: 0,
          alive: null,
        ),
        DirectOutcome.pending,
        reason: '宁可少一次纠正，也不要凭缺失的信息下结论',
      );
    });

    test('走隧道的连接不参与这套判定', () {
      expect(
        policy.classifyDirectConnection(
          direct: false,
          bytes: 0,
          alive: const Duration(seconds: 30),
        ),
        DirectOutcome.notApplicable,
      );
    });
  });

  group('学习表：挂死计入失败，且不再有永久闸门', () {
    test('连续挂死达到阈值 → 改为走隧道', () {
      final table = AutoRouteTable();
      AutoRouteDecision? last;
      for (var i = 0; i < 3; i++) {
        last = table.recordDirectStall('stalled.example', reason: '握手成功但无数据');
      }
      final entry = table.match('stalled.example')!;
      expect(entry.preference, RoutePreference.forceProxy);
      expect(entry.stalls, 3);
      expect(
        entry.directFailures,
        0,
        reason: '挂死与连接失败分开计数，界面上才分得清「连不上」与「连上了没数据」',
      );
      expect(last!.added, isTrue);
      expect(last.reason, contains('没有数据'));
    });

    test('历史上成功过也能被学成走隧道（旧闸门已移除）', () {
      // 原实现的门槛是 `consecutiveFailures >= 3 && directSuccesses == 0`，
      // 于是「偶尔能连上、大部分时候连不上」的域名永远学不会走隧道——
      // 而这正是实测中 github.com 的形态。
      //
      // 构造方式：先用反方向学习造一条 forceDirect 规则（它会建表项），
      // 再让它成功一次，然后连续失败三次。
      final table = AutoRouteTable();
      table.recordDomesticAnswer('flaky.example');
      table.recordDomesticAnswer('flaky.example');
      expect(
        table.match('flaky.example')!.preference,
        RoutePreference.forceDirect,
      );

      table.recordDirectSuccess('flaky.example');
      expect(table.match('flaky.example')!.directSuccesses, 1);

      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('flaky.example', reason: '连接超时');
      }
      expect(
        table.match('flaky.example')!.preference,
        RoutePreference.forceProxy,
        reason: '连续失败已经隐含了「最近没有成功过」，那道闸门既多余又有害',
      );
    });

    test('未定性时不建规则，只攒证据（否则一次失败就生效）', () {
      // 这条锁的是一个真实缺陷：`AutoRouteEntry` 的默认 preference 是
      // forceProxy，一旦装进表里，`buildRouteRules()` 立刻会生成一条强制代理
      // 规则——于是写在 promotionThreshold 上的「连续 3 次」实际变成了 1 次。
      final table = AutoRouteTable();
      table.recordDirectFailure('early.example', reason: '连接超时');

      expect(
        table.match('early.example'),
        isNull,
        reason: '一次失败不该产生任何路由规则',
      );
      expect(
        table.buildRouteRules().otherRules,
        isEmpty,
        reason: '配置文件里也不该出现针对它的规则',
      );
      expect(
        table.pendingSetback('early.example')?.consecutive,
        1,
        reason: '但证据要记下来，否则阈值永远攒不满',
      );

      table.recordDirectFailure('early.example', reason: '连接超时');
      table.recordDirectFailure('early.example', reason: '连接超时');
      expect(table.match('early.example')!.preference, RoutePreference.forceProxy);
      expect(
        table.pendingSetback('early.example'),
        isNull,
        reason: '提升成规则后应从待定区移除，否则同一份证据会被计两次',
      );
    });

    test('待定区的证据会被一次确实交付清掉', () {
      final table = AutoRouteTable();
      table.recordDirectFailure('cleared.example', reason: '连接超时');
      expect(table.pendingSetback('cleared.example')?.consecutive, 1);

      expect(
        table.recordDirectSuccess('cleared.example'),
        isTrue,
        reason: '返回 true 才说明反证确实被记账，上层才会去重',
      );
      expect(
        table.pendingSetback('cleared.example'),
        isNull,
        reason: '直连既然交付了内容，之前那点失败证据就不成立了',
      );
    });

    test('一次侥幸成功不足以推翻刚学到的规则（横跳已消除）', () {
      final table = AutoRouteTable();
      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('churn.example', reason: '连接超时');
      }
      expect(table.match('churn.example')!.preference, RoutePreference.forceProxy);

      // 两次零星「成功」——旧实现累计到 2 次就会撤销规则。
      table.recordDirectSuccess('churn.example');
      table.recordDirectSuccess('churn.example');
      expect(
        table.match('churn.example')?.preference,
        RoutePreference.forceProxy,
        reason: '撤销要连续三次确实交付，否则按实测的簇状抖动会反复横跳',
      );
    });

    test('连续三次确实交付才撤销学到的规则', () {
      final table = AutoRouteTable();
      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('recovered.example', reason: '连接超时');
      }
      expect(table.match('recovered.example')?.preference, RoutePreference.forceProxy);

      for (var i = 0; i < 3; i++) {
        table.recordDirectSuccess('recovered.example');
      }
      expect(
        table.match('recovered.example'),
        isNull,
        reason: '网络恢复后连续成功攒够阈值，规则应被撤销',
      );
    });

    test('成败交替时两个方向都不触发（迟滞由「连续」提供）', () {
      final table = AutoRouteTable();
      // 复现实测的分布：成功 / 失败×2 / 成功 / 成功 / 失败×2 …
      for (var round = 0; round < 3; round++) {
        table.recordDirectSuccess('alternating.example');
        table.recordDirectFailure('alternating.example', reason: '连接超时');
        table.recordDirectFailure('alternating.example', reason: '连接超时');
      }
      final entry = table.match('alternating.example');
      expect(
        entry?.preference,
        isNot(RoutePreference.forceProxy),
        reason: '交替出现时连续失败凑不满 3 次，因此不该改判——否则规则会来回翻',
      );
    });

    test('一次失败会清零连续成功计数', () {
      final table = AutoRouteTable();
      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('reset.example', reason: '连接超时');
      }
      table.recordDirectSuccess('reset.example');
      table.recordDirectSuccess('reset.example');
      expect(table.match('reset.example')!.consecutiveSuccesses, 2);

      table.recordDirectStall('reset.example', reason: '握手成功但无数据');
      expect(
        table.match('reset.example')!.consecutiveSuccesses,
        0,
        reason: '「没有交付」也是失败，必须打断连续成功，否则攒阈值就没有意义',
      );
    });

    test('挂死与成功率都会落盘', () {
      final table = AutoRouteTable();
      for (var i = 0; i < 3; i++) {
        table.recordDirectStall('persist.example', reason: '握手成功但无数据');
      }
      table.recordDirectSuccess('persist.example');

      final restored = AutoRouteTable()
        ..loadFrom(jsonDecode(jsonEncode(table.toJson())));
      final entry = restored.match('persist.example')!;
      expect(entry.stalls, 3);
      expect(entry.directSuccesses, 1);
      expect(entry.consecutiveSuccesses, 1);
    });

    test('旧存档缺这两个键时按 0 起算，不会凭空白撤销', () {
      final legacy = AutoRouteEntry.fromJson(<String, Object?>{
        'domain': 'legacy.example',
        'preference': 'proxy',
        'source': 'learned',
        'directFailures': 3,
        'directSuccesses': 2,
        'consecutiveFailures': 3,
        'consecutiveSuccesses': null,
      });
      expect(legacy, isNotNull);
      expect(legacy!.stalls, 0);
      expect(
        legacy.consecutiveSuccesses,
        0,
        reason: '宁可让撤销多等几次，也不要凭一个不存在的历史立刻撤销正在起作用的规则',
      );
    });
  });

  group('观测层：挂死连接被记下并推进学习', () {
    /// 一份含一条**已存活 10 秒、只交付 0 字节**的直连连接快照。
    ///
    /// 这正是实测的失败形态：`tls` 早就完成，`total` 却停在 0。
    String stalledSnapshot({required String host, required int secondsAlive}) {
      final started = DateTime.now()
          .toUtc()
          .subtract(Duration(seconds: secondsAlive))
          .toIso8601String();
      return jsonEncode(<String, Object?>{
        'downloadTotal': 0,
        'uploadTotal': 0,
        'memory': 1024,
        'connections': <Object?>[
          <String, Object?>{
            'id': 'stall-1',
            'metadata': <String, Object?>{
              'network': 'tcp',
              'host': host,
              'destinationIP': '20.205.243.166',
              'destinationPort': '443',
            },
            'upload': 0,
            'download': 0,
            'start': started,
            'chains': <String>['direct'],
            'rule': 'final',
            'rulePayload': '',
          },
        ],
      });
    }

    String emptySnapshot() => jsonEncode(<String, Object?>{
      'downloadTotal': 0,
      'uploadTotal': 0,
      'memory': 1024,
      'connections': <Object?>[],
    });

    CoreMonitor monitorFor(
      RecordingListener listener,
      AutoRouteTable table,
      _QueueHttpClient client,
    ) => CoreMonitor(
      CoreMonitorHooks(
        listener: listener,
        clashApiPort: 2081,
        autoRoute: table,
        probesEnabled: true,
        dnsResolver: _StubResolver(),
        tunnelLatencyProbe: () async => 120,
        directLatencyProbe: () async => 25,
        httpClient: client,
      ),
    );

    test('连接关闭后按「握手成功但无数据」记账，攒够阈值才改成走隧道', () async {
      final table = AutoRouteTable();
      final listener = RecordingListener();
      final client = _QueueHttpClient(<String>[
        stalledSnapshot(host: 'stalled.example', secondsAlive: 10),
        emptySnapshot(), // 已关闭
      ]);
      final monitor = monitorFor(listener, table, client);
      addTearDown(monitor.dispose);

      // 第一轮：连接还在，只建立轨迹，不下结论。
      await monitor.tick();
      expect(
        table.match('stalled.example'),
        isNull,
        reason: '连接还活着时不该下结论——它的字节数可能还在涨',
      );
      expect(table.pendingSetback('stalled.example'), isNull);

      // 第二轮：连接消失 → 判定为挂死，记入待定区（阈值 3，还不改路由）。
      await monitor.tick();
      expect(
        table.pendingSetback('stalled.example')?.stalls,
        1,
        reason: '这类失败原先完全不可见：没有 ERROR 行，也不算成功',
      );
      expect(
        table.match('stalled.example'),
        isNull,
        reason: '一次挂死不该立刻改判',
      );

      // 补足阈值后提升成规则。
      table.recordDirectStall('stalled.example', reason: '握手成功但无数据');
      final decision = table.recordDirectStall(
        'stalled.example',
        reason: '握手成功但无数据',
      );
      expect(decision.added, isTrue);
      expect(decision.reason, contains('没有数据'));
    });

    test('同一域名的挂死在一小段时间内只记一次', () async {
      final table = AutoRouteTable();
      final listener = RecordingListener();
      // 两轮「出现 → 关闭」，间隔远小于限流窗口（15 秒）。
      final client = _QueueHttpClient(<String>[
        stalledSnapshot(host: 'repeat.example', secondsAlive: 10),
        emptySnapshot(),
        stalledSnapshot(host: 'repeat.example', secondsAlive: 10),
        emptySnapshot(),
      ]);
      final monitor = monitorFor(listener, table, client);
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();
      await monitor.tick();
      await monitor.tick();

      expect(
        table.pendingSetback('repeat.example')?.stalls,
        1,
        reason: '一次故障里的多条连接要折成一次观测，否则阈值会被突发刷满',
      );
    });

    test('短命且字节少的连接不下结论（不误记为挂死）', () async {
      final table = AutoRouteTable();
      final listener = RecordingListener();
      final quick = jsonEncode(<String, Object?>{
        'downloadTotal': 270,
        'uploadTotal': 0,
        'memory': 1024,
        'connections': <Object?>[
          <String, Object?>{
            'id': 'quick-1',
            'metadata': <String, Object?>{
              'network': 'tcp',
              'host': 'quick.example',
              'destinationPort': '443',
            },
            'upload': 0,
            'download': 270,
            'start': DateTime.now().toUtc().toIso8601String(),
            'chains': <String>['direct'],
            'rule': 'final',
          },
        ],
      });
      final client = _QueueHttpClient(<String>[quick, emptySnapshot()]);
      final monitor = monitorFor(listener, table, client);
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();
      expect(
        table.match('quick.example'),
        isNull,
        reason: '一个 270 字节的正常小响应不该被当成挂死',
      );
    });

    test('字节够多时记为确实交付，并清零连续失败', () async {
      final table = AutoRouteTable();
      final listener = RecordingListener();
      // 先造 3 次失败把域名推成走隧道，再用一次大交付验证它被记为反证。
      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('big.example', reason: '连接超时');
      }
      final big = jsonEncode(<String, Object?>{
        'downloadTotal': 200000,
        'uploadTotal': 0,
        'memory': 1024,
        'connections': <Object?>[
          <String, Object?>{
            'id': 'big-1',
            'metadata': <String, Object?>{
              'network': 'tcp',
              'host': 'big.example',
              'destinationPort': '443',
            },
            'upload': 0,
            'download': 200000,
            'start': DateTime.now().toUtc().toIso8601String(),
            'chains': <String>['direct'],
            'rule': 'final',
          },
        ],
      });
      final client = _QueueHttpClient(<String>[big, emptySnapshot()]);
      final monitor = monitorFor(listener, table, client);
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.tick();

      final entry = table.match('big.example')!;
      expect(entry.directSuccesses, 1);
      expect(entry.consecutiveSuccesses, 1);
      expect(entry.consecutiveFailures, 0);
    });
  });
  group('交付速率：提升、回滚与冷却', () {
    /// 造一次速率观测。1 MB / 1 秒 = 1 MB/s（健康）；200 KB / 20 秒 = 10 KB/s（偏慢）。
    /// 两者都远超 64 KB 的字节下限，因此都会计入统计。
    void feed(
      AutoRouteTable table,
      String host, {
      required bool direct,
      required int bytes,
      required int seconds,
      DateTime? now,
    }) {
      table.recordDeliveryRate(
        host,
        direct: direct,
        bytes: bytes,
        duration: Duration(seconds: seconds),
        now: now,
      );
    }

    void feedHealthyLink(AutoRouteTable table, {int count = 8}) {
      for (var i = 0; i < count; i++) {
        feed(table, 'healthy-$i.example', direct: true, bytes: 1024 * 1024, seconds: 1);
      }
    }

    test('只有速率证据时不建规则（阈值不能被绕过）', () {
      final table = AutoRouteTable();
      feed(table, 'slow.example', direct: true, bytes: 200 * 1024, seconds: 20);

      expect(
        table.match('slow.example'),
        isNull,
        reason: '一次偏慢不该产生规则——否则「连续 3 次」形同虚设',
      );
      expect(table.toJson(), isEmpty, reason: '配置文件里也不该出现它');
    });

    test('基准未建立时不下结论', () {
      final table = AutoRouteTable();
      // 只喂 2 个基准样本（阈值是 5），再给目标 5 次偏慢。
      for (var i = 0; i < 2; i++) {
        feed(table, 'h-$i.example', direct: true, bytes: 1024 * 1024, seconds: 1);
      }
      for (var i = 0; i < 5; i++) {
        feed(table, 'slow.example', direct: true, bytes: 200 * 1024, seconds: 20);
      }
      expect(
        table.match('slow.example'),
        isNull,
        reason: '拿几个样本当基准，会把「今天没跑过大传输」误判成「所有站点都慢」',
      );
    });

    test('直连连续偏慢达到阈值 → 试走隧道，且标记为速率证据', () {
      final table = AutoRouteTable();
      feedHealthyLink(table);
      for (var i = 0; i < 3; i++) {
        feed(table, 'slow.example', direct: true, bytes: 200 * 1024, seconds: 20);
      }

      final entry = table.match('slow.example');
      expect(entry, isNotNull);
      expect(entry!.preference, RoutePreference.forceProxy);
      expect(
        entry.byRate,
        isTrue,
        reason: '必须与「因为直连失败而学到」区分开：两者的回滚条件不同',
      );
      expect(entry.rateNote, contains('KB/s'));
    });

    test('偏慢与健康交替时不提升（迟滞由「连续」提供）', () {
      final table = AutoRouteTable();
      feedHealthyLink(table);
      for (var round = 0; round < 3; round++) {
        feed(table, 'mixed.example', direct: true, bytes: 200 * 1024, seconds: 20);
        feed(table, 'mixed.example', direct: true, bytes: 1024 * 1024, seconds: 1);
      }
      expect(
        table.match('mixed.example'),
        isNull,
        reason: '中途插进一个正常样本就清零，因此攒不满阈值',
      );
    });

    test('隧道上同样偏慢 → 放回直连并进入冷却', () {
      final table = AutoRouteTable();
      feedHealthyLink(table);
      for (var i = 0; i < 3; i++) {
        feed(table, 'both-slow.example', direct: true, bytes: 200 * 1024, seconds: 20);
      }
      expect(table.match('both-slow.example')!.preference, RoutePreference.forceProxy);

      // 隧道上三次同样偏慢 → 说明问题不在路径上。
      AutoRouteDecision? revert;
      for (var i = 0; i < 3; i++) {
        revert = table.recordDeliveryRate(
          'both-slow.example',
          direct: false,
          bytes: 200 * 1024,
          duration: const Duration(seconds: 20),
        );
      }
      expect(
        table.match('both-slow.example'),
        isNull,
        reason: '两条路都慢说明不是路径问题，应放回直连（省下隧道带宽）',
      );
      expect(revert!.reason, contains('问题不在路径上'));
    });

    test('冷却期内不会立刻又试一次（防止来回横跳）', () {
      final table = AutoRouteTable();
      final t0 = DateTime(2026, 9, 13, 12);
      for (var i = 0; i < 8; i++) {
        feed(table, 'h-$i.example', direct: true, bytes: 1024 * 1024, seconds: 1, now: t0);
      }
      for (var i = 0; i < 3; i++) {
        feed(table, 'churn.example', direct: true, bytes: 200 * 1024, seconds: 20, now: t0);
      }
      expect(table.match('churn.example')!.byRate, isTrue);

      for (var i = 0; i < 3; i++) {
        feed(table, 'churn.example', direct: false, bytes: 200 * 1024, seconds: 20, now: t0);
      }
      expect(table.match('churn.example'), isNull, reason: '已回滚');

      // 冷却期内：即使直连仍偏慢，也不该马上再上隧道。
      feed(table, 'churn.example', direct: true, bytes: 200 * 1024, seconds: 20, now: t0);
      expect(
        table.match('churn.example'),
        isNull,
        reason: '没有冷却就会「直连慢→上隧道→隧道也慢→回直连→又上隧道」',
      );

      // 冷却期满后允许重试。
      final later = t0.add(const Duration(minutes: 31));
      feed(table, 'churn.example', direct: true, bytes: 200 * 1024, seconds: 20, now: later);
      expect(table.match('churn.example')!.byRate, isTrue);
    });

    test('因为直连失败而学到的规则绝不被「隧道偏慢」放回直连', () {
      // 这是 byRate 这个标记存在的唯一理由。若不做区分，一个在直连上
      // **连不上**的域名会因为隧道也慢而被放回直连——那是明确的功能回退。
      final table = AutoRouteTable();
      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('unreachable.example', reason: '连接超时');
      }
      final entry = table.match('unreachable.example')!;
      expect(entry.preference, RoutePreference.forceProxy);
      expect(entry.byRate, isFalse);

      feedHealthyLink(table);
      for (var i = 0; i < 5; i++) {
        feed(table, 'unreachable.example', direct: false, bytes: 200 * 1024, seconds: 20);
      }
      expect(
        table.match('unreachable.example')?.preference,
        RoutePreference.forceProxy,
        reason: '它在直连上连不上，绝不能因为隧道慢就放回去',
      );
    });

    test('用户指定的走向不被速率证据改写', () {
      final table = AutoRouteTable()
        ..setUserRule('mine.example', RoutePreference.forceDirect);
      feedHealthyLink(table);
      for (var i = 0; i < 5; i++) {
        feed(table, 'mine.example', direct: true, bytes: 200 * 1024, seconds: 20);
      }
      final entry = table.match('mine.example')!;
      expect(entry.preference, RoutePreference.forceDirect);
      expect(entry.source, RouteRuleSource.user);
    });

    test('「恢复内置规则」会清掉速率证据与基准', () {
      final table = AutoRouteTable();
      feedHealthyLink(table);
      for (var i = 0; i < 3; i++) {
        feed(table, 'slow.example', direct: true, bytes: 200 * 1024, seconds: 20);
      }
      expect(table.match('slow.example'), isNotNull);
      expect(table.linkRateReference, isNotNull);

      table.removeLearned();
      expect(table.match('slow.example'), isNull);
      expect(
        table.linkRateReference,
        isNull,
        reason: '基准也是运行中观察到的，应当一并丢弃',
      );
    });
  });
}

/// 按顺序返回一批响应体，用来模拟「连接先出现、后关闭」这种跨轮次变化。
class _QueueHttpClient implements HttpClient {
  _QueueHttpClient(this._bodies);

  final List<String> _bodies;
  int _index = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final body = _index < _bodies.length ? _bodies[_index] : _bodies.last;
    _index++;
    return _QueueRequest(body);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueueRequest implements HttpClientRequest {
  _QueueRequest(this.body);

  final String body;

  @override
  Future<HttpClientResponse> close() async => _QueueResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueueResponse extends Stream<List<int>> implements HttpClientResponse {
  _QueueResponse(String body) : _bytes = utf8.encode(body);

  final List<int> _bytes;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 什么都不解析的桩：这些用例只走「连接质量」这条路，不涉及 DNS。
class _StubResolver implements DnsResolver {
  @override
  Future<DnsOutcome> query(
    String server,
    String name, {
    Duration? timeout,
  }) async => DnsOutcome(
    server: server,
    name: name,
    answers: const <String>[],
    elapsed: const Duration(milliseconds: 5),
  );

  @override
  void close() {}
}
