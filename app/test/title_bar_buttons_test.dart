import 'dart:ui' as ui;

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

  group('GitHub 入口的图标', () {
    /// 路径由脚本从 SVG path 数据换算而来（含椭圆弧 → 三次贝塞尔）。
    /// 换算写错时图标会歪掉，而这一点在代码上完全看不出来，所以这里断言形状。
    test('标记的路径覆盖 16×16 视口，且落在视口内', () {
      final bounds = buildGitHubMarkPath().getBounds();

      // 贝塞尔的控制点可能略微超出真实曲线，因此给一点余量。
      expect(bounds.left, closeTo(0, 0.6));
      expect(bounds.top, closeTo(0, 0.6));
      expect(bounds.right, closeTo(16, 0.6));
      expect(bounds.bottom, closeTo(16, 0.9));
    });

    test('填充占比在合理范围（不至于画出空框，也不至于糊成一团）', () async {
      // 官方标记在 16×16 视口里约占 45%：它并不是一个实心圆，猫的两臂与身体之间
      // 本身就是负空间。这条断言真正防的是「路径转写出错」——比如命令漏读导致
      // 只剩一小块，或全部塌成一个方块。
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const n = 64;
      canvas.scale(n / 16.0);
      canvas.drawPath(buildGitHubMarkPath(), Paint()..color = const Color(0xFFFFFFFF));
      final image = await recorder.endRecording().toImage(n, n);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final data = bytes.buffer.asUint8List();
      var filled = 0;
      for (var i = 3; i < data.length; i += 4) {
        if (data[i] > 128) filled++;
      }
      final percent = filled * 100 / (n * n);
      // 与 Chromium 渲染同一份官方 SVG 的实测值（45.1%）对齐，给足余量。
      expect(percent, greaterThan(30), reason: '填充太少，路径多半转错了');
      expect(percent, lessThan(65), reason: '填充太多，路径多半转错了');
    });

    test('左右对称（椭圆弧换算写错时这条会先失败）', () {
      final path = buildGitHubMarkPath();
      const step = 0.05;

      // 逐行扫出填充区间的左右边界，比较二者到中线的距离。
      for (double y = 3; y <= 12; y += 1) {
        double? left;
        double? right;
        for (double x = 0; x <= 8; x += step) {
          if (path.contains(Offset(x, y))) {
            left = x;
            break;
          }
        }
        for (double x = 16; x >= 8; x -= step) {
          if (path.contains(Offset(x, y))) {
            right = x;
            break;
          }
        }
        expect(left, isNotNull, reason: 'y=$y 这一行应该有填充');
        expect(right, isNotNull, reason: 'y=$y 这一行应该有填充');
        expect(
          left! - (16 - right!),
          closeTo(0, 0.35),
          reason: 'y=$y 处左右边界到中线距离应一致，否则图标是歪的',
        );
      }
    });

    testWidgets('标题栏用自绘标记而不是通用图标', (WidgetTester tester) async {
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

      final entry = find.byTooltip('在 GitHub 上查看源码');
      expect(entry, findsOneWidget);
      expect(
        find.descendant(of: entry, matching: find.byType(CustomPaint)),
        findsWidgets,
        reason: 'GitHub 入口应绘制官方标记，而不是一个通用图标',
      );

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
