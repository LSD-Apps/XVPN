import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/tunnel_health.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/core/wireguard_handshake.dart';
import 'package:xvpn/models.dart';

import 'support/recording_listener.dart';

/// 构造一个探测结果可控的观测引擎。
///
/// 探测间隔压到 0，否则一个用例要真等 45 秒才能凑够三次失败——那等于没法测。
///
/// 预热起点走 `warmupSince` 注入，**刻意不调用 `start()`**：那个方法会顺手拉起
/// 真实 DNS 探测与启动自检（真的去 bind UDP 套接字），把一个纯逻辑用例变成一次
/// 真实网络访问，在没有网络的环境里直接失败。
CoreMonitor _monitor({
  required VpnCoreListener listener,
  required Future<int?> Function() tunnel,
  required Future<int?> Function() direct,
  bool probesEnabled = true,
  DateTime? since,
  void Function(TunnelHealth health)? onHealth,
}) {
  final monitor = CoreMonitor(
    CoreMonitorHooks(
      listener: listener,
      clashApiPort: 2081,
      probesEnabled: probesEnabled,
      latencyProbeInterval: Duration.zero,
      tunnelLatencyProbe: tunnel,
      directLatencyProbe: direct,
      onHealth: onHealth,
      warmupSince: since ?? DateTime.now(),
    ),
  );
  return monitor;
}

