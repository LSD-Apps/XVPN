import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/links.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/common.dart';

/// 设置页「开源许可」入口。
///
/// 守的是一个**取舍**：许可必须可获取，但不必长在应用里。此前应用内自绘了一个
/// 完整的许可浏览界面，并把 `LICENSE` / `NOTICE.md` / `THIRD-PARTY-NOTICES.md`
/// （合计约 430 KB，含 111 个模块的聚合许可）一起打进安装包供它读取。现在那三份
/// 文本随仓库与各平台发布包分发，应用只把人送到读得到全文的地方。
///
/// 因此本文件同时守住三件事：
///   1. 入口点了真的会打开项目主页的许可章节，而不是一个已经拆掉的应用内页面；
///   2. 打开的失败路径有出路（给出可手动访问的地址），不是点了没反应；
///   3. 本项目**不再**往 `LicenseRegistry` 里注册任何条目——也就是
///      「没有必要列举所有 license」这句要求的机器可验证形式；
///   4. 同一张卡上的「作者与官网」也真的会打开官网（共用同一条失败路径）。
void main() {
  /// 渲染桌面端设置页到「关于」卡片可见为止。
  ///
  /// 入口在页面最底部，矮窗口下要先滚过去；这里给一个够高的视口再 `ensureVisible`
  /// 兜一次，避免用例因为「控件在视口外」而假失败。
  Future<void> pumpSettings(
    WidgetTester tester, {
    ExternalUrlLauncher? openExternalUrl,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    addTearDown(state.dispose);
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
            openExternalUrl: openExternalUrl ?? (Uri uri) async => true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder licenseButton() => find.widgetWithText(XvButton, '查看');

  /// 「关于」卡里的另一个外部入口。
  ///
  /// 与「开源许可」放在同一个文件里，而不是另开一个：它们共用同一条失败路径
  /// （[_openExternal]），用户看到的也是同一张卡上的两行。分开写会让人以为
  /// 「点了打不开浏览器」这件事只对其中一行成立。
  Finder websiteButton() => find.widgetWithText(XvButton, '访问');

  testWidgets('「作者与官网」入口把作者与产品主页摆出来，而不是藏在仓库里', (WidgetTester tester) async {
    final opened = <Uri>[];
    await pumpSettings(
      tester,
      openExternalUrl: (Uri uri) async {
        opened.add(uri);
        return true;
      },
    );

    expect(find.text('作者与官网'), findsOneWidget);
    expect(
      find.textContaining('LUSIDA'),
      findsOneWidget,
      reason: '作者名字要直接写在卡上：用户不该为了知道这是谁做的东西去翻安装包属性',
    );
    await tester.ensureVisible(websiteButton());
    await tester.pumpAndSettle();
    await tester.tap(websiteButton());
    await tester.pumpAndSettle();

    expect(
      opened,
      <Uri>[Uri.parse(kWebsiteUrl)],
      reason: '点「访问」必须打开官网——它与仓库并列，不是同一个地址的两种写法',
    );
    expect(tester.takeException(), isNull);
  });

  test('官网与仓库是两个不同的地址，且都走 https', () {
    final site = Uri.parse(kWebsiteUrl);
    final repo = Uri.parse(kRepoUrl);
    expect(site.scheme, 'https');
    expect(site.host, 'www.lusida.net');
    expect(
      site.host,
      isNot(repo.host),
      reason: '官网是产品所在、仓库是源码所在；合成一个会让「下载」和「读代码」互相抢入口',
    );
  });

  testWidgets('「开源许可」入口打开项目主页的许可章节', (WidgetTester tester) async {
    final opened = <Uri>[];
    await pumpSettings(
      tester,
      openExternalUrl: (Uri uri) async {
        opened.add(uri);
        return true;
      },
    );

    expect(find.text('开源许可'), findsOneWidget, reason: '入口本身仍在');
    await tester.ensureVisible(licenseButton());
    await tester.pumpAndSettle();
    await tester.tap(licenseButton());
    await tester.pumpAndSettle();

    expect(
      opened,
      <Uri>[Uri.parse(kLicenseUrl)],
      reason: '点「查看」必须把人送到公开的许可声明，不是弹一个空窗',
    );
    expect(tester.takeException(), isNull);
  });

  test('许可地址指向项目主页的许可章节，而不是包内文件', () {
    final uri = Uri.parse(kLicenseUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'lsd-apps.github.io');
    expect(
      uri.fragment,
      'license',
      reason: '要落到页面的许可章节；锚点写错会静默停在页首',
    );
  });

  testWidgets('打不开浏览器时给出可手动访问的地址，而不是静默', (WidgetTester tester) async {
    await pumpSettings(tester, openExternalUrl: (Uri uri) async => false);

    await tester.ensureVisible(licenseButton());
    await tester.pumpAndSettle();
    await tester.tap(licenseButton());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(kLicenseUrl),
      findsOneWidget,
      reason: '没有默认浏览器时，用户至少要把地址抄走',
    );
  });

  testWidgets('不再向 LicenseRegistry 注册本项目的许可条目', (WidgetTester tester) async {
    // Flutter 自己的 NOTICES.Z 注册器在 flutter_test 里被刻意关掉（`initLicenses`
    // 是空实现），因此这里读到空清单，就等于「应用不再列举任何随包许可」。
    final entries = await tester.runAsync(() => LicenseRegistry.licenses.toList());
    expect(
      entries,
      isEmpty,
      reason: '本项目不再注册许可条目；要恢复「列举所有 license」请先改这条断言的意图',
    );
  });
}
