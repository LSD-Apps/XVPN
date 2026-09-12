import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/window_controls.dart';

/// 原生 → Dart 的「退出请求」握手。
///
/// Linux 上没有 Windows 那样的原生退出钩子，Dart 的收尾（还原系统代理、结束
/// sing-box）又是异步的；如果原生直接结束进程，这两步会被一起打断，用户留下一个
/// 指向死端口的系统代理和一个孤儿内核。因此约定是：原生只发 `quitRequested`，
/// Dart 跑完收尾再回一条 `quitNow`。
///
/// 这里锁两件事，都是「说好的行为」而不是实现细节：
///   * 收到请求时**先跑收尾**，跑完（或失败）才回 `quitNow`；
///   * 即使 Wayland 下不自绘窗口（[WindowControls.supported] 为 false），这条
///     推送也必须被接住——文件里说明过，一个平台通道只能有一个方法处理器，因此
///     处理器与自绘能力是两回事。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.xvpn.xvpn/platform');
  const StandardMethodCodec codec = StandardMethodCodec();
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    // 原生侧替身：listen 会查 clientDecorations，退出回敬 quitNow，都要能应答。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          // 返回 false 表示 Wayland：此时 supported 为 false。
          return call.method == 'clientDecorations' ? false : null;
        });
  });

  tearDown(() {
    WindowControls.onQuitRequested = null;
    WindowControls.linuxClientDecorations = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 模拟原生推来的一条方法调用，并等 Dart 处理器跑完。
  Future<void> pushFromNative(String method) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall(method)),
          (ByteData? _) {},
        );
  }

  test('先跑 Dart 收尾再请原生退出，Wayland 下也要接住', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final log = <String>[];
      WindowControls.onQuitRequested = () async => log.add('收尾');
      await WindowControls.listen();

      await pushFromNative('quitRequested');

      expect(log, <String>['收尾'], reason: '必须先让 Dart 收尾，不能先退进程');
      expect(
        calls.map((MethodCall call) => call.method),
        contains('quitNow'),
        reason: '收尾之后才请原生真正退出',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('收尾抛异常也必须继续退出：卡住不关比清理不干净更糟', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      WindowControls.onQuitRequested = () async => throw StateError('收尾失败');
      await WindowControls.listen();

      await pushFromNative('quitRequested');

      expect(
        calls.map((MethodCall call) => call.method),
        contains('quitNow'),
        reason: '收尾失败也要走完退出，下次启动还有 recoverIfNeeded 兜底',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
