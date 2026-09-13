import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/route_learning.dart';

/// 学习策略与决策的**纯逻辑**测试。
///
/// 这个文件的存在本身就是这次拆分要换来的东西：判据与「累计到多少才改判」
/// 现在可以**不构造路由表、不伪造网络**地逐条验证。此前它们长在 1000 行的
/// `AutoRouteTable` 里，而策略常量还横跨两个文件——想验证一条阈值语义，
/// 得先把整张表搭起来。
///
/// 因此这里刻意不 import `auto_route.dart`：如果哪天有人把策略又挪回表里，
/// 这个文件会第一个失败。
void main() {
  group('LearningPolicy：默认值有依据', () {
    const policy = LearningPolicy();

    test('阈值与文档一致', () {
      expect(policy.promotionThreshold, 3);
      expect(policy.revokeSuccessThreshold, 3);
      expect(policy.domesticPromotionThreshold, 2);
    });

    test('判据阈值来自实测（成功 577 KB / 挂死 0 字节，相差三个数量级）', () {
      // 8 KB 远低于任何真实页面、又远高于「零星漏出几个字节」。
      expect(policy.substantiveByteFloor, 8 * 1024);
      expect(policy.stallFloor, const Duration(seconds: 6));
    });

    test('解析结果不一致是确定性证据，阈值降为 1', () {
      expect(policy.setbackThreshold(poisoned: true), 1);
      expect(policy.setbackThreshold(poisoned: false), 3);
    });

    test('非法构造被断言挡下', () {
      expect(
        () => LearningPolicy(promotionThreshold: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => LearningPolicy(capacity: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('策略可整体替换（这是「独立迭代」的前提）', () {
      const strict = LearningPolicy(promotionThreshold: 1, stallFloor: Duration(seconds: 2));
      expect(strict.setbackThreshold(poisoned: false), 1);
      expect(
        strict.classifyDirectConnection(
          direct: true,
          bytes: 0,
          alive: const Duration(seconds: 3),
        ),
        DirectOutcome.stalled,
      );
      // 宽松策略对同一条观测不下结论。
      expect(
        policy.classifyDirectConnection(
          direct: true,
          bytes: 0,
          alive: const Duration(seconds: 3),
        ),
        DirectOutcome.pending,
      );
    });
  });

  group('judgeSetback：累计到多少才改判', () {
    const policy = LearningPolicy();

    test('不到阈值只观察，且理由里带上进度', () {
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 1,
        currentPreference: null,
        stalled: false,
        poisoned: false,
      );
      expect(v.promote, isFalse);
      expect(v.record, EvidenceKind.connectionFailure);
      expect(v.reason, contains('1/3'));
    });

    test('达到阈值即改判，理由说明依据', () {
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 3,
        currentPreference: null,
        stalled: false,
        poisoned: false,
      );
      expect(v.promote, isTrue);
      expect(v.reason, contains('连续 3 次判为直连但失败'));
    });

    test('挂死与连接失败分开表述（界面上才分得清）', () {
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 3,
        currentPreference: null,
        stalled: true,
        poisoned: false,
      );
      expect(v.record, EvidenceKind.stall);
      expect(v.promote, isTrue);
      expect(v.reason, contains('握手成功但没有数据'));
    });

    test('解析不一致时一次即改判，理由不同', () {
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 1,
        currentPreference: null,
        stalled: false,
        poisoned: true,
      );
      expect(v.promote, isTrue);
      expect(v.reason, contains('解析结果不一致'));
    });

    test('已经是强制代理时不再重复改判', () {
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 9,
        currentPreference: RoutePreference.forceProxy,
        stalled: false,
        poisoned: false,
      );
      expect(v.promote, isFalse);
    });

    test('不看累计成功次数——历史上成功过也要能改判', () {
      // 这条锁的是一个真实缺陷：原条件是
      // `consecutiveFailures >= 阈值 && directSuccesses == 0`，只要历史上
      // 成功过一次就再也学不会走隧道。函数签名里**根本没有**成功次数这个入参，
      // 因此那种写法无法再被悄悄加回来。
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 3,
        currentPreference: RoutePreference.forceDirect,
        stalled: false,
        poisoned: false,
      );
      expect(v.promote, isTrue);
    });

    test('一条直连规则被连续证伪也会被改判', () {
      final v = judgeSetback(
        policy: policy,
        consecutiveFailures: 2,
        currentPreference: RoutePreference.forceDirect,
        stalled: true,
        poisoned: false,
      );
      expect(
        v.promote,
        isFalse,
        reason: '阈值 3，两次还不到',
      );
      expect(
        judgeSetback(
          policy: policy,
          consecutiveFailures: 3,
          currentPreference: RoutePreference.forceDirect,
          stalled: false,
          poisoned: false,
        ).promote,
        isTrue,
      );
    });
  });

  group('shouldRevokeLearnedProxy：撤销要看连续', () {
    const policy = LearningPolicy();

    test('连续三次确实交付才撤销', () {
      bool at(int n) => shouldRevokeLearnedProxy(
        policy: policy,
        consecutiveSuccesses: n,
        source: RouteRuleSource.learned,
        preference: RoutePreference.forceProxy,
      );
      expect(at(1), isFalse);
      expect(at(2), isFalse);
      expect(at(3), isTrue);
    });

    test('用户指定的规则永不撤销', () {
      expect(
        shouldRevokeLearnedProxy(
          policy: policy,
          consecutiveSuccesses: 99,
          source: RouteRuleSource.user,
          preference: RoutePreference.forceProxy,
        ),
        isFalse,
        reason: '那是人的明确决定',
      );
    });

    test('已经是直连的规则没什么可撤销', () {
      expect(
        shouldRevokeLearnedProxy(
          policy: policy,
          consecutiveSuccesses: 99,
          source: RouteRuleSource.learned,
          preference: RoutePreference.forceDirect,
        ),
        isFalse,
      );
    });
  });

  group('OutcomeThrottle：同样的观测在时间窗内只记一次', () {
    final t0 = DateTime(2026, 9, 13, 12);

    test('首次记下，窗口内重复被挡，窗口外放行', () {
      final throttle = OutcomeThrottle(policy: const LearningPolicy());
      expect(throttle.tryRecord(EvidenceKind.stall, 'a.example', t0), isTrue);
      expect(
        throttle.tryRecord(
          EvidenceKind.stall,
          'a.example',
          t0.add(const Duration(seconds: 5)),
        ),
        isFalse,
        reason: '一次故障里的多条连接要折成一次观测',
      );
      expect(
        throttle.tryRecord(
          EvidenceKind.stall,
          'a.example',
          t0.add(const Duration(seconds: 20)),
        ),
        isTrue,
        reason: '持续存在的问题要能稳定累积，否则阈值永远攒不满',
      );
    });

    test('不同域名、不同证据互不影响', () {
      final throttle = OutcomeThrottle(policy: const LearningPolicy());
      expect(throttle.tryRecord(EvidenceKind.stall, 'a.example', t0), isTrue);
      expect(
        throttle.tryRecord(EvidenceKind.stall, 'b.example', t0),
        isTrue,
        reason: '限流按域名，不是全局',
      );
      expect(
        throttle.tryRecord(EvidenceKind.delivery, 'a.example', t0),
        isTrue,
        reason: '同一域名既挂死过、也正常交付过，那是「不稳定」本身，不该互相限流',
      );
    });

    test('tryRecord 同时打时间戳，调用方无须再记一次', () {
      final throttle = OutcomeThrottle(policy: const LearningPolicy());
      expect(throttle.recentlyRecorded(EvidenceKind.delivery, 'x.example', t0), isFalse);
      throttle.tryRecord(EvidenceKind.delivery, 'x.example', t0);
      expect(
        throttle.recentlyRecorded(EvidenceKind.delivery, 'x.example', t0),
        isTrue,
        reason: '检查与记录分开写会引入「之间被插入别的观测」的窗口',
      );
    });

    test('窗口长度来自策略，改策略即改行为', () {
      final tight = OutcomeThrottle(
        policy: const LearningPolicy(outcomeWindow: Duration(seconds: 2)),
      );
      expect(tight.tryRecord(EvidenceKind.stall, 'a.example', t0), isTrue);
      expect(
        tight.tryRecord(
          EvidenceKind.stall,
          'a.example',
          t0.add(const Duration(seconds: 3)),
        ),
        isTrue,
        reason: '窗口只有 2 秒，3 秒后应放行',
      );
    });

    test('clear 清空全部类别', () {
      final throttle = OutcomeThrottle(policy: const LearningPolicy());
      throttle.tryRecord(EvidenceKind.stall, 'a.example', t0);
      throttle.tryRecord(EvidenceKind.delivery, 'b.example', t0);
      throttle.clear();
      expect(throttle.recentlyRecorded(EvidenceKind.stall, 'a.example', t0), isFalse);
      expect(throttle.recentlyRecorded(EvidenceKind.delivery, 'b.example', t0), isFalse);
    });
  });
}
