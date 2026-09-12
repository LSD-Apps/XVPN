import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/android_vpn_core.dart';
import 'package:xvpn/core/singbox_runner.dart';

import 'support/recording_listener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('日志进入缓冲并通知界面', () {
    test('一行日志被收下，并通知一次界面', () {
      final listener = RecordingListener();
      final core = SingBoxRunner(listener, probesEnabled: false);
      addTearDown(core.dispose);

      core.handleCoreLog('WARN outbound/vpn: connection refused');

      expect(core.kernelLog.lines, <String>[
        'WARN outbound/vpn: connection refused',
      ]);
      expect(listener.kernelLogNotifications, 1);
    });

    test('空行不占位置也不惊动界面', () {
      final listener = RecordingListener();
      final core = SingBoxRunner(listener, probesEnabled: false);
      addTearDown(core.dispose);

      core.handleCoreLog('   ');

      expect(core.kernelLog.lines, isEmpty);
      expect(listener.kernelLogNotifications, 0);
    });

    test('一整块输出只通知一次，而不是每行一次', () {
      // 内核一次输出动辄几十行。逐行通知会把界面刷成噪声，
      // 而日志内容本身没有「每行都要立刻上屏」的要求。
      final listener = RecordingListener();
      final core = SingBoxRunner(listener, probesEnabled: false);
      addTearDown(core.dispose);

      core.handleCoreLogChunk('一行\n二行\n三行\n');

      expect(core.kernelLog.lines, hasLength(3));
      expect(listener.kernelLogNotifications, 1);
    });

    test('只有半截行时不通知，等它拼完整', () {
      final listener = RecordingListener();
      final core = SingBoxRunner(listener, probesEnabled: false);
      addTearDown(core.dispose);

      core.handleCoreLogChunk('还没结束的一行');

      expect(listener.kernelLogNotifications, 0);
      expect(core.kernelLog.lines, isEmpty);

      core.handleCoreLogChunk('（接上）\n');
      expect(core.kernelLog.lines, <String>['还没结束的一行（接上）']);
      expect(listener.kernelLogNotifications, 1);
    });

    test('日志不会因为界面报错而被当成错误', () {
      // 日志是材料不是结论。绝大多数行都不代表出错，按错误显示会把真正的
      // 错误淹掉——用户看到满屏红字反而找不到重点。
      final listener = RecordingListener();
      final core = SingBoxRunner(listener, probesEnabled: false);
      addTearDown(core.dispose);

      core.handleCoreLog('INFO inbound/mixed: connection to 1.1.1.1:443');

      expect(listener.errors, isEmpty);
      expect(listener.kernelLogNotifications, 1);
    });
  });

  group('安卓端同样留存日志', () {
    const channel = MethodChannel('com.xvpn.xvpn/vpn');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('原生推来的 coreLog 会进同一个缓冲', () async {
      // 这条守的是两端一致性：此前安卓端读完日志就丢，出了问题是**什么都查不到**的，
      // 而 Windows 端至少还有 40 行。现在两端共用同一个缓冲。
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'status') {
          return <String, Object?>{'running': true};
        }
        return null;
      });

      final listener = RecordingListener();
      final core = AndroidVpnCore(listener, probesEnabled: false);
      // 接管路径会注册日志转发回调。
      expect(await core.resumeIfRunning(), isTrue);
      addTearDown(core.dispose);

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('coreLog', 'WARN 安卓内核的一行日志'),
        ),
        (ByteData? _) {},
      );

      expect(core.kernelLog.lines, <String>['WARN 安卓内核的一行日志']);
      expect(listener.kernelLogNotifications, 1);
    });
  });

  group('AppState 暴露日志给界面', () {
    test('日志可读、可清空', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.core.handleCoreLog('第一行');
      state.core.handleCoreLog('第二行');

      expect(state.kernelLog, <String>['第一行', '第二行']);
      expect(state.kernelLogDropped, 0);

      state.clearKernelLog();
      expect(state.kernelLog, isEmpty);
    });

    test('日志到达会通知界面刷新，但不会变成错误提示', () async {
      final state = AppState();
      addTearDown(state.dispose);
      var notified = 0;
      state.addListener(() => notified++);

      state.core.handleCoreLog('WARN something happened');
      // 重绘请求被合并到一个微任务里（内核日志按块、高频到达，逐块重建界面会
      // 把主线程占满，而它与分流数据处理共用同一个 isolate），因此要让它跑完。
      await Future<void>.microtask(() {});

      expect(notified, greaterThan(0), reason: '日志视图要能自己刷新');
      expect(state.lastError, isNull, reason: '日志不是错误。写进错误提示会让真正的问题被满屏日志淹掉');
    });

    test('同一轮里多条日志只触发一次重绘', () async {
      final state = AppState();
      addTearDown(state.dispose);
      var notified = 0;
      state.addListener(() => notified++);

      // 一次内核输出往往包含几十行，按块到达。逐块重建整棵界面树是纯粹的浪费，
      // 而界面卡住会直接推迟分流数据的处理。
      for (var i = 0; i < 20; i++) {
        state.core.handleCoreLog('DEBUG line $i');
      }
      await Future<void>.microtask(() {});

      expect(notified, 1, reason: '同一轮里的 20 条日志应当合并成一次重绘，而不是 20 次');
    });
  });
}
