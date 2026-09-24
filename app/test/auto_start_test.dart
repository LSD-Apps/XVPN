import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/auto_start.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/core/system_tray.dart';
import 'package:xvpn/core/update_center.dart';
import 'package:xvpn/core/updater.dart';
import 'package:xvpn/core/window_controls.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';

/// 「随系统启动」的两半：**Dart 这一半**的镜像与界面行为。
///
/// 真正把启动项写进系统的是原生（Windows 上是
/// `HKCU\...\CurrentVersion\Run`，见 app/windows/runner/auto_start.cc）。这里锁住
/// 的是另外三条容易出错的规律：
///
///   1. **后端能用才显示开关**。拨一个不会有任何效果的开关比没有开关更糟，
///      因此原生回答「当前形态用不了」时这一行必须**不渲染**；
///   2. **系统是事实来源**。用户在「任务管理器 → 启动」里改了它，存档里的镜像就
///      过期了，启动时必须被回读结果校准；
///   3. **托盘与设置页说的是同一件事**。托盘在原生侧，它改了状态会推回来，
///      设置页必须跟上——否则同一个事实在一端显示为开、另一端显示为关。
/// 让用例跑在「Windows 桌面」这个平台上。
///
/// 用 [TargetPlatformVariant] 而不是自己写 `debugDefaultTargetPlatformOverride`
/// 加 `addTearDown`：那条调试变量有一条框架自带的纪律——`testWidgets` 在**用例体
/// 结束时**（早于任何 tearDown）就断言它已经还原。写在用例里靠 addTearDown 清理
/// 会失败，而且报出来的是一句与真实原因毫无关系的
/// 「The value of a foundation debug variable was changed by the test」。
final TargetPlatformVariant onWindows = TargetPlatformVariant.only(
  TargetPlatform.windows,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.xvpn.xvpn/platform');
  late List<MethodCall> calls;

  /// 原生侧替身的状态。**必须有状态**：`setAutoStart` 之后要回读，而无状态的
  /// 替身会让「拨开 → 回读 → 又是关」变成一次静默的自我否定，于是「拨开关」
  /// 那条用例永远测不出真实行为。
  late bool nativeSupported;
  late bool nativeEnabled;
  late bool nativeAcceptsSet;

  /// 原生侧替身：按需回答能力与状态，并记录被调用的方法。
  void installNative({
    bool supported = true,
    bool enabled = false,
    bool acceptSet = true,
  }) {
    nativeSupported = supported;
    nativeEnabled = enabled;
    nativeAcceptsSet = acceptSet;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          switch (call.method) {
            case 'autoStartSupported':
              return nativeSupported;
            case 'getAutoStart':
              return nativeEnabled;
            case 'setAutoStart':
              // 受理了就落到「系统」里，与原生写注册表同义。
              if (nativeAcceptsSet) nativeEnabled = call.arguments as bool;
              return nativeAcceptsSet;
            default:
              return null;
          }
        });
  }

  setUp(() {
    calls = <MethodCall>[];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    WindowControls.onAutoStartChanged = null;
  });

  AutoStartController controllerFor(AppState state) {
    final controller = AutoStartController(state: state);
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('后端可用时：问原生要能力与状态，并把镜像校准到系统的事实', (
    WidgetTester tester,
  ) async {
    installNative(supported: true, enabled: true);
    final state = AppState();
    addTearDown(state.dispose);

    // 存档里是「关」（默认值），而系统里其实是「开」——用户可能是在
    // 「任务管理器 → 启动」里打开的，或者上次切换后就一直是开的。
    expect(state.settings.autoRunAtStartup, isFalse);

    final controller = controllerFor(state);
    expect(controller.resolved, isFalse, reason: '还没问过原生时不能假装知道');
    await controller.refresh();

    expect(controller.resolved, isTrue);
    expect(controller.supported, isTrue);
    expect(
      controller.enabled,
      isTrue,
      reason: '系统是事实来源：回读到「开」就必须把存档里的镜像改过来',
    );
    expect(
      calls.map((MethodCall c) => c.method).toList(),
      containsAll(<String>['autoStartSupported', 'getAutoStart']),
    );
  }, variant: onWindows);

  testWidgets('后端不可用时 supported 为假，界面据此不渲染这一行', (
    WidgetTester tester,
  ) async {
    installNative(supported: false);
    final state = AppState();
    addTearDown(state.dispose);

    final controller = controllerFor(state);
    await controller.refresh();

    expect(controller.resolved, isTrue);
    expect(controller.supported, isFalse);
  }, variant: onWindows);

  // 用 `test` 而不是 `testWidgets`：`testWidgets` 跑在 FakeAsync 上，一条
  // 「通道没有处理器」的 invokeMethod 在那种环境里不会以 MissingPluginException
  // 收场，而是**永远不完成**——表现为用例挂死（超时），而不是干净地失败。
  // 这条用例本来也不需要 pump 任何界面。
  test('原生侧不存在（通道不可用）时按不支持处理，不抛异常', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = AppState();
      addTearDown(state.dispose);
      final controller = AutoStartController(
        state: state,
        service: AutoStartService(
          channel: const MethodChannel('com.xvpn.xvpn/no-such-native-side'),
        ),
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.supported, isFalse);
      expect(controller.resolved, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('拨开关：先落到系统，再按回读结果校准；被拒绝时回到系统的真实状态', (
    WidgetTester tester,
  ) async {
    installNative(supported: true, enabled: false);
    final state = AppState();
    addTearDown(state.dispose);
    final controller = controllerFor(state);
    await controller.refresh();

    await controller.setEnabled(true);
    expect(controller.enabled, isTrue);
    expect(
      calls.where((MethodCall c) => c.method == 'setAutoStart').last.arguments,
      isTrue,
    );

    // 系统拒绝（策略限制、用户在系统设置里关掉了）。替身改成回读为「关」。
    installNative(supported: true, enabled: false, acceptSet: false);
    await controller.setEnabled(true);
    expect(
      controller.enabled,
      isFalse,
      reason: '请求没被受理时必须回到系统里的真实状态，而不是停在用户拨到的位置',
    );
  }, variant: onWindows);

  testWidgets('原生改了状态（托盘菜单）时镜像跟上', (WidgetTester tester) async {
    installNative(supported: true, enabled: false);
    final state = AppState();
    addTearDown(state.dispose);
    final controller = controllerFor(state);

    controller.onNativeChanged(true);
    expect(controller.enabled, isTrue);

    controller.onNativeChanged(false);
    expect(controller.enabled, isFalse);
  }, variant: onWindows);

  testWidgets('托盘载荷带上 autoStart 两个键；未问过原生时都不出现', (
    WidgetTester tester,
  ) async {
    installNative(supported: true, enabled: true);
    final state = AppState();
    addTearDown(state.dispose);
    final center = UpdateCenter(
      check: () async => const UpdateNotAvailable(
        currentVersion: '1.0.0',
        latestVersion: '1.0.0',
      ),
    );
    addTearDown(center.dispose);
    final controller = controllerFor(state);

    // 还没问过原生：不能把「不知道」说成「没开」，因此两个键都不出现，
    // 原生据此把菜单项灰掉。
    final tray = SystemTray(
      state: state,
      updateCenter: center,
      autoStart: controller,
    );
    addTearDown(tray.dispose);
    expect(tray.payload().containsKey('autoStart'), isFalse);
    expect(tray.payload().containsKey('autoStartSupported'), isFalse);

    await controller.refresh();
    expect(tray.payload()['autoStartSupported'], isTrue);
    expect(tray.payload()['autoStart'], isTrue);
  }, variant: onWindows);

  testWidgets('后端不支持时载荷只说「不支持」，不说状态', (WidgetTester tester) async {
    installNative(supported: false);
    final state = AppState();
    addTearDown(state.dispose);
    final center = UpdateCenter(
      check: () async => const UpdateNotAvailable(
        currentVersion: '1.0.0',
        latestVersion: '1.0.0',
      ),
    );
    addTearDown(center.dispose);
    final controller = controllerFor(state);
    await controller.refresh();

    final tray = SystemTray(
      state: state,
      updateCenter: center,
      autoStart: controller,
    );
    addTearDown(tray.dispose);

    expect(tray.payload()['autoStartSupported'], isFalse);
    expect(
      tray.payload().containsKey('autoStart'),
      isFalse,
      reason: '后端都没有，状态无从谈起；报一个「没开」会让界面显示一个假的结论',
    );
  }, variant: onWindows);

  testWidgets('设置页：支持时显示开关，拨动会写进设置并落到系统', (WidgetTester tester) async {
    // 设置页在 800x600 的默认测试窗口下必然超出屏幕，开关落在可视区之外点不到。
    // 放高窗口，避免用 scrollUntilVisible 那样「测试里比用户多点几步」的写法。
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    installNative(supported: true, enabled: false);
    final state = AppState();
    addTearDown(state.dispose);
    final controller = controllerFor(state);
    await controller.refresh();
    final theme = ThemeController();
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: SettingsScreen(
            state: state,
            compact: false,
            theme: theme,
            autoStart: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('随系统启动'), findsOneWidget);

    // 按 Key 定位而不是「最后一个 XvSwitch」：卡片顺序一变，按下标取的写法
    // 会悄悄指到另一个开关上，而用例仍然「通过」。
    final toggle = find.byKey(SettingsScreen.autoStartSwitchKey);
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(state.settings.autoRunAtStartup, isTrue);
    expect(
      calls.where((MethodCall c) => c.method == 'setAutoStart').last.arguments,
      isTrue,
    );
  }, variant: onWindows);

  testWidgets('设置页：后端不支持时不显示这一行', (WidgetTester tester) async {
    installNative(supported: false);
    final state = AppState();
    addTearDown(state.dispose);
    final controller = controllerFor(state);
    await controller.refresh();
    final theme = ThemeController();
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: SettingsScreen(
            state: state,
            compact: false,
            theme: theme,
            autoStart: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('导入配置后自动连接'), findsOneWidget);
    expect(
      find.text('随系统启动'),
      findsNothing,
      reason: '拨一个不会有任何效果的开关比没有这个开关更糟',
    );
  }, variant: onWindows);

  testWidgets('没有控制器时设置页照常渲染（测试与移动端）', (WidgetTester tester) async {
    installNative(supported: true);
    final state = AppState();
    addTearDown(state.dispose);
    final theme = ThemeController();
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: SettingsScreen(state: state, compact: true, theme: theme),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('启动'), findsOneWidget);
    expect(find.text('随系统启动'), findsNothing);
  }, variant: onWindows);

  test('WindowControls 收到 autoStartChanged 会转给注册的回调', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      bool? received;
      WindowControls.onAutoStartChanged = (bool value) => received = value;
      // 走 Windows 分支才有平台通道。要装替身是因为
      // [WindowControls.listen] 末尾会同步问一次 isMaximized——一条没有应答的
      // invokeMethod 会让这个 Future 永远不完成，用例挂死而不是失败。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return call.method == 'isMaximized' ? false : null;
          });

      await WindowControls.listen();

      // 模拟原生推来的一条方法调用（与 window_quit_test 同一套写法）。
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('autoStartChanged', true),
            ),
            (ByteData? _) {},
          );
      await Future<void>.delayed(Duration.zero);

      expect(received, isTrue);
      expect(
        calls.map((MethodCall call) => call.method),
        contains('isMaximized'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('设置项落盘并恢复', () async {
    final dir = Directory.systemTemp.createTempSync('xvpn-autostart-test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final store = AppStore(dir);
    final state = AppState(store: store);
    addTearDown(state.dispose);
    expect(state.settings.autoRunAtStartup, isFalse, reason: '默认必须是关');

    state.updateSettings(state.settings.copyWith(autoRunAtStartup: true));

    final restored = AppState(store: AppStore(dir));
    addTearDown(restored.dispose);
    expect(restored.settings.autoRunAtStartup, isTrue);
  });
}
