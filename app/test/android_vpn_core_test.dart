import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/android_vpn_core.dart';
import 'package:xvpn/models.dart';

import 'support/recording_listener.dart';

/// 本文件的断言只关心状态迁移与错误上报，因此直接用共享的记录器。
typedef _Recorder = RecordingListener;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.xvpn.xvpn/vpn');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

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
      expect(
        recorder.statuses,
        <VpnStatus>[VpnStatus.connected],
        reason: '界面必须立刻反映「隧道其实还开着」，否则会显示未连接却仍在走隧道',
      );

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
}
