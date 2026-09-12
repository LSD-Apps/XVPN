import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
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
}