void main() {
  group('预热宽限期判定（纯函数）', () {
    final connectedAt = DateTime(2026, 1, 1, 12, 0, 0);

    test('宽限期内达到阈值：判为预热，而不是节点故障', () {
      final health = evaluateTunnelHealth(
        consecutiveFailures: 3,
        threshold: 3,
        directLatencyMillis: 25,
        // 连上后 3 秒：同一节点上首次握手实测约 5 秒，此刻还没通是正常的。
        now: connectedAt.add(const Duration(seconds: 3)),
        sinceConnect: connectedAt,
      );

      expect(health.verdict, TunnelHealthVerdict.warmingUp);
      expect(health.isWarmingUp, isTrue);
      expect(
        health.isProblem,
        isFalse,
        reason: '把预热当成问题，界面就会建议用户「更换节点」——而它几秒后自己就好了',
      );
      expect(
        health.shouldRecover,
        isFalse,
        reason: '对着一份正在握手的隧道重启内核，只会把已经走通的握手拆掉重来',
      );
      expect(
        health.directLatencyMillis,
        isNull,
        reason: '预热结论不该携带直连对照：还没到判断「是谁的问题」的时候',
      );
    });

    test('宽限期一过：同样次数的失败立刻恢复成真正的隧道故障结论', () {
      final health = evaluateTunnelHealth(
        consecutiveFailures: 3,
        threshold: 3,
        directLatencyMillis: 25,
        now: connectedAt.add(tunnelWarmupWindow),
        sinceConnect: connectedAt,
      );

      expect(
        health.verdict,
        TunnelHealthVerdict.tunnelDown,
        reason: '宽限期是为了不误报，不是为了把真实故障永远藏起来',
      );
      expect(health.shouldRecover, isTrue);
      expect(health.directLatencyMillis, 25);
    });

    test('宽限期边界：最后一刻仍算预热，越过即失效', () {
      final justBefore = evaluateTunnelHealth(
        consecutiveFailures: 3,
        threshold: 3,
        directLatencyMillis: 25,
        now: connectedAt
            .add(tunnelWarmupWindow)
            .subtract(const Duration(milliseconds: 1)),
        sinceConnect: connectedAt,
      );
      expect(justBefore.verdict, TunnelHealthVerdict.warmingUp);

      final justAfter = evaluateTunnelHealth(
        consecutiveFailures: 3,
        threshold: 3,
        directLatencyMillis: 25,
        now: connectedAt.add(tunnelWarmupWindow),
        sinceConnect: connectedAt,
      );
      expect(justAfter.verdict, TunnelHealthVerdict.tunnelDown);
    });

    test('没连过时不进入预热：冷启动期间的健康判定不会被误吞', () {
      final health = evaluateTunnelHealth(
        consecutiveFailures: 3,
        threshold: 3,
        directLatencyMillis: 25,
        now: connectedAt,
        sinceConnect: null,
      );

      expect(
        health.verdict,
        TunnelHealthVerdict.tunnelDown,
        reason: 'sinceConnect 为 null 时若也判预热，等于把所有真实故障吞掉',
      );
    });

    test('不到阈值仍然是健康：预热不改变原有的「抖动不重连」行为', () {
      final health = evaluateTunnelHealth(
        consecutiveFailures: 1,
        threshold: 3,
        directLatencyMillis: 25,
        now: connectedAt.add(const Duration(seconds: 1)),
        sinceConnect: connectedAt,
      );

      expect(health.verdict, TunnelHealthVerdict.healthy);
    });

    test('预热态不占用恢复额度：它不算一次事故', () {
      final guard = HealthRecoveryGuard();
      expect(guard.restarts, 0);
      expect(guard.exhausted, isFalse);
      // 预热结论自身不触发 noteRestart，因此额度必须原样不动。
      const warming = TunnelHealth.warmingUp(consecutiveFailures: 3);
      expect(warming.shouldRecover, isFalse);
    });
  });

  group('观测引擎在预热宽限期内不下故障结论', () {
    test('宽限期内连续失败只报预热，且不打出直连对照探测', () async {
      final listener = RecordingListener();
      var directProbes = 0;
      // 基准取在**真正开始探测之前**：若取被测对象构造那一刻，三探测跑完可能
      // 已经越过 12 秒窗口，用例就会随机器快慢时好时坏。
      final probeAt = DateTime.now().add(const Duration(seconds: 1));
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async {
          directProbes++;
          return 25;
        },
        since: probeAt,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }

      expect(listener.healthReports, hasLength(1));
      expect(
        listener.healthReports.single.verdict,
        TunnelHealthVerdict.warmingUp,
      );
      expect(directProbes, 0, reason: '预热期间判不出「是谁的问题」，多打一次直连探测纯属浪费');
      expect(
        listener.errors.where((String e) => e.contains('节点可能不稳定')),
        isEmpty,
        reason: '关闭主动探测的那条分支也不该在预热期报警',
      );
    });

    test('同一份预热结论只上报一次，不会每轮刷屏', () async {
      final listener = RecordingListener();
      final probeAt = DateTime.now().add(const Duration(seconds: 1));
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async => 25,
        since: probeAt,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 8; i++) {
        await monitor.probeLatency();
      }

      expect(listener.healthReports, hasLength(1));
      expect(
        listener.healthReports.single.verdict,
        TunnelHealthVerdict.warmingUp,
      );
    });

    test('预热窗口已过时照常判故障，宽限期不会把真实故障一起吞掉', () async {
      final listener = RecordingListener();
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => null,
        direct: () async => 25,
        // 预热窗口早在过去：这一轮必须给出真正的结论。
        since: DateTime.now().subtract(tunnelWarmupWindow * 2),
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }

      expect(listener.healthReports, hasLength(1));
      expect(
        listener.healthReports.single.verdict,
        TunnelHealthVerdict.tunnelDown,
      );
      expect(listener.healthReports.single.shouldRecover, isTrue);
    });

    test('预热结束后隧道转通：正常上报延迟，不留下预热残留', () async {
      final listener = RecordingListener();
      var up = false;
      final probeAt = DateTime.now().add(const Duration(seconds: 1));
      final monitor = _monitor(
        listener: listener,
        tunnel: () async => up ? 88 : null,
        direct: () async => 25,
        since: probeAt,
      );
      addTearDown(monitor.dispose);

      for (var i = 0; i < 3; i++) {
        await monitor.probeLatency();
      }
      expect(
        listener.healthReports.single.verdict,
        TunnelHealthVerdict.warmingUp,
      );

      up = true;
      await monitor.probeLatency();

      expect(listener.latencies.last, 88);
      expect(listener.healthReports, hasLength(2));
      expect(listener.healthReports.last.verdict, TunnelHealthVerdict.healthy);
    });
  });

  group('连接流程的就绪门控', () {
    test('探测拿到耗时即通过，不会白等到超时', () async {
      var calls = 0;
      final ready = await waitForTunnelReady(
        probe: () async {
          calls++;
          return 42;
        },
        isAborted: () => false,
        timeout: const Duration(seconds: 5),
        interval: const Duration(milliseconds: 1),
      );

      expect(ready, isTrue);
      expect(calls, 1, reason: '第一次就通了却继续探测，是在白白拖长用户的等待');
    });

    test('一直不通时等到上限才放弃，并如实返回 false', () async {
      var calls = 0;
      final started = DateTime.now();
      final ready = await waitForTunnelReady(
        probe: () async {
          calls++;
          return null;
        },
        isAborted: () => false,
        timeout: const Duration(milliseconds: 120),
        interval: const Duration(milliseconds: 20),
      );
      final elapsed = DateTime.now().difference(started);

      expect(ready, isFalse);
      expect(calls, greaterThan(1), reason: '一次探测失败就放弃，慢握手的节点会被误判成连不上');
      expect(
        elapsed,
        lessThan(const Duration(milliseconds: 900)),
        reason: '等待上限必须真的封顶：睡眠也要计入，否则实际等待会超出 timeout 一个 interval',
      );
    });

    test('用户在等待期间断开：门控立刻收手，不把已拆掉的内核说成已连接', () async {
      var aborted = false;
      var calls = 0;
      final ready = await waitForTunnelReady(
        probe: () async {
          calls++;
          // 第一次探测期间用户点了断开。
          aborted = true;
          return null;
        },
        isAborted: () => aborted,
        timeout: const Duration(seconds: 30),
        interval: const Duration(milliseconds: 1),
      );

      expect(ready, isFalse);
      expect(calls, 1, reason: '断开之后还继续探测，等于对着一个已经消失的内核反复敲门');
    });
  });

  group('两端共用的就绪门控流程', () {
    // 这一段的重点是「两端走同一条代码」：门控的顺序（先广播预热、再等待、
    // 超时才提示）本身就是语义，各写一遍迟早分叉。
    test('先广播预热态，隧道通了才返回 true', () async {
      final listener = RecordingListener();
      final statusesWhenProbed = <List<VpnStatus>>[];

      final ready = await runTunnelReadyGate(
        listener: listener,
        probe: () async {
          // 探测发生时，界面上必须已经是「建立隧道中」，而不是已连接。
          statusesWhenProbed.add(List<VpnStatus>.from(listener.statuses));
          return 55;
        },
        isAborted: () => false,
        timeout: const Duration(seconds: 5),
        interval: const Duration(milliseconds: 1),
      );

      expect(ready, isTrue);
      expect(listener.statuses, <VpnStatus>[VpnStatus.warmingUp]);
      expect(statusesWhenProbed.single, <VpnStatus>[
        VpnStatus.warmingUp,
      ], reason: '探测时若界面还是旧状态，那几秒里用户看到的仍是「已连接」');
      expect(listener.errors, isEmpty, reason: '门控成功不该留下任何提示');
    });

    test('超时返回 false 并给出可撤销的提示', () async {
      final listener = RecordingListener();

      final ready = await runTunnelReadyGate(
        listener: listener,
        probe: () async => null,
        isAborted: () => false,
        timeout: const Duration(milliseconds: 60),
        interval: const Duration(milliseconds: 10),
      );

      expect(ready, isFalse);
      expect(listener.statuses, <VpnStatus>[VpnStatus.warmingUp]);
      expect(
        listener.errors.single,
        tunnelNotReadyNotice,
        reason: '提示必须是那个可被撤销的常量，否则隧道恢复后它会永远留在界面上',
      );
    });

    test('被取消时不写提示：那是用户主动断开，不是故障', () async {
      final listener = RecordingListener();
      var aborted = false;

      final ready = await runTunnelReadyGate(
        listener: listener,
        probe: () async {
          aborted = true;
          return null;
        },
        isAborted: () => aborted,
        timeout: const Duration(seconds: 30),
        interval: const Duration(milliseconds: 1),
      );

      expect(ready, isFalse);
      expect(listener.errors, isEmpty, reason: '用户自己点了断开，界面不该再弹一句「隧道尚未就绪」');
    });
  });

  group('界面如何呈现预热态', () {
    test('预热态仍算「连接中」：连接按钮必须保持禁用', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onStatusChanged(VpnStatus.warmingUp);

      expect(state.isWarmingUp, isTrue);
      expect(
        state.isConnecting,
        isTrue,
        reason: '预热时若按钮可用，用户再点一次会并发跑两遍 connect()',
      );
      expect(state.isConnected, isFalse, reason: '隧道还不能载流量，不能算已连接');
    });

    test('预热态允许断开：点了必须真的断开，而不是被静默忽略', () async {
      final state = AppState();
      addTearDown(state.dispose);
      state.onStatusChanged(VpnStatus.warmingUp);

      await state.toggleConnection();

      expect(
        state.status,
        VpnStatus.disconnected,
        reason: '此前预热态会落到「连接中」分支被忽略——用户点了没反应，只能干等门控超时',
      );
    });

    test('预热转正时不清空失败记录：预热期的失败是排查证据', () async {
      final state = AppState();
      addTearDown(state.dispose);

      // connecting 会清空失败记录；预热紧随其后，不该再清一次。
      state.onStatusChanged(VpnStatus.connecting);
      state.onConnectionFailure(
        ConnectionFailure(
          time: DateTime.now(),
          target: 'example.com',
          outbound: 'vpn',
          reason: 'context deadline exceeded',
        ),
      );
      expect(state.failures, hasLength(1));

      state.onStatusChanged(VpnStatus.warmingUp);

      expect(
        state.failures,
        hasLength(1),
        reason:
            '预热期记录下的失败正是排查「为什么连上却打不开」的证据，'
            '在预热转正时被抹掉就再也看不到当时的现场了',
      );
    });

    test('从预热进入已连接：计时器才开始走', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onStatusChanged(VpnStatus.warmingUp);
      expect(state.elapsed, Duration.zero);

      state.onStatusChanged(VpnStatus.connected);
      expect(state.isConnected, isTrue);
      expect(state.isWarmingUp, isFalse);
    });

    test('门控超时的提示在隧道恢复后撤销，不留过期结论', () {
      final state = AppState();
      addTearDown(state.dispose);

      // 门控超时**不阻断连接**，隧道完全可能过几秒才通——实测正是如此。
      state.onError(tunnelNotReadyNotice);
      expect(state.lastError, isNotNull);

      state.onTunnelHealth(const TunnelHealth.healthy(consecutiveFailures: 0));

      expect(
        state.lastError,
        isNull,
        reason: '隧道都通了还挂着「尚未就绪」，用户会拿着过期结论排查一条已经好了的隧道',
      );
    });

    test('撤销只针对自己那条：别人写的消息不误删', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onError('内核已退出（代码 1）');
      state.onTunnelHealth(const TunnelHealth.healthy(consecutiveFailures: 0));

      expect(
        state.lastError,
        '内核已退出（代码 1）',
        reason: '恢复健康只该撤掉「端口未就绪」这类自己写的临时说明',
      );
    });
  });

  group('握手状态接在内核日志管线上', () {
    /// 用真实内核的措辞喂进去。这一条链路此前没有被端到端测过：解析器单测覆盖
    /// 措辞，这里覆盖「日志真的从内核走到底层状态」这一段。
    test('真实日志序列能推出「无应答」，并带上对端短标识', () {
      final state = AppState(
        coreFactory: (VpnCoreListener l) =>
            SingBoxRunner(l, probesEnabled: false),
      );
      addTearDown(state.dispose);
      final core = state.core;

      expect(core.handshake.isKnown, isFalse, reason: '还没连过，不该有握手结论');

      for (final line in <String>[
        '+0800 2026-09-11 22:18:03 DEBUG endpoint/wireguard[vpn]: '
            'peer(Qk9y…7tZa) - sending handshake initiation',
        '+0800 2026-09-11 22:18:08 DEBUG endpoint/wireguard[vpn]: '
            'peer(Qk9y…7tZa) - handshake did not complete after 5 seconds, retrying (try 2)',
      ]) {
        core.handleCoreLog(line);
      }

      expect(core.handshake.phase, HandshakePhase.noResponse);
      expect(core.handshake.attempts, 2);
      expect(core.handshake.peerPublicKey, 'Qk9y…7tZa');
    });

    test('收到应答后转为已应答——这是「密钥与通路都成立」的信号', () {
      final state = AppState(
        coreFactory: (VpnCoreListener l) =>
            SingBoxRunner(l, probesEnabled: false),
      );
      addTearDown(state.dispose);
      final core = state.core;

      core.handleCoreLog(
        'DEBUG endpoint/wireguard[vpn]: peer(a) - sending handshake initiation',
      );
      expect(core.handshake.phase, HandshakePhase.awaitingResponse);

      core.handleCoreLog(
        'DEBUG endpoint/wireguard[vpn]: peer(a) - received handshake response',
      );
      expect(core.handshake.phase, HandshakePhase.responded);
    });
  });
}
