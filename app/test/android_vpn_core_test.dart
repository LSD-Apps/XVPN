import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/android_vpn_core.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';

/// 记录内核回调，用来断言状态迁移。
class _Recorder implements VpnCoreListener {
  final List<VpnStatus> statuses = <VpnStatus>[];
  final List<String> errors = <String>[];
  final List<String> logFailures = <String>[];

  @override
  void onStatusChanged(VpnStatus status) => statuses.add(status);

  @override
  void onTraffic({required double downBps, required double upBps, required int totalBytes}) {}

  @override
  void onLatency(int? millis) {}

  @override
  void onSplitRecord(SplitRecord record) {}

  @override
  void onConnectionFailure(ConnectionFailure failure) => logFailures.add(failure.target);

  @override
  void onError(String message) => errors.add(message);
}

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

  group('AndroidVpnCore.resumeIfRunning', () {
    test('内核仍在运行时会接管，并把状态置为已连接', () async {
      final calls = mockChannel(running: true);
      final recorder = _Recorder();
      final core = AndroidVpnCore(recorder);

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
      final core = AndroidVpnCore(recorder);

      final adopted = await core.resumeIfRunning();

      expect(adopted, isFalse);
      expect(recorder.statuses, isEmpty);
      core.dispose();
    });

    test('原生通道不可用时不抛异常，只是不接管', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final recorder = _Recorder();
      final core = AndroidVpnCore(recorder);

      // 通道没有实现时 invokeMethod 会抛 MissingPluginException，
      // 这里要求它被吞掉——启动路径上的异常会让整个界面起不来。
      final adopted = await core.resumeIfRunning();

      expect(adopted, isFalse);
      expect(recorder.statuses, isEmpty);
      core.dispose();
    });
  });
}
