import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/links.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/title_bar.dart';

/// 标题栏的窗口按钮必须真的出现在最右侧。
///
/// 这一条是补上一个**没有任何测试覆盖**的区域：自绘标题栏的按钮。
/// 实测在桌面上右侧一片空白，而我把 `_WindowButtons` 从有状态改成无状态时
/// 并没有测试能发现这件事。
void main() {
  testWidgets('标题栏右侧渲染出最小化 / 最大化 / 关闭三个按钮', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              XvTitleBar(theme: ThemeController(), state: state),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // 三个按钮各自带 tooltip，用 tooltip 文案定位最直接。
    for (final label in <String>['最小化', '最大化', '关闭']) {
      expect(
        find.byTooltip(label),
        findsOneWidget,
        reason: '标题栏缺少「$label」按钮',
      );
    }

    // 它们必须在窗口右侧：这是标题栏按钮的位置约定。
    final close = tester.getRect(find.byTooltip('关闭'));
    debugPrint('关闭按钮位置: $close  视口宽=${tester.view.physicalSize.width}');
    expect(
      close.right,
      greaterThan(1400 - 160),
      reason: '窗口按钮应贴在标题栏最右侧',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('标题栏有 GitHub 入口，且排在窗口按钮左侧', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              XvTitleBar(theme: ThemeController(), state: state),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final github = find.byTooltip('在 GitHub 上查看源码');
    expect(github, findsOneWidget, reason: '标题栏应有 GitHub 入口');

    // 它必须在窗口按钮左侧：分割线右侧才是系统窗口控制，
    // GitHub 属于应用自身的功能，混进窗口按钮组会让人误以为是系统按钮。
    expect(
      tester.getCenter(github).dx,
      lessThan(tester.getCenter(find.byTooltip('关闭')).dx),
      reason: 'GitHub 入口不能混进右侧的窗口按钮组',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('点击 GitHub 按钮会打开仓库地址，且不触发窗口拖动', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 拖动由原生通道处理；记录一下，确保点 GitHub 不会被当成拖标题栏。
    const windowChannel = MethodChannel('com.xvpn.xvpn/platform');
    final nativeCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (MethodCall call) async {
        nativeCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        null,
      ),
    );

    final state = AppState();
    addTearDown(state.dispose);

    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              XvTitleBar(
                theme: ThemeController(),
                state: state,
                // 真实的 url_launcher 在测试环境里没有浏览器可用，注入记录器
                // 才能断言「点了哪个地址」。
                openExternalUrl: (Uri uri) async {
                  opened.add(uri);
                  return true;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('在 GitHub 上查看源码'));
    await tester.pump();

    expect(
      opened,
      <Uri>[Uri.parse(kRepoUrl)],
      reason: '应尝试打开常量里的仓库地址，而不是别处',
    );
    expect(
      nativeCalls,
      isNot(contains('startDragging')),
      reason: 'GitHub 按钮必须消费掉点击，不能让标题栏开始拖动',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('打开仓库失败时只提示，不把异常抛到界面', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              XvTitleBar(
                theme: ThemeController(),
                state: state,
                openExternalUrl: (Uri uri) async =>
                    throw StateError('没有可用的浏览器'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // 抛出的异常若逃逸，flutter_test 会直接判这个用例失败——能走到下面的
    // 断言，本身就说明按钮接住了它。
    await tester.tap(find.byTooltip('在 GitHub 上查看源码'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(kRepoUrl),
      findsOneWidget,
      reason: '打不开浏览器时应把地址告诉用户，让他能手动访问',
    );

    debugDefaultTargetPlatformOverride = null;
  });
}
