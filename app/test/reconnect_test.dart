import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/reconnect.dart';

void main() {
  group('重试节奏', () {
    const policy = ReconnectPolicy();

    test('按 2 的幂退避：1s、2s、4s、8s、16s', () {
      expect(policy.delayForAttempt(1), const Duration(seconds: 1));
      expect(policy.delayForAttempt(2), const Duration(seconds: 2));
      expect(policy.delayForAttempt(3), const Duration(seconds: 4));
      expect(policy.delayForAttempt(4), const Duration(seconds: 8));
      expect(policy.delayForAttempt(5), const Duration(seconds: 16));
    });

    test('等待时间封顶在 maxDelay，不会无限增长', () {
      expect(policy.delayForAttempt(6), const Duration(seconds: 30));
      expect(policy.delayForAttempt(50), const Duration(seconds: 30));
    });

    test('第 0 次或负数次没有等待时间', () {
      expect(policy.delayForAttempt(0), Duration.zero);
      expect(policy.delayForAttempt(-3), Duration.zero);
    });

    test('很大的次数不会因移位溢出成负数', () {
      // 这是真实风险：`1 << 40` 之后再乘毫秒数会溢出，得到负的 Duration。
      expect(policy.delayForAttempt(1000).isNegative, isFalse);
      expect(policy.delayForAttempt(1000), const Duration(seconds: 30));
    });
  });

  group('崩溃恢复状态机', () {
    test('用户主动断开时绝不重连', () {
      final recovery = CrashRecovery();
      final decision = recovery.onCoreExit(
        uptime: const Duration(seconds: 1),
        userInitiated: true,
      );
      expect(decision.shouldRetry, isFalse, reason: '点了断开又被自动连回来是最糟的体验');
      expect(recovery.attempts, 0);
    });

    test('稳定运行后崩溃：每次都算新事故，但累计次数封顶', () {
      final recovery = CrashRecovery(
        policy: const ReconnectPolicy(maxTotalAttempts: 4),
      );
      // 内核每次都跑了两分钟才崩——按「稳定运行过就是新事故」的规则，
      // 单次额度会一直重置。真正兜住无限重连的是累计上限。
      for (var i = 1; i <= 4; i++) {
        final decision = recovery.onCoreExit(
          uptime: const Duration(minutes: 2),
          userInitiated: false,
        );
        expect(decision.shouldRetry, isTrue, reason: '第 $i 次应当重试');
        expect(decision.attempt, 1, reason: '每次都是新事故，因此都是本轮的第一次');
      }

      final exhausted = recovery.onCoreExit(
        uptime: const Duration(minutes: 2),
        userInitiated: false,
      );
      expect(exhausted.shouldRetry, isFalse, reason: '没有累计上限时这里会永远重连下去');
      expect(exhausted.reason, contains('累计自动重连'));
      expect(recovery.totalAttempts, 4);
    });

    test('同一次事故内的连续重试按 maxAttempts 封顶', () {
      final recovery = CrashRecovery(
        // 让运行时长落在「不短也不长」的区间：既不算刚起来就死，也不算稳定运行，
        // 因此额度不会被重置。
        policy: const ReconnectPolicy(maxAttempts: 3, maxTotalAttempts: 100),
      );
      for (var i = 1; i <= 3; i++) {
        final decision = recovery.onCoreExit(
          uptime: const Duration(seconds: 15),
          userInitiated: false,
        );
        expect(decision.shouldRetry, isTrue, reason: '第 $i 次应当重试');
        expect(decision.attempt, i);
      }
      final exhausted = recovery.onCoreExit(
        uptime: const Duration(seconds: 15),
        userInitiated: false,
      );
      expect(exhausted.shouldRetry, isFalse);
      expect(exhausted.reason, contains('仍未稳定'));
    });

    test('刚起来就死：只给很少的次数，快速失败', () {
      final recovery = CrashRecovery();
      final first = recovery.onCoreExit(
        uptime: const Duration(seconds: 2),
        userInitiated: false,
      );
      expect(first.shouldRetry, isTrue);

      final second = recovery.onCoreExit(
        uptime: const Duration(seconds: 2),
        userInitiated: false,
      );
      expect(second.shouldRetry, isTrue);

      // 第三次不再重试：启动后立刻退出几乎必然是配置问题，重试没有意义。
      final third = recovery.onCoreExit(
        uptime: const Duration(seconds: 2),
        userInitiated: false,
      );
      expect(third.shouldRetry, isFalse);
      expect(third.reason, contains('立即退出'));
    });

    test('稳定运行一次后，重试额度重新计算', () {
      final recovery = CrashRecovery();
      // 先耗尽「刚起来就死」的额度。
      recovery.onCoreExit(
        uptime: const Duration(seconds: 1),
        userInitiated: false,
      );
      recovery.onCoreExit(
        uptime: const Duration(seconds: 1),
        userInitiated: false,
      );
      expect(
        recovery
            .onCoreExit(
              uptime: const Duration(seconds: 1),
              userInitiated: false,
            )
            .shouldRetry,
        isFalse,
      );

      // 之后内核稳定跑了两分钟才崩：这是一次全新的独立事故。
      final afterStable = recovery.onCoreExit(
        uptime: const Duration(minutes: 2),
        userInitiated: false,
      );
      expect(afterStable.shouldRetry, isTrue, reason: '长期稳定后的崩溃不该受上一次事故的额度拖累');
      expect(afterStable.attempt, 1, reason: '额度应当已经重新计算');
    });

    test('reset 清空事故计数，用于用户手动重连', () {
      final recovery = CrashRecovery();
      recovery.onCoreExit(
        uptime: const Duration(seconds: 1),
        userInitiated: false,
      );
      recovery.onCoreExit(
        uptime: const Duration(seconds: 1),
        userInitiated: false,
      );
      expect(recovery.attempts, 2);

      recovery.reset();
      expect(recovery.attempts, 0);
      expect(
        recovery
            .onCoreExit(
              uptime: const Duration(seconds: 1),
              userInitiated: false,
            )
            .shouldRetry,
        isTrue,
      );
    });

    test('可注入更紧的策略', () {
      final recovery = CrashRecovery(
        policy: const ReconnectPolicy(
          maxAttempts: 1,
          maxRapidAttempts: 1,
          maxTotalAttempts: 1,
        ),
      );
      expect(
        recovery
            .onCoreExit(
              uptime: const Duration(minutes: 5),
              userInitiated: false,
            )
            .shouldRetry,
        isTrue,
      );
      expect(
        recovery
            .onCoreExit(
              uptime: const Duration(minutes: 5),
              userInitiated: false,
            )
            .shouldRetry,
        isFalse,
      );
    });
  });
}
