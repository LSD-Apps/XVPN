import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/tunnel_health.dart';

void main() {
  group('隧道健康判定', () {
    test('失败次数未到阈值时算健康', () {
      final health = evaluateTunnelHealth(consecutiveFailures: 2, threshold: 3);
      expect(health.verdict, TunnelHealthVerdict.healthy);
      expect(health.isProblem, isFalse);
      expect(health.shouldRecover, isFalse);
    });

    test('隧道不通但直连正常：值得重启内核', () {
      final health = evaluateTunnelHealth(
        consecutiveFailures: 3,
        threshold: 3,
        directLatencyMillis: 27,
      );
      expect(health.verdict, TunnelHealthVerdict.tunnelDown);
      expect(health.shouldRecover, isTrue, reason: '直连能通说明本地网络没问题，问题在隧道');
      expect(health.summary, contains('27ms'));
    });

    test('直连也不通：判定为本地网络问题，不做无谓重连', () {
      final health = evaluateTunnelHealth(
        consecutiveFailures: 5,
        threshold: 3,
        directLatencyMillis: null,
      );
      expect(health.verdict, TunnelHealthVerdict.networkDown);
      expect(health.shouldRecover, isFalse, reason: '本地网络断了，重启内核只会反复失败');
      expect(health.summary, contains('本地网络'));
    });

    test('零次失败也走健康分支，不会除零或误判', () {
      final health = evaluateTunnelHealth(consecutiveFailures: 0, threshold: 3);
      expect(health.verdict, TunnelHealthVerdict.healthy);
    });
  });

  group('健康重启限流', () {
    final t0 = DateTime(2026, 2, 14, 12);

    test('首次可以重启，冷却期内不行', () {
      final guard = HealthRecoveryGuard();
      expect(guard.shouldRestart(t0), isTrue);
      guard.noteRestart(t0);

      expect(
        guard.shouldRestart(t0.add(const Duration(seconds: 30))),
        isFalse,
        reason: '冷却期内的第二次重启会把界面刷成反复重连',
      );
      expect(guard.shouldRestart(t0.add(const Duration(minutes: 3))), isTrue);
    });

    test('次数用尽后不再重启，并对外可知', () {
      final guard = HealthRecoveryGuard(maxRestarts: 2);
      guard.noteRestart(t0);
      guard.noteRestart(t0.add(const Duration(minutes: 3)));

      expect(guard.shouldRestart(t0.add(const Duration(minutes: 6))), isFalse);
      expect(guard.exhausted, isTrue, reason: '额度用尽要能告诉用户，否则他只会看到一直连不上');
    });

    test('隧道恢复只归还次数、不解除冷却', () {
      final guard = HealthRecoveryGuard();
      guard.noteRestart(t0);
      guard.noteHealthy();

      expect(guard.restarts, 0, reason: '事故结束，额度重新可用');
      expect(
        guard.shouldRestart(t0.add(const Duration(seconds: 5))),
        isFalse,
        reason: '隧道「断了又通、通了又断」时冷却必须仍然生效，否则退化成无限重连',
      );
    });

    test('手动重连把限流完全清零', () {
      final guard = HealthRecoveryGuard();
      guard.noteRestart(t0);
      guard.reset();
      expect(guard.restarts, 0);
      expect(guard.lastRestartAt, isNull);
      expect(guard.shouldRestart(t0), isTrue);
    });
  });
}
