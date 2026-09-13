import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/licenses.dart';
import 'package:xvpn/screens/licenses_dialog.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/common.dart';

/// 应用内「开源许可」界面必须能读到随包附带的许可全文。
///
/// 这条测试针对的是一个具体的失败模式：许可文件「被塞进了安装包」但用户读不到。
/// 之前的合规审计确认 `LICENSE` / `NOTICE.md` 确实随产物分发，却没有应用内
/// 入口。这里同时验证：
///   1. 三个 asset 真的能被 `rootBundle` 读到（副本没漏进 pubspec / 与根文件一致）；
///   2. 由这些 asset 构造出的许可条目里确实有 GPL 正文与第三方声明；
///   3. 自绘的许可视图能列出条目、点开全文、筛选与返回，并且能安全打开
///      347 KB 的内核依赖声明（懒建，不一次性铺完）。
///
/// 关于 `runAsync`：`rootBundle.loadString` 是真实异步 I/O，而 `testWidgets`
/// 的测试体跑在 `FakeAsync` 下——直接 await 会一直等不到（微任务不被冲刷）。
/// 因此真实 I/O 一律放进 `tester.runAsync`。生产代码没有 FakeAsync，不受影响。
void main() {
  testWidgets('assets/legal 下的许可文件可被应用读取', (WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final asset in bundledLicenseAssets) {
        final text = await rootBundle.loadString(asset.asset);
        expect(text, isNotEmpty, reason: '${asset.asset} 读不到或为空');
      }
      final gpl = await rootBundle.loadString('assets/legal/LICENSE');
      expect(gpl, contains('GNU GENERAL PUBLIC LICENSE'));
      expect(gpl, contains('Version 3'));
      // 第三方声明（尤其是内核静态依赖）必须真的在包里，而不只是被注册。
      final thirdParty = await rootBundle.loadString(
        'assets/legal/THIRD-PARTY-NOTICES.md',
      );
      expect(thirdParty, contains('BSD-3-Clause'));
      expect(thirdParty, contains('Apache-2.0'));
    });
  });

  testWidgets('许可条目里能取到 GPL 全文与第三方声明', (WidgetTester tester) async {
    final entries = await tester.runAsync(loadBundledLicenseEntries);
    expect(entries, isNotNull);
    final all = entries!;

    final gplEntries = all.where(
      (LicenseEntry e) => e.packages.contains('XVPN · 本项目许可（GPL-3.0-or-later）'),
    );
    expect(gplEntries, isNotEmpty, reason: '许可页应包含本项目自身条目');
    final gplText = gplEntries.first.paragraphs
        .map((LicenseParagraph p) => p.text)
        .join('\n');
    expect(gplText, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(gplText, contains('Version 3'));

    // 第三方条目也要在，而不是只有 Flutter 自动生成的依赖许可。
    expect(
      all.any(
        (LicenseEntry e) =>
            e.packages.contains('XVPN · 第三方组件与许可') ||
            e.packages.contains('XVPN · 内核静态依赖（sing-box 及其 Go 依赖）'),
      ),
      isTrue,
      reason: '第三方声明必须在许可页可见',
    );
  });

  /// 读出 `LicenseRegistry` 里的全部条目。
  ///
  /// 走的是生产路径：`registerBundledLicenses()` 注册本项目三个 asset，注册表
  /// 被遍历时它们才真正读文件。测试环境里 Flutter 自己的 `NOTICES.Z` 注册器
  /// 被刻意关掉（`flutter_test` 的 `initLicenses` 是空实现），因此这里读到的
  /// 就是本项目那三条。
  Future<List<LicenseEntry>> loadRegistryEntries(WidgetTester tester) async {
    registerBundledLicenses();
    final entries = await tester.runAsync(
      () => LicenseRegistry.licenses.toList(),
    );
    return entries ?? const <LicenseEntry>[];
  }

  /// 渲染许可视图本体并冲刷注入的 loader。
  ///
  /// 直接以 `body` 的形式渲染 [LicensesDialog]：这里关心的是列表/全文两级切换，
  /// 入口本身由下面的用例单独覆盖。条目通过 `loadEntries` 注入，从而避开
  /// `FakeAsync` 下的真实 I/O。
  Future<void> pumpLicenses(
    WidgetTester tester, {
    required List<LicenseEntry> entries,
    required XvPalette palette,
    Size size = const Size(1000, 760),
  }) async {
    // 调色板是全局变量，用例之间必须复位，否则会给后续用例留下亮色。
    applyPalette(palette);
    addTearDown(() => applyPalette(XvPalette.dark));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(palette),
        home: Scaffold(
          backgroundColor: XV.bg,
          body: LicensesDialog(loadEntries: () async => entries),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('新的许可视图列出本项目自己的条目', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);

    // 本项目三条都必须出现，而不是只剩 Flutter 聚合来的依赖许可。
    expect(find.textContaining('本项目许可'), findsOneWidget);
    expect(find.textContaining('第三方组件与许可'), findsOneWidget);
    expect(find.textContaining('内核静态依赖'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点开条目能读到全文，返回回到列表', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);

    await tester.tap(find.textContaining('本项目许可'));
    await tester.pumpAndSettle();

    // 正文必须真的在，且是可选中复制的段落。
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsOneWidget);
    expect(find.byType(LicenseParagraphLine), findsWidgets);
    expect(find.byType(SelectionArea), findsOneWidget);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(XvSearchField), findsOneWidget);
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsNothing);
  });

  testWidgets('搜索框按组件名筛选条目', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);

    // 只有一个输入框（搜索），直接输入即可。
    await tester.enterText(find.byType(TextField), '第三方');
    await tester.pumpAndSettle();

    expect(find.textContaining('第三方组件与许可'), findsOneWidget);
    expect(find.textContaining('本项目许可'), findsNothing);
    expect(find.textContaining('内核静态依赖'), findsNothing);

    // 清除后恢复完整列表。
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本项目许可'), findsOneWidget);
    expect(find.textContaining('内核静态依赖'), findsOneWidget);
  });

  testWidgets('347 KB 的内核依赖条目能安全打开，且只建可视范围内的段落', (
    WidgetTester tester,
  ) async {
    final entries = await loadRegistryEntries(tester);

    // 先解析一次拿到总段数，作为「是否懒建」的对照。
    final huge = entries.firstWhere(
      (LicenseEntry e) => e.packages.any(
        (String p) => p.contains('内核静态依赖'),
      ),
    );
    final parsed = await tester.runAsync(() async => huge.paragraphs.toList());
    expect(parsed, isNotNull);
    final total = parsed!.length;
    // 这条断言保证这份夹具确实够大：小于 100 段的话下面的「懒建」就失去意义。
    expect(total, greaterThan(100), reason: '内核依赖声明应当确实是「大条目」');

    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);
    await tester.tap(find.textContaining('内核静态依赖'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '打开大条目不能抛异常');
    final built = find.byType(LicenseParagraphLine).evaluate().length;
    expect(built, greaterThan(0), reason: '至少要把可视范围内的正文建出来');
    expect(
      built,
      lessThan(total),
      reason: 'ListView.builder 必须懒建：实际建出的段落数应远小于总段数（$total）',
    );
  });

  testWidgets('暗色与亮色两套调色板下都不溢出、不抛异常', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    for (final palette in <XvPalette>[XvPalette.dark, XvPalette.light]) {
      await pumpLicenses(tester, entries: entries, palette: palette, size: const Size(1000, 760));
      expect(tester.takeException(), isNull, reason: '列表在 ${palette.bg} 下不应溢出');

      await tester.tap(find.textContaining('本项目许可'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '全文在 ${palette.bg} 下不应溢出');
    }
  });

  testWidgets('窄屏整屏铺开，返回与关闭都可用', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    await pumpLicenses(
      tester,
      entries: entries,
      palette: XvPalette.dark,
      size: const Size(390, 780),
    );

    expect(find.byType(XvSearchField), findsOneWidget);
    await tester.tap(find.textContaining('本项目许可'));
    await tester.pumpAndSettle();

    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(XvSearchField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('条目读取失败时给出说明而不是崩溃', (WidgetTester tester) async {
    applyPalette(XvPalette.dark);
    addTearDown(() => applyPalette(XvPalette.dark));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: LicensesDialog(
            loadEntries: () async => throw StateError('asset 缺失'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('读取许可条目失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('入口打开的是自绘许可视图，而不是 Material 的许可页', (
    WidgetTester tester,
  ) async {
    registerBundledLicenses();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: XvButton(
                label: '查看',
                onPressed: () => showLicensesDialog(context),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('查看'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(LicensesDialog), findsOneWidget);
    expect(find.byType(LicensePage), findsNothing);
  });
}
