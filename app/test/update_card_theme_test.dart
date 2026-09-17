import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/update_card.dart';

/// 「版本更新」卡片的主题跟随。
///
/// ## 这一组守的是什么
///
/// 界面统一通过 `XV.xxx` 读取颜色，而那些是**读取可变调色板的静态 getter**
/// （`applyPalette` 换掉 `_current`，见 theme.dart）。颜色不是编译期常量，因此
/// 一个组件能不能跟着主题走，取决于**重建时它的 `build` 有没有被重新执行**。
///
/// 这里踩过一个只有暗色主题下才看得见的坑：设置页把这张卡片写成了
/// `const UpdateCard()`。const 组件实例在重建时被判定为同一个对象
/// （`identical`），Flutter 直接复用已构建的子树、**不会**再调它的 `build`，
/// 于是它一直拿着创建时那套调色板算出来的颜色——切到暗色后，同一页里只有这一张
/// 卡片没有跟着变。同一页其余卡片都是方法调用（`_buildXxxCard(...)`），每次重建
/// 都是新实例，所以只有它出问题，看起来就像「只有版本更新卡片漏了」。
///
/// 这类缺陷**不会抛异常、也不影响布局**，只会显示成一双不匹配的配色，因此必须
/// 由测试盯着，不能靠肉眼在亮色主题下开发时发现。
void main() {
  /// 渲染设置页。桌面端包含「版本更新」卡片。
  Future<void> pumpSettings(WidgetTester tester, XvPalette palette) async {
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    applyPalette(palette);
    final state = AppState();
    addTearDown(state.dispose);
    final theme = ThemeController();
    addTearDown(theme.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(palette),
        home: Scaffold(
          body: SettingsScreen(state: state, compact: false, theme: theme),
        ),
      ),
    );
    await tester.pump();
  }

  /// 「版本更新」那张卡片实际画出来的底色。
  Color renderedCardColor(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .descendant(of: find.byType(UpdateCard), matching: find.byType(Container))
          .first,
    );
    return (container.decoration! as BoxDecoration).color!;
  }

  setUp(() => applyPalette(XvPalette.dark));
  tearDown(() => applyPalette(XvPalette.dark));

  testWidgets('亮色下渲染后切到暗色，卡片底色跟着变', (WidgetTester tester) async {
    await pumpSettings(tester, XvPalette.light);
    expect(
      renderedCardColor(tester),
      XvPalette.light.panel,
      reason: '亮色主题下应当是亮色的面板底色',
    );

    // 模拟用户切换主题：换调色板后整体重建一次。
    //
    // 这条路径与生产一致——`_PaletteSync`（main.dart）在子树构建之前
    // `applyPalette`，然后整棵子树重建。
    await pumpSettings(tester, XvPalette.dark);
    expect(
      renderedCardColor(tester),
      XvPalette.dark.panel,
      reason: '切到暗色后卡片必须跟着换底色。'
          '若设置页把它写成 `const UpdateCard()`，子树的 build 不会重跑，'
          '这里会仍然是亮色的 panel —— 同一页里只有这一张卡片不跟随主题。',
    );
  });

  testWidgets('暗色下渲染后切到亮色，卡片底色也跟着变', (WidgetTester tester) async {
    // 反向也测：只在单方向断言的话，一个「永远用 dark」的写法能骗过上面那条。
    await pumpSettings(tester, XvPalette.dark);
    expect(renderedCardColor(tester), XvPalette.dark.panel);

    await pumpSettings(tester, XvPalette.light);
    expect(renderedCardColor(tester), XvPalette.light.panel);
  });

  test('设置页不得把 UpdateCard 写成 const', () {
    // 结构层面的兜底断言。
    //
    // 上面两条渲染用例已经能抓到它，但这条把**原因**写死在代码库里：`const`
    // 与 `XV` 的静态 getter 是互斥的用法，任何人以后再顺手加回 `const` 都会
    // 立刻看到为什么不行，而不必去重新推导一遍。
    final code = _codeOnly(File('lib/screens/settings_screen.dart').readAsStringSync());
    expect(
      RegExp(r'const\s+UpdateCard\s*\(').hasMatch(code),
      isFalse,
      reason: 'UpdateCard 依赖 XV 的主题色（可变调色板的静态 getter）。'
          'const 实例在重建时会被判定为同一个对象，build 不会重跑，'
          '于是切主题后这张卡片不跟随——实测只有它在暗色下没变。',
    );
  });

  test('移动端三个页头不得写成 const', () {
    // `MobileHeader` 同样读 XV 的颜色（状态圆点与前景色），而它被三个移动端
    // 页面各自 `const MobileHeader(...)` 了一次——同一类缺陷，只是它只影响页头
    // 自己那一行，不像 UpdateCard 那样整张卡片都错。
    //
    // 三个页面一起守：只修其中一处的话，另外两处在暗色下依旧是旧配色。
    for (final path in <String>[
      'lib/screens/settings_screen.dart',
      'lib/screens/rules_screen.dart',
      'lib/screens/connect_screen.dart',
    ]) {
      final code = _codeOnly(File(path).readAsStringSync());
      expect(
        RegExp(r'const\s+MobileHeader\s*\(').hasMatch(code),
        isFalse,
        reason: '$path 里的 MobileHeader 用了 const。它读 XV 的主题色，'
            'const 实例在切主题时不会重建，页头颜色会停在上一个主题。',
      );
    }
  });
}

/// 去掉 `//` 行注释与 `/* */` 块注释，只留代码。
///
/// 必须这么做：本仓库的习惯是把「当初那么写是错的」写进注释，而那些注释里
/// 正好含有被禁止的写法本身（例如 `const UpdateCard()`），不剥离就会误判。
String _codeOnly(String text) {
  final withoutBlock =
      text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlock
      .split('\n')
      .map((String line) {
        final int at = line.indexOf('//');
        return at < 0 ? line : line.substring(0, at);
      })
      .join('\n');
}
