import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/android_vpn_core.dart';
import 'package:xvpn/core/tunnel_health.dart';
import 'package:xvpn/models.dart';

import 'support/recording_listener.dart';

/// 本文件的断言只关心状态迁移与错误上报，因此直接用共享的记录器。
typedef _Recorder = RecordingListener;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.xvpn.xvpn/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 拦截原生通道，并记录 Dart 侧发出的每一次调用。
  List<String> mockChannel({required bool running, String? error}) {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'status':
          return <String, Object?>{'running': running, 'error': error};
        case 'coreLog':
          return null;
        default:
          return null;
      }
    });
    return calls;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// 关掉主动探测。
  ///
  /// 接管成功后会启动观测引擎，它默认会立刻发一轮 DNS 探测（UDP）与启动自检
  /// （TCP 连本机外的地址）。测试环境里这两者既不允许也没有意义，而且它们的
  /// 异步工作在测试结束后才回来，会被 flutter_test 判为「有未完成的异步工作」。
  AndroidVpnCore newCore(_Recorder recorder) =>
      AndroidVpnCore(recorder, probesEnabled: false);

  group('AndroidVpnCore.resumeIfRunning', () {
    test('内核仍在运行时会接管，并把状态置为已连接', () async {
      final calls = mockChannel(running: true);
      final recorder = _Recorder();
      final core = newCore(recorder);

      final adopted = await core.resumeIfRunning();

      expect(adopted, isTrue);
      expect(calls, contains('status'));
      expect(recorder.statuses, <VpnStatus>[
        VpnStatus.connected,
      ], reason: '界面必须立刻反映「隧道其实还开着」，否则会显示未连接却仍在走隧道');

      // 接管后开始轮询，测试结束前必须停掉，否则会留下未取消的定时器。
      core.dispose();
    });

    test('内核没在运行时不动状态', () async {
      mockChannel(running: false);
      final recorder = _Recorder();
      final core = newCore(recorder);

      final adopted = await core.resumeIfRunning();

      expect(adopted, isFalse);
      expect(recorder.statuses, isEmpty);
      core.dispose();
    });

    test('原生通道不可用时不抛异常，只是不接管', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final recorder = _Recorder();
      final core = newCore(recorder);

      // 通道没有实现时 invokeMethod 会抛 MissingPluginException，
      // 这里要求它被吞掉——启动路径上的异常会让整个界面起不来。
      final adopted = await core.resumeIfRunning();

      expect(adopted, isFalse);
      expect(recorder.statuses, isEmpty);
      core.dispose();
    });
  });

  group('AndroidVpnCore 的隧道自愈', () {
    /// 与桌面端同一个限流器语义：这里把冷却压到 0、额度设为 2，才能在一次
    /// 用例里数清「恰好恢复了几次」。
    AndroidVpnCore recoveryCore(
      _Recorder recorder,
      void Function() onRestart,
    ) {
      return AndroidVpnCore(
        recorder,
        probesEnabled: false,
        healthGuard: HealthRecoveryGuard(
          maxRestarts: 2,
          cooldown: Duration.zero,
        ),
        recoveryRestart: () async => onRestart(),
      );
    }

    const tunnelDown = TunnelHealth(
      verdict: TunnelHealthVerdict.tunnelDown,
      consecutiveFailures: 3,
      directLatencyMillis: 25,
    );

    test('不健康结论触发恰好 N 次恢复，额度用尽后出声', () async {
      final recorder = _Recorder();
      var restarts = 0;
      final core = recoveryCore(recorder, () => restarts++);
      addTearDown(core.dispose);

      // 前两次：额度内，真的执行恢复。
      for (var i = 0; i < 2; i++) {
        core.handleTunnelHealth(tunnelDown);
        await Future<void>.delayed(Duration.zero);
      }

      expect(restarts, 2, reason: '额度内的每次判定都应触发一次恢复');
      expect(
        recorder.errors.where((String e) => e.contains('自动恢复')).length,
        2,
      );

      // 第三次：额度用尽，必须明确说明为什么没有动作，而不是静默。
      core.handleTunnelHealth(tunnelDown);
      await Future<void>.delayed(Duration.zero);

      expect(restarts, 2, reason: '额度用尽后不应再重启隧道');
      expect(
        recorder.errors.last,
        contains('已用尽'),
        reason: '拦下来却不解释，用户只会以为程序卡住了',
      );
    });

    test('本地网络问题不触发恢复', () async {
      final recorder = _Recorder();
      var restarts = 0;
      final core = recoveryCore(recorder, () => restarts++);
      addTearDown(core.dispose);

      core.handleTunnelHealth(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.networkDown,
          consecutiveFailures: 3,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        restarts,
        0,
        reason: '本地网络断了，重建 VpnService 只会反复失败',
      );
      expect(recorder.errors, isEmpty);
    });

    test('健康恢复会归还额度', () async {
      final recorder = _Recorder();
      var restarts = 0;
      final core = recoveryCore(recorder, () => restarts++);
      addTearDown(core.dispose);

      core.handleTunnelHealth(tunnelDown);
      await Future<void>.delayed(Duration.zero);
      expect(restarts, 1);

      // 隧道恢复正常：额度重新可用（但冷却时间戳保留，见桌面端同款语义）。
      core.handleTunnelHealth(
        const TunnelHealth.healthy(consecutiveFailures: 0),
      );
      core.handleTunnelHealth(tunnelDown);
      await Future<void>.delayed(Duration.zero);

      expect(restarts, 2, reason: '恢复之后新一轮事故应当重新获得额度');
    });

    test('显式断开抑制自愈，内核不会把刚拆掉的隧道又拉起来', () async {
      final recorder = _Recorder();
      var restarts = 0;
      final core = recoveryCore(recorder, () => restarts++);
      addTearDown(core.dispose);

      mockChannel(running: false);
      await core.disconnect();

      core.handleTunnelHealth(tunnelDown);
      await Future<void>.delayed(Duration.zero);

      expect(
        restarts,
        0,
        reason: '用户明确断开后自愈还动手，表现为「断开之后自己又连上了」',
      );
      expect(
        recorder.errors.any((String e) => e.contains('自动恢复')),
        isFalse,
      );
    });
  });
}
