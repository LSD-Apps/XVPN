import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/screen_navigation.dart';
import 'package:xvpn/core/window_controls.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';

/// 托盘「发现新版本」到更新界面的通路。
///
/// 这条用例的由来是一个**真实的假界面**：托盘里那条「发现新版本 vX」被做成
/// 灰色纯信息项（Windows 用 `MF_GRAYED` 且菜单 id 为 0，Linux 用
/// `set_sensitive(FALSE)`），于是应用告诉用户有新版本、却不给他任何出路。
///
/// 更值得记下来的是它当初的理由是**错的**：`flutter_window.cpp` 里写着
/// 「没有一条现成的 native → Dart 通道」，而那条通道本就在用——同文件的
/// `maximizedChanged`，以及 Linux 的 `quitRequested`。一个凭不成立的前提做出的
/// 让步，最后落成了一个不能用的菜单项。
///
/// 因此这里锁三层，缺任何一层这条通路都是断的：
///   1. 原生推来的 `trayOpenUpdate` 必须被接住；
///   2. 即使 Wayland 下不自绘窗口也要接住（同 `quitRequested` 的教训：
///      一个平台通道只能有一个方法处理器，能与不能自绘是两回事）；
///   3. 外壳要把它落到**两端各自**的设置页索引上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.xvpn.xvpn/platform');
  const StandardMethodCodec codec = StandardMethodCodec();

  group('原生 → Dart 的「打开更新界面」推送', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            // false 表示 Wayland：此时 WindowControls.supported 为 false。
            return call.method == 'clientDecorations' ? false : null;
          });
    });

    tearDown(() {
      WindowControls.onShowUpdateRequested = null;
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

    test('收到推送时调用注册的回调', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        var opened = 0;
        WindowControls.onShowUpdateRequested = () => opened++;
        await WindowControls.listen();

        await pushFromNative('trayOpenUpdate');

        expect(
          opened,
          1,
          reason: '托盘那条菜单项可点之后，必须真的有人接住它——'
              '否则比灰显更糟：看着能点，点了什么都不发生',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('Wayland 下不自绘窗口也要接住这条推送', () async {
      // 与 quitRequested 同一个坑：处理器是在 listen() 里统一安装并**按方法名
      // 分发**的（一个通道只能有一个处理器）。若把安装条件绑在「能不能自绘
      // 窗口」上，Wayland 用户的托盘更新项会静默失效。
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        var opened = 0;
        WindowControls.onShowUpdateRequested = () => opened++;
        await WindowControls.listen();
        expect(
          WindowControls.supported,
          isFalse,
          reason: '前置条件：这个替身让 Linux 报 Wayland，因而不自绘窗口',
        );

        await pushFromNative('trayOpenUpdate');

        expect(opened, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('没有注册回调时不抛异常（测试与嵌入场景）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        WindowControls.onShowUpdateRequested = null;
        await WindowControls.listen();

        await pushFromNative('trayOpenUpdate');

        // 原生那边至少还把窗口亮了出来，因此这里静默是正确的降级：
        // 不该把一个异步异常甩到界面上。
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('外壳把「设置」意图落到两端的正确索引', () {
    setUp(() {
      applyPalette(XvPalette.dark);
      ScreenNavigation.instance.consume();
    });

    /// 两端各自的尺寸与期望落点。
    ///
    /// 索引**逐端不同**是既有事实：移动端没有独立的「配置文件」标签，配置列表
    /// 与更新入口都内嵌在设置标签里。桌面侧栏里设置是第 5 项（索引 4）。
    for (final testCase in <({TargetPlatform platform, Size size, String name})>[
      (platform: TargetPlatform.windows, size: Size(1400, 1200), name: '桌面'),
      (platform: TargetPlatform.android, size: Size(390, 900), name: '移动端'),
    ]) {
      testWidgets('${testCase.name}：请求设置区后落到设置页，且意图被消费', (
        WidgetTester tester,
      ) async {
        debugDefaultTargetPlatformOverride = testCase.platform;
        final state = AppState();
        final theme = ThemeController();
        addTearDown(theme.dispose);
        try {
          tester.view.physicalSize = testCase.size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildXvTheme(XvPalette.dark),
              home: XvShell(
                key: ValueKey<TargetPlatform>(testCase.platform),
                state: state,
                theme: theme,
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byType(SettingsScreen),
            findsNothing,
            reason: '${testCase.name} 初始应停在连接页',
          );

          ScreenNavigation.instance.request(AppSection.settings);
          await tester.pumpAndSettle();

          expect(
            find.byType(SettingsScreen),
            findsOneWidget,
            reason: '${testCase.name} 收到意图后应落到设置页（更新入口在那里）',
          );
          expect(
            ScreenNavigation.instance.value,
            isNull,
            reason: '意图必须被消费，否则下一次重建会重复跳转',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          state.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
