import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/tunnel_health.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/recording_listener.dart';

/// 一份合法配置，用于构造 VpnProfile。
const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.0.0.3/32

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 1.2.3.4:51820
''';

void main() {
  group('SingBoxRunner 的观测依赖接线', () {
    test('monitorHooks 每次返回同一个实例，改端口才会生效', () {
      // 观测引擎只拿一次 hooks。如果这里每次 new 一个新的，那么连接时选定的
      // Clash API 端口就同步不过去，表现是「连上了但速率、连接数、分流记录全空」。
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      final first = runner.monitorHooks();
      expect(identical(runner.monitorHooks(), first), isTrue);

      first.clashApiPort = 12081;
      expect(runner.monitorHooks().clashApiPort, 12081);
    });

    test('观测引擎拿到的是内核自己的自动纠正表，而不是「不学习」的默认值', () {
      // 这条守的是 late 字段的初始化时机：hooks 是在父类构造里就被取走的，
      // 那一刻如果内核自己的表还没准备好，自动纠正会静默失效——分流规则不再
      // 学习，用户只会觉得「有时候能连有时候不能」。
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      expect(runner.monitorHooks().autoRoute, isNotNull);
      expect(
        identical(runner.monitorHooks().autoRoute, runner.autoRoute),
        isTrue,
      );
    });

    test('默认端口取自配置生成器，两处不会各写一个数字', () {
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      expect(
        runner.monitorHooks().clashApiPort,
        SingBoxConfigBuilder.defaultClashApiPort,
      );
      expect(SingBoxRunner.mixedPort, SingBoxConfigBuilder.defaultMixedPort);
    });

    test('关闭主动探测时，hooks 也如实反映', () {
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      expect(runner.monitorHooks().probesEnabled, isFalse);
    });

    test('健康结论回到内核自己：隧道不通时会产生一次自动恢复动作', () {
      // 隧道不通时要重启进程，而这件事只有内核自己做得了。这里断言的是
      // **行为**而不是对象标识：方法撕下来（tear-off）每次都是新闭包，
      // 比 identical 只会得到一个永远为假的结论。
      final recorder = RecordingListener();
      final runner = SingBoxRunner(recorder, probesEnabled: false);
      addTearDown(runner.dispose);

      final hooks = runner.monitorHooks();
      expect(hooks.onHealth, isNotNull);

      hooks.onHealth!(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.tunnelDown,
          consecutiveFailures: 3,
          directLatencyMillis: 25,
        ),
      );

      expect(
        recorder.errors.any((String e) => e.contains('自动恢复')),
        isTrue,
        reason: '结论没能到达内核，用户就永远等不到自愈',
      );
    });

    test('内核卡住同样会触发自动恢复', () {
      // 「读不到内核」与「隧道不通」是两路信号，但对内核来说处置一样：
      // 重启是唯一能立刻恢复的手段。
      final recorder = RecordingListener();
      final runner = SingBoxRunner(recorder, probesEnabled: false);
      addTearDown(runner.dispose);

      runner.monitorHooks().onHealth!(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.coreUnreachable,
          consecutiveFailures: 5,
        ),
      );

      expect(
        recorder.errors.any((String e) => e.contains('自动恢复')),
        isTrue,
        reason: '内核卡住时不重启，界面会一直停在「已连接」而数字全冻住',
      );
    });

    test('本地网络断了不会触发自动恢复', () {
      final recorder = RecordingListener();
      final runner = SingBoxRunner(recorder, probesEnabled: false);
      addTearDown(runner.dispose);

      runner.monitorHooks().onHealth!(
        const TunnelHealth(
          verdict: TunnelHealthVerdict.networkDown,
          consecutiveFailures: 3,
        ),
      );

      expect(
        recorder.errors.any((String e) => e.contains('自动恢复')),
        isFalse,
        reason: '本地网络断了重连只会空转',
      );
    });

    test('被冷却期拦下时也要出声', () {
      // 此前只有「额度用尽」会提示，而「还在冷却期内」是**静默**的：
      // 用户看到诊断说隧道异常，却什么都没发生，也没有任何解释。
      final recorder = RecordingListener();
      final runner = SingBoxRunner(recorder, probesEnabled: false);
      addTearDown(runner.dispose);

      const tunnelDown = TunnelHealth(
        verdict: TunnelHealthVerdict.tunnelDown,
        consecutiveFailures: 3,
        directLatencyMillis: 25,
      );
      final hooks = runner.monitorHooks();
      // 第一次：执行恢复（这里没有配置可重启，但额度与冷却起点都记下了）。
      hooks.onHealth!(tunnelDown);
      // 第二次：仍在冷却期内，必须说明为什么没有动作。
      hooks.onHealth!(tunnelDown);

      expect(
        recorder.errors.any(
          (String e) => e.contains('暂不重复重启') || e.contains('已用尽'),
        ),
        isTrue,
        reason: '拦下来却不解释，用户只会以为程序卡住了',
      );
    });

    test('观测引擎的端口可在连接前改写（内核换端口用）', () {
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      final CoreMonitorHooks hooks = runner.monitorHooks();
      hooks.clashApiPort = 12099;
      expect(hooks.clashApiPort, 12099);
    });
  });

  group('断开与启动的竞争', () {
    test('断开之后再连接，不会被上一轮的「用户断开」标记卡住', () async {
      // 启动路径上的每一次 await 之后都会查这个标记（否则用户在半途点断开，
      // 已经拆掉的内核与系统代理会被重新装回来）。它是**按次**的：新一轮
      // connect 必须把它清掉，否则第二次连接会静默什么都不做。
      final recorder = RecordingListener();
      final runner = SingBoxRunner(recorder, probesEnabled: false);
      addTearDown(runner.dispose);

      await runner.disconnect();
      final parsed = VpnProtocolFactory.parse(_conf, 'x.conf');
      await runner.connect(
        VpnProfile(id: 'x', name: 'x.conf', parsed: parsed),
        const AppSettings(autoConnectOnImport: false),
      );

      // 测试进程旁边没有 sing-box.exe，因此必然走到「缺少内核文件」。
      // 关键是它**走到了**：说明没有被上一轮的断开标记挡住。
      expect(
        recorder.errors.any((String e) => e.contains('缺少内核文件')),
        isTrue,
        reason: '新一轮连接被上一轮的断开标记挡住的话，用户点连接会毫无反应',
      );
    });

    test('已销毁的内核不会再被拉起来，也不会广播「连接中」', () async {
      // 守的是启动路径开头那道判断（在广播之前）。同一个判断还盖住了一个
      // 无法用测试确定性复现的竞态：用户点断开时，启动流程已经排在队列里
      // （自愈重启正在进行、或 connect 卡在拆旧内核那一步）——那时先广播
      // 「连接中」再悄悄返回，界面就会**永远停在连接中**。
      //
      // 这里走的是它另一个分支：对象已销毁。效果等价，且可复现。
      final recorder = RecordingListener();
      final runner = SingBoxRunner(recorder, probesEnabled: false);
      runner.dispose();
      recorder.statuses.clear();

      final parsed = VpnProtocolFactory.parse(_conf, 'x.conf');
      await runner.connect(
        VpnProfile(id: 'x', name: 'x.conf', parsed: parsed),
        const AppSettings(autoConnectOnImport: false),
      );

      expect(
        recorder.statuses,
        isNot(contains(VpnStatus.connecting)),
        reason: '已销毁的内核被重新拉起来，界面会卡在连接中，而且没有任何东西能把它停掉',
      );
      expect(
        recorder.errors,
        isEmpty,
        reason: '不该再去碰内核文件（这个测试进程旁边根本没有 sing-box.exe）',
      );
    });
  });

  group('停止内核时的日志处理', () {
    test('半行日志被收下，不会粘到下一次连接的第一行前面', () async {
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      // 内核被杀掉前正好写了一半（输出没有以换行结尾）。
      runner.handleCoreLogChunk('内核写了一半就');
      expect(runner.kernelLog.lines, isEmpty, reason: '没结束的那一行还不算完整行');

      await runner.disconnect();

      expect(runner.kernelLog.lines, <String>[
        '内核写了一半就',
      ], reason: '停止时要把它收下；否则它会一直留在待续区');

      // 下一次连接的第一段输出。
      runner.handleCoreLogChunk('\n下一段输出\n');
      expect(runner.kernelLog.lines, <String>[
        '内核写了一半就',
        '下一段输出',
      ], reason: '上一个会话的半行被拼到新会话第一行前面，会造出一条根本不存在的内容');
    });
  });
}
