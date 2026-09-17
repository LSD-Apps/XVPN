import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/app_presets.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/auto_route_card.dart';
import 'package:xvpn/widgets/common.dart';

/// 「域名分流规则」卡片输入行**下方**那一块动作区的布局规范。
///
/// 这一块此前是四行同款灰色文字链接平铺在卡片底部（导出 / 导入 / 清理过期 /
/// 全部清除），既不符合这个项目自己写在 `rules_screen.dart` 里的规范（卡片级
/// 动作用 [XvButton]，[TapAction] 只用于列表项内部的逐条操作），也把**不可逆的
/// 「全部清除」和「导出规则包」做成了同一个样子**。
///
/// 这里锁的不是像素，而是几条能被证伪的规律。每一条都对应一个真实观察到的缺陷：
///
///   1. 两段动作各有标题，且**成对**出现——四个等权裸文字看不出谁和谁是一组；
///   2. 卡片级动作是真实按钮，破坏性的那个是 danger 变体——危险操作必须与
///      普通操作长得不同；
///   3. 「清理过期」的计数只数**可以被它删掉的**条目——旧标签数的是全部条目，
///      实测 1 条学习规则 + 4 条手工规则时会写「8 条中」；
///   4. 校验提示紧贴输入行——旧位置距离输入框 108px，中间隔着两个可点动作。
void main() {
  AppState newState() => AppState(
    coreFactory: (VpnCoreListener listener) =>
        SingBoxRunner(listener, probesEnabled: false),
  );

  /// 手机宽度（390）与足够高，让整张卡片都在视口内，免去滚动带来的不确定。
  Future<void> pumpCard(
    WidgetTester tester,
    AppState state, {
    bool compact = true,
  }) async {
    tester.view.physicalSize = Size(compact ? 390 : 1180, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          backgroundColor: XV.bg,
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: AutoRouteCard(state: state, compact: compact),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inCard(Finder matching) =>
      find.descendant(of: find.byType(AutoRouteCard), matching: matching);

  group('页脚动作区的分组与控件类型', () {
    testWidgets('两段各有标题', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      expect(inCard(find.text('规则包')), findsOneWidget);
      expect(inCard(find.text('批量清理')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('四个动作都是按钮，而不是裸文字链接', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      for (final label in <String>[
        '导出规则包',
        '导入规则包',
        '全部清除',
      ]) {
        expect(
          inCard(find.widgetWithText(XvButton, label)),
          findsOneWidget,
          reason: '「$label」是卡片级动作，必须是 XvButton',
        );
        expect(
          inCard(find.widgetWithText(TapAction, label)),
          findsNothing,
          reason: '「$label」不该退回成 TapAction（那是列表项内部逐条操作用的）',
        );
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('「全部清除」用 danger 变体，与其它动作明显不同', (
      WidgetTester tester,
    ) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      final danger = tester.widget<XvButton>(
        inCard(find.widgetWithText(XvButton, '全部清除')),
      );
      expect(
        danger.kind,
        XvButtonKind.danger,
        reason: '不可逆的批量删除必须与「导出规则包」这类普通动作在视觉上分开',
      );

      // 同组的「清理过期」与另一组的按钮都应是默认的次要按钮。
      for (final label in <String>['清理过期（0 条）', '导出规则包', '导入规则包']) {
        final button = tester.widget<XvButton>(
          inCard(find.widgetWithText(XvButton, label)),
        );
        expect(button.kind, XvButtonKind.secondary, reason: label);
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('成对的动作同行、等高、等宽（窄屏也不堆成两行）', (
      WidgetTester tester,
    ) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      Future<void> assertPair(String a, String b) async {
        final ra = tester.getRect(inCard(find.widgetWithText(XvButton, a)));
        final rb = tester.getRect(inCard(find.widgetWithText(XvButton, b)));
        expect(
          (ra.top - rb.top).abs(),
          lessThan(1),
          reason: '「$a」与「$b」是同一件事的两个方向，应并排',
        );
        expect(
          (ra.width - rb.width).abs(),
          lessThan(1),
          reason: '「$a」与「$b」等宽，不该给谁更大的位置',
        );
        expect(
          (ra.height - rb.height).abs(),
          lessThan(1),
          reason: '同一行的控件必须等高',
        );
      }

      await assertPair('导出规则包', '导入规则包');
      await assertPair('清理过期（0 条）', '全部清除');

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('「清理过期」的计数口径', () {
    testWidgets('只数程序学到的条目，不把手工指定的算进去', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      // 关掉默认启用的「直连白名单」预置：它也会往这张表里写条目，而本用例要
      // 精确控制条目总数，好让「计数写的不是总数」这个断言足够锋利。
      for (final preset in AppPresets.all) {
        state.setAppPresetEnabled(preset.id, false);
      }

      // 5 条手工指定 + 0 条程序学到。旧实现在这里会显示「清理过期（5 条中）」，
      // 而这个动作一条也删不掉。
      for (final domain in <String>[
        'a.example.com',
        'b.example.com',
        'c.example.com',
        'd.example.com',
        'e.example.com',
      ]) {
        state.setDomainPreference(domain, RoutePreference.forceProxy);
      }
      expect(state.autoRoute!.entries.length, 5);
      expect(
        state.autoRoute!.entries
            .where((AutoRouteEntry e) => e.source == RouteRuleSource.learned)
            .length,
        0,
      );

      await pumpCard(tester, state);

      expect(
        inCard(find.widgetWithText(XvButton, '清理过期（0 条）')),
        findsOneWidget,
        reason: '计数必须与动作的作用域一致：能删 0 条就写 0 条',
      );
      expect(
        inCard(find.textContaining('5 条')),
        findsNothing,
        reason: '全部条目数是 5，但其中可被清理的是 0——不能把 5 写进这个标签',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('没有可清理的条目时按钮禁用，而不是消失', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      state.setDomainPreference('only-user.example.com',
          RoutePreference.forceProxy);
      await pumpCard(tester, state);

      final button = tester.widget<XvButton>(
        inCard(find.widgetWithText(XvButton, '清理过期（0 条）')),
      );
      expect(button.onPressed, isNull, reason: '没事可做时应禁用');
      expect(
        inCard(find.widgetWithText(XvButton, '全部清除')).evaluate(),
        isNotEmpty,
        reason: '「全部清除」删的是所有规则（含手工的），仍然可用',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('校验提示的位置', () {
    testWidgets('提示紧贴输入行，中间不夹任何可点动作', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      // 空输入点「添加」→ 出提示。
      await tester.tap(inCard(find.widgetWithText(XvButton, '添加')));
      await tester.pumpAndSettle();

      final error = inCard(find.textContaining('请输入域名'));
      expect(error, findsOneWidget);

      final field = tester.getRect(inCard(find.byType(XvSearchField)));
      final errorRect = tester.getRect(error);
      expect(
        errorRect.top,
        greaterThan(field.bottom),
        reason: '提示应在输入行下方',
      );
      // 旧位置：提示在导出/导入两个动作之后，距输入框底边 108px。
      expect(
        errorRect.top - field.bottom,
        lessThan(24),
        reason: '提示必须紧贴输入行；远了就会脱离它要解释的那个控件',
      );

      // 中间不能夹着任何按钮。
      for (final label in <String>['导出规则包', '导入规则包']) {
        final r = tester.getRect(inCard(find.widgetWithText(XvButton, label)));
        expect(
          r.top,
          greaterThan(errorRect.top),
          reason: '「$label」不该夹在输入框与校验提示之间',
        );
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('输入框里打字即清除提示', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      await tester.tap(inCard(find.widgetWithText(XvButton, '添加')));
      await tester.pumpAndSettle();
      expect(inCard(find.textContaining('请输入域名')), findsOneWidget);

      await tester.enterText(inCard(find.byType(TextField)), 'example.com');
      await tester.pumpAndSettle();
      expect(
        inCard(find.textContaining('请输入域名')),
        findsNothing,
        reason: '用户开始修正时提示应立刻消失',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('回车即提交，与点「添加」等效', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      await pumpCard(tester, state);

      await tester.enterText(inCard(find.byType(TextField)), 'enter.example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        state.autoRoute!.match('enter.example.com'),
        isNotNull,
        reason: '键盘用户不该被迫去找按钮',
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
