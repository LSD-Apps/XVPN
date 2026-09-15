import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/main.dart';
import 'package:xvpn/screens/legal_notice_dialog.dart';
import 'package:xvpn/theme.dart';

void main() {
  testWidgets('法律声明弹窗渲染 Markdown 标题而不是字面量', (WidgetTester tester) async {
    const sample = '''
# 法律与使用声明

**本文不是法律意见。**

## 一、产品定位（最重要）

XVPN 是开源客户端工具。
''';
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    applyPalette(XvPalette.dark);
    addTearDown(() => applyPalette(XvPalette.dark));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          backgroundColor: XV.bg,
          body: LegalNoticeDialog(loadText: () async => sample),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('# 法律与使用声明'), findsNothing);
    expect(find.textContaining('不是法律意见'), findsOneWidget);
  });

  testWidgets('确认层挡住界面，点确认后消失', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    applyPalette(XvPalette.dark);
    addTearDown(() => applyPalette(XvPalette.dark));
    var acknowledged = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          backgroundColor: XV.bg,
          body: LegalAcceptanceGate(
            onAcknowledge: () => acknowledged = true,
            loadText: () async => '# 法律与使用声明\n\n全文。',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用前请确认'), findsOneWidget);
    expect(find.text('我已了解，继续'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);

    await tester.tap(find.text('阅读全文'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);

    await tester.tap(find.text('我已了解，继续'));
    await tester.pump();
    expect(acknowledged, isTrue);
  });

  testWidgets('全新安装的 XvpnApp 先出确认层', (WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('xvpn-legal-gate');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(XvpnApp(store: AppStore(dir)));
    await tester.pumpAndSettle();
    expect(find.text('我已了解，继续'), findsOneWidget);

    await tester.tap(find.text('我已了解，继续'));
    await tester.pumpAndSettle();
    expect(find.text('我已了解，继续'), findsNothing);
    expect(find.text('配置文件'), findsWidgets);
  });
}
