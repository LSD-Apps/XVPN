import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';

/// 这一轮界面精简后的几条结构性断言。
///
/// 都是「删掉了什么」和「宽度用没用上」，用截图核对成本高且不可回归，
/// 因此写成断言。
void main() {
  Future<void> pumpShell(
    WidgetTester tester,
    AppState state, {
    required TargetPlatform platform,
    required Size size,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: XvShell(state: state, theme: ThemeController()),
      ),
    );
    await tester.pumpAndSettle();
  }

  void reset() => debugDefaultTargetPlatformOverride = null;

  testWidgets('连接页不再有顶部标题、副标题与状态标签', (WidgetTester tester) async {
    // 三者在同一个位置重复了圆环已经表达的信息，而且占掉首屏最宝贵的高度。
    final state = AppState();
    addTearDown(state.dispose);
    await pumpShell(
      tester,
      state,
      platform: TargetPlatform.windows,
      size: const Size(1400, 1000),
    );

    // 「连接」只应剩侧边栏的那一个导航项；页面里那个标题已移除
    // （它与侧边栏当前项重复，而且占掉首屏高度）。
    expect(find.text('连接'), findsOneWidget, reason: '页标题已移除，只剩侧边栏导航项');
    expect(
      find.textContaining('分流规则由内置规则库自动应用'),
      findsNothing,
      reason: '副标题是泛泛的说明，不带来新信息',
    );
    // 状态标签（胶囊）也一并移除；状态由圆环表达。
    expect(find.text('未连接'), findsNothing, reason: '状态由圆环表达，页头再挂一个标签是重复');
    reset();
  });

  testWidgets('分流列表不再有「延迟」列', (WidgetTester tester) async {
    // 那一列对每一行都是同一个数（整条隧道的往返延迟），挂在每一行上会让人
    // 以为在比较不同站点的快慢。测不了每目标延迟，就不要这一列。
    final state = AppState();
    addTearDown(state.dispose);
    await pumpShell(
      tester,
      state,
      platform: TargetPlatform.windows,
      size: const Size(1400, 1000),
    );
    state.onSplitRecord(
      SplitRecord(
        time: DateTime(2026, 9, 12, 10),
        target: 'www.example.com',
        kind: RouteKind.proxy,
        rule: '默认规则',
        outbound: 'vpn',
      ),
    );
    await tester.pump();

    await tester.tap(find.text('分流记录'));
    await tester.pumpAndSettle();

    expect(find.text('延迟'), findsNothing, reason: '延迟对每个目标都一样，不该占一列');
    // 保留下来的量化列仍在。
    expect(find.text('流量 ↓/↑'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    reset();
  });
}
