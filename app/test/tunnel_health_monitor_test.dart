import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/tunnel_health.dart';
import 'package:xvpn/core/vpn_core.dart';

import 'support/recording_listener.dart';

/// 构造一个探测结果可控的观测引擎。
///
/// 探测间隔压到 0，否则一个用例要真等 45 秒才能凑够三次失败——那等于没法测。
CoreMonitor _monitor({
  required VpnCoreListener listener,
  required Future<int?> Function() tunnel,
  required Future<int?> Function() direct,
  bool probesEnabled = true,
  void Function(TunnelHealth health)? onHealth,
}) {
  return CoreMonitor(
    CoreMonitorHooks(
      listener: listener,
      clashApiPort: 2081,
      probesEnabled: probesEnabled,
      latencyProbeInterval: Duration.zero,
      tunnelLatencyProbe: tunnel,
      directLatencyProbe: direct,
      onHealth: onHealth,
    ),
  );
}

void main() {
  group('隧道健康判定链路', () {
    test('不到阈值不下结论：单次失败只是抖动', () async {
      final listener = RecordingListener();
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async => 25,
      );
      addTearDown(monitor.dispose);

      await monitor.probeLatency();
      await monitor.probeLatency();

      expect(listener.healthReports, isEmpty, reason: '一抖动就重连比不重连更影响体验');
      expect(listener.latencies, <int?>[
        null,
        null,
      ], reason: '失败仍要上报，界面需要显示延迟已丢失');
    });

    test('连续三次失败且直连正常：判定隧道异常并要求恢复', () async {
      final listener = RecordingListener();
      final decisions = <TunnelHealth>[];
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async => 27,
        onHealth: decisions.add,
      );
      addTearDown(monitor.dispose);

      await monitor.probeLatency();
      await monitor.probeLatency();
      await monitor.probeLatency();

      expect(listener.healthReports, hasLength(1));
      final health = listener.healthReports.single;
      expect(health.verdict, TunnelHealthVerdict.tunnelDown);
      expect(health.consecutiveFailures, 3);
      expect(health.directLatencyMillis, 27);
      expect(health.shouldRecover, isTrue);

      // 决策与显示是两条路：内核要先拿到结论才能重启进程。
      expect(decisions, hasLength(1));
      expect(decisions.single.verdict, TunnelHealthVerdict.tunnelDown);
    });

    test('直连同时不通：只报本地网络问题，不要求恢复', () async {
      final listener = RecordingListener();
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async => null,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }

      final health = listener.healthReports.single;
      expect(health.verdict, TunnelHealthVerdict.networkDown);
      expect(health.shouldRecover, isFalse, reason: '本地网络断了，重启内核只会反复失败');
    });

    test('同一结论只上报一次，不会每 15 秒刷一遍', () async {
      final listener = RecordingListener();
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async => 25,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 8; i++) {
        await monitor.probeLatency();
      }

      expect(listener.healthReports, hasLength(1), reason: '重复的同一句结论会把界面刷成噪声');
    });

    test('恢复后补报一次健康，自愈限流才能解除', () async {
      final listener = RecordingListener();
      var tunnelUp = false;
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => tunnelUp ? 42 : null,
        direct: () async => 25,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }
      expect(
        listener.healthReports.single.verdict,
        TunnelHealthVerdict.tunnelDown,
      );

      tunnelUp = true;
      await monitor.probeLatency();

      expect(listener.healthReports, hasLength(2));
      expect(
        listener.healthReports.last.verdict,
        TunnelHealthVerdict.healthy,
        reason: '没有这条「已恢复」，限流器会永远停在上一次事故里',
      );
      expect(listener.latencies.last, 42);
    });

    test('关闭主动探测时退回旧行为：只提示，不做对照探测', () async {
      final listener = RecordingListener();
      var directProbes = 0;
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async {
          directProbes++;
          return 25;
        },
        probesEnabled: false,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }

      expect(directProbes, 0, reason: '用户明确关掉主动探测后不该偷偷发 TCP 连接');
      expect(listener.healthReports, isEmpty);
      expect(listener.errors.single, contains('延迟探测失败'));
    });

    test('先通知界面、再通知内核：通用结论不会被具体结论盖掉', () async {
      // 这个顺序是有语义的，不只是实现细节：
      //   界面先写下「隧道异常」这条通用结论（保证任何平台都看得见），
      //   内核随后写「第 N 次自动恢复」这条更具体的结论。
      // 顺序反过来的话，通用结论会把具体结论覆盖，用户就看不到内核做了什么。
      //
      // 因此这里在内核收到回调的那一刻读界面的状态：如果界面还没写进去，
      // 就说明顺序反了。
      final state = AppState();
      addTearDown(state.dispose);
      String? visibleWhenCoreActed;

      final monitor = _monitor(
        listener: state,
        tunnel: () async => null,
        direct: () async => 25,
        onHealth: (TunnelHealth health) =>
            visibleWhenCoreActed = state.lastError,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }

      expect(state.tunnelHealth?.verdict, TunnelHealthVerdict.tunnelDown);
      expect(
        visibleWhenCoreActed,
        contains('隧道'),
        reason: '内核行动时，界面上必须已经有结论了；否则通用结论会盖掉内核随后写的具体消息',
      );
      // 内核随后写下的更具体的消息，应当覆盖通用结论。
      state.onError('正在自动恢复（第 1 次）');
      expect(state.lastError, '正在自动恢复（第 1 次）');
    });
  });

  group('界面如何呈现健康结论', () {
    test('异常结论一定变成用户可见的提示', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onTunnelHealth(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.tunnelDown,
          consecutiveFailures: 3,
          directLatencyMillis: 25,
        ),
      );

      expect(state.tunnelHealth?.verdict, TunnelHealthVerdict.tunnelDown);
      expect(
        state.lastError,
        contains('隧道'),
        reason: '没有自愈能力的平台上，这条提示是用户唯一的线索',
      );
    });

    test('恢复后撤掉自己写的那条结论', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onTunnelHealth(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.networkDown,
          consecutiveFailures: 4,
        ),
      );
      expect(state.lastError, isNotNull);

      state.onTunnelHealth(const TunnelHealth.healthy(consecutiveFailures: 0));
      expect(state.lastError, isNull, reason: '已经恢复的结论留在界面上会误导');
      expect(state.tunnelHealth?.isProblem, isFalse);
    });

    test('只撤自己写的那条，不误删别的错误', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onTunnelHealth(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.tunnelDown,
          consecutiveFailures: 3,
          directLatencyMillis: 25,
        ),
      );
      // 内核接着报了一条更具体的消息，覆盖了上面那条。
      state.onError('正在自动恢复（第 1 次）');

      state.onTunnelHealth(const TunnelHealth.healthy(consecutiveFailures: 0));

      expect(
        state.lastError,
        '正在自动恢复（第 1 次）',
        reason: '恢复时不该把内核刚写下的、与健康结论无关的消息一起抹掉',
      );
    });
  });
}
