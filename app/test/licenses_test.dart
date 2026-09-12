import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/licenses.dart';
import 'package:xvpn/version.dart';

/// 应用内「开源许可」界面必须能读到随包附带的许可全文。
///
/// 这条测试针对的是一个具体的失败模式：许可文件「被塞进了安装包」但用户读不到。
/// 之前的合规审计确认 `LICENSE` / `NOTICE.md` 确实随产物分发，却没有应用内
/// 入口。这里同时验证：
///   1. 三个 asset 真的能被 `rootBundle` 读到（副本没漏进 pubspec / 与根文件一致）；
///   2. 由这些 asset 构造出的许可条目里确实有 GPL 正文与第三方声明；
///   3. 许可页本身能打开。
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

  testWidgets('showLicensePage 能打开许可页', (WidgetTester tester) async {
    registerBundledLicenses();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'XVPN',
                  applicationVersion: appVersion,
                ),
                child: const Text('打开许可'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开许可'));
    // 不用 pumpAndSettle：许可页会异步聚合 Flutter 依赖与 NOTICES，settle 可能
    // 一直等不到静止。这里只验证路由与页面已经建立。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
