import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/licenses.dart';
import 'package:xvpn/core/links.dart';
import 'package:xvpn/screens/licenses_dialog.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/common.dart';

/// 应用内「开源许可」界面必须能读到随包附带的许可全文，并按内容本身的格式
/// 渲染——`NOTICE.md` / `THIRD-PARTY-NOTICES.md` 是 Markdown，`LICENSE` 是
/// GPL-3.0 的纯文本。
///
/// 这条测试针对的是一个具体的失败模式：许可文件「被塞进了安装包」但用户读不到，
/// 或者读到了却是一堆字面量标记（`## 一、…`、`| a | b |`）。这里同时验证：
///   1. 三个 asset 真的能被 `rootBundle` 读到（副本没漏进 pubspec / 与根文件一致）；
///   2. 由这些 asset 构造出的许可条目里确实有 GPL 正文与第三方声明；
///   3. 自绘的许可视图能列出条目、点开全文、筛选与返回；
///   4. Markdown 条目渲染成标题 / 真实表格 / 链接，而不是字面量标记；纯文本
///      （GPL）仍按段落渲染，尖括号占位不会被 Markdown 解析吞掉；
///   5. 347 KB 的内核依赖声明能限时打开，并且只构建视口附近的分段。
///
/// 关于 `runAsync`：`rootBundle.loadString` 是真实异步 I/O，而 `testWidgets`
/// 的测试体跑在 `FakeAsync` 下——直接 await 会一直等不到（微任务不被冲刷）。
/// 因此真实 I/O 一律放进 `tester.runAsync`。生产代码没有 FakeAsync，不受影响。
void main() {
  /// 一份结构完整的小 Markdown 夹具：标题、粗体、行内代码、GFM 表格与链接。
  /// 域名用 RFC 2606 保留的 `example.net`，不指向任何真实站点。
  LicenseEntryWithLineBreaks markdownSample() =>
      const LicenseEntryWithLineBreaks(<String>[
        'Test · Markdown 示例',
      ], '''
# 一级标题

普通段落，含 **加粗** 与 `内联代码`。

## 依赖表

| 名称 | 许可 |
| --- | --- |
| alpha | MIT |
| beta | BSD-3-Clause |

### 链接

[示例站点](https://example.net/xvpn)
''');

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

  /// 收集屏幕上全部已构建文字（`Text`、含 `Text.rich`，以及裸 `RichText`）。
  ///
  /// 为什么需要它：Markdown 渲染出来的标题/段落是 `Text.rich`，要断言「字面量
  /// 标记没有漏出来」（`## `、`**`、`| ---`）就得把它们拼起来整体看，而不是
  /// 逐个 `find.text` 猜。
  String renderedText(WidgetTester tester) {
    final buffer = StringBuffer();
    for (final Element element in find.byType(Text).evaluate()) {
      final Text text = element.widget as Text;
      buffer.writeln(text.data ?? text.textSpan?.toPlainText() ?? '');
    }
    for (final Element element in find.byType(RichText).evaluate()) {
      buffer.writeln((element.widget as RichText).text.toPlainText());
    }
    return buffer.toString();
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
    ExternalUrlLauncher? openExternalUrl,
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
          body: LicensesDialog(
            loadEntries: () async => entries,
            // 默认注入一个不弹浏览器的实现：真实 `launchInBrowser` 在测试里
            // 没有平台通道，会走到「打开失败」分支。
            openExternalUrl: openExternalUrl ?? (Uri uri) async => true,
          ),
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

  testWidgets('纯文本条目（GPL）仍按段落渲染，返回回到列表', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);

    await tester.tap(find.textContaining('本项目许可'));
    await tester.pumpAndSettle();

    // 正文必须真的在，且仍是可选中复制的段落（GPL 的 ASCII 版式不能交给
    // Markdown 解析——`<name of author>` 会被当标签吞掉）。
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsOneWidget);
    expect(find.byType(LicenseParagraphLine), findsWidgets);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(XvSearchField), findsOneWidget);
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsNothing);
  });

  testWidgets('Markdown 条目渲染成标题/表格，不再出现字面量标记', (
    WidgetTester tester,
  ) async {
    await pumpLicenses(
      tester,
      entries: <LicenseEntry>[markdownSample()],
      palette: XvPalette.dark,
    );

    await tester.tap(find.textContaining('Markdown 示例'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final rendered = renderedText(tester);
    // 标题的 `#` 前缀、粗体的 `**`、表格的竖线/分隔行都不能以字面量出现。
    expect(rendered, isNot(contains('## ')), reason: '标题不应带 ## 前缀');
    expect(rendered, isNot(contains('### ')), reason: '标题不应带 ### 前缀');
    expect(rendered, isNot(contains('# 一级标题')));
    expect(rendered, isNot(contains('**')), reason: '粗体不应带 ** 标记');
    expect(rendered, isNot(contains('| ---')), reason: '表格分隔行不应原样出现');
    expect(rendered, isNot(contains('| 名称 |')), reason: '表格不应是竖线文本');
    // 标题文字本身要在（去掉 # 之后）。
    expect(rendered, contains('一级标题'));
    expect(rendered, contains('依赖表'));
    expect(rendered, contains('加粗'));

    // GFM 表格必须渲染成真正的 Table，而不是一行行竖线文本。
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(MarkdownBody), findsWidgets);
    // 选择能力不能丢：整段仍由 SelectionArea 包着（用户要复制 GPL 正文）。
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('真实的 NOTICE.md 条目按 Markdown 渲染', (WidgetTester tester) async {
    final entries = await loadRegistryEntries(tester);
    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);

    await tester.tap(find.textContaining('第三方组件与许可'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final rendered = renderedText(tester);
    expect(rendered, contains('第三方组件与许可'));
    expect(rendered, contains('零、本项目的授权声明'));
    expect(rendered, isNot(contains('## ')), reason: '标题不应带 ## 前缀');
    expect(rendered, isNot(contains('**')), reason: '粗体不应带 ** 标记');
  });

  testWidgets('正文里的链接交给应用自己的打开实现', (WidgetTester tester) async {
    final opened = <Uri>[];
    await pumpLicenses(
      tester,
      entries: <LicenseEntry>[markdownSample()],
      palette: XvPalette.dark,
      openExternalUrl: (Uri uri) async {
        opened.add(uri);
        return true;
      },
    );

    await tester.tap(find.textContaining('Markdown 示例'));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('示例站点'));
    await tester.pump();

    expect(opened, <Uri>[Uri.parse('https://example.net/xvpn')]);
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

  testWidgets('347 KB 的内核依赖条目：真实表格渲染成 Table，懒建且限时打开', (
    WidgetTester tester,
  ) async {
    final entries = await loadRegistryEntries(tester);

    final huge = entries.firstWhere(
      (LicenseEntry e) => e.packages.any(
        (String p) => p.contains('内核静态依赖'),
      ),
    );
    // 真实文档按顶层标题能切成多少段——用作「只建了视口附近」的对照。
    final raw = (huge as LicenseEntryWithLineBreaks).text;
    final totalSections = splitMarkdownSections(raw).length;
    expect(
      totalSections,
      greaterThan(50),
      reason: '内核依赖声明应当确实能被切成很多段（实际 $totalSections）',
    );

    await pumpLicenses(tester, entries: entries, palette: XvPalette.dark);
    final stopwatch = Stopwatch()..start();
    await tester.tap(find.textContaining('内核静态依赖'));
    await tester.pumpAndSettle();
    stopwatch.stop();
    // 实测值：见本用例输出。
    debugPrint('347 KB 条目打开至稳定：${stopwatch.elapsedMilliseconds} ms');

    expect(tester.takeException(), isNull, reason: '打开大条目不能抛异常');
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(2000),
      reason: '整份 Markdown 一次性渲染会卡住首帧，必须保持在预算内',
    );
    // 真实的 GFM 表格（`## 依赖总览`）必须渲染成真正的 Table。
    expect(find.byType(Table), findsWidgets);
    final rendered = renderedText(tester);
    expect(rendered, isNot(contains('| ---')), reason: '表格分隔行不应以字面量出现');

    // 懒建：实际构建的分段数应远小于总段数。
    final built = find.byType(MarkdownBody).evaluate().length;
    expect(built, greaterThan(0), reason: '至少要把可视范围内的正文建出来');
    expect(
      built,
      lessThan(totalSections),
      reason: 'ListView.builder 必须懒建（实际建出 $built / $totalSections 段）',
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

  testWidgets('Markdown 条目在暗色/亮色/窄屏下都不溢出', (WidgetTester tester) async {
    for (final palette in <XvPalette>[XvPalette.dark, XvPalette.light]) {
      await pumpLicenses(
        tester,
        entries: <LicenseEntry>[markdownSample()],
        palette: palette,
        size: const Size(1000, 760),
      );
      await tester.tap(find.textContaining('Markdown 示例'));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Markdown 全文在 ${palette.bg} 下不应溢出',
      );
    }

    await pumpLicenses(
      tester,
      entries: <LicenseEntry>[markdownSample()],
      palette: XvPalette.dark,
      size: const Size(390, 780),
    );
    await tester.tap(find.textContaining('Markdown 示例'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '窄屏下 Markdown 条目不应溢出');
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
