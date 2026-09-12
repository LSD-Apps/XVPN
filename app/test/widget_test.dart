import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/main.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/rules_screen.dart';
import 'package:xvpn/screens/shell.dart';import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/common.dart';
import 'package:xvpn/widgets/title_bar.dart';

/// 与 testdata/wg-hk-01.conf 等价的测试配置。
const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32, fd00:7::2/128
DNS = 223.5.5.5, 119.29.29.29
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

Future<void> _pumpShell(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(1400, 900),
}) async {
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

/// 收尾：先卸载界面，再释放状态。
///
/// 必须在测试体内完成——内核的周期定时器如果留到 tearDown 才取消，
/// flutter_test 会在测试体结束时先报「A Timer is still pending」。
Future<void> _stopCore(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

void main() {
  // ------------------------------------------------------------ 空状态与布局

  testWidgets('未导入配置时展示导入引导', (WidgetTester tester) async {
    // 桌面尺寸（>= 900）才会走侧边导航布局
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XvpnApp());
    await tester.pumpAndSettle();

    expect(find.text('导入你的 VPN 配置'), findsOneWidget);
    expect(find.text('选择配置文件'), findsOneWidget);
    // 空状态要如实体现在支持两种协议，不能只写 WireGuard。
    expect(
      find.textContaining('.ovpn'),
      findsWidgets,
      reason: '两种协议的入口文案要一起出现',
    );
    expect(find.text('分流记录'), findsOneWidget);
    expect(find.text('配置文件'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('拖拽落点占满内容列宽度，不按内容收缩', (WidgetTester tester) async {
    // 原型 `design/ui-mockup.html` 写的是 `.drop{width:100%;max-width:520px}`。
    // 早先漏了 width:100%，落点于是按内容收缩成一条窄框：
    // 既不像一个可拖放的区域，与上下两段文字的宽度也参差不齐。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XvpnApp());
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(DashedBox)).width,
      closeTo(520, 1),
      reason: '拖拽落点应占满内容列（原型 max-width:520px），而不是按内容收缩',
    );
  });

  testWidgets('窄屏切换为底部标签栏布局', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XvpnApp());
    await tester.pumpAndSettle();

    // 移动端标签栏只有三项，且「配置文件」并入设置页。
    // 「连接」同时出现在页头标题与底部标签上，因此是 2 个。
    expect(find.text('连接'), findsNWidgets(2));
    expect(find.text('分流'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('配置文件'), findsNothing);
  });

  testWidgets('横屏等矮屏下移动端页面不溢出', (WidgetTester tester) async {
    // 手机横屏时可用高度只剩 300 上下，空状态与连接页都必须能滚，
    // 否则会直接抛 RenderFlex overflow。
    tester.view.physicalSize = const Size(780, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const XvpnApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('导入配置'), findsOneWidget);
  });

  testWidgets('横屏下三个标签页都不溢出（已导入配置且有记录）', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    tester.view.physicalSize = const Size(780, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: XvShell(state: state, theme: ThemeController()),
      ),
    );
    await tester.pumpAndSettle();

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(state.records, isNotEmpty);
    expect(tester.takeException(), isNull, reason: '连接页在矮屏下不应溢出');

    for (final String tab in <String>['分流', '设置']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$tab 页在矮屏下不应溢出');
    }

    await _stopCore(tester, state);
  });

  // ------------------------------------------------------------ 导入与连接

  test('导入合法 .conf 后会成为当前配置', () {
    final state = AppState();
    addTearDown(state.dispose);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');

    expect(state.hasProfiles, isTrue);
    expect(state.activeProfile!.name, 'wg-hk-01.conf');
    expect(state.activeProfile!.endpointDisplay, '203.0.113.42:51820');
    expect(state.activeProfile!.tunnelAddressDisplay, '10.7.0.2, fd00:7::2');
    expect(state.settings.autoConnectOnImport, isTrue);
  });

  testWidgets('导入后自动连接，界面进入已连接状态', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    // DemoVpnCore 在 700ms 后置为已连接
    await tester.pump(const Duration(seconds: 1));

    expect(state.status, VpnStatus.connected);
    expect(find.text('断开连接'), findsOneWidget);
    expect(find.text('已连接'), findsWidgets);
    // 零配置校验卡应显示系统代理已被接管
    expect(find.text('系统代理已自动设置'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:2080'), findsOneWidget);

    await _stopCore(tester, state);
  });

  testWidgets('连接后分流记录会出现在界面上，并区分代理与直连', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // DemoVpnCore 每 2.6 秒产生一条记录，等够两条以上
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(state.records, isNotEmpty, reason: '内核应上报分流记录');
    expect(state.proxyCount, greaterThan(0), reason: '应有走代理的记录');
    expect(state.directCount, greaterThan(0), reason: '应有直连的记录');
    expect(find.text('代理'), findsWidgets);
    expect(find.text('直连'), findsWidgets);

    await _stopCore(tester, state);
  });

  testWidgets('断开后回到未连接状态', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(state.status, VpnStatus.connected);

    await tester.tap(find.text('断开连接'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(state.status, VpnStatus.disconnected);
    expect(find.text('连接'), findsWidgets);
    expect(find.text('断开连接'), findsNothing);
  });

  // ------------------------------------------------------------ 分流记录页

  testWidgets('分流记录页可切换筛选并显示命中规则', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();

    // 不依赖演示内核的定时器刚好轮到哪一条目标，直接喂入两条记录。
    // 否则这个用例会随定时器步进变得时灵时不灵。
    state.onSplitRecord(
      SplitRecord(
        time: DateTime.now(),
        target: 'npmmirror.com',
        kind: RouteKind.direct,
        rule: 'geosite-cn + geoip-cn',
        outbound: 'direct',
      ),
    );
    state.onSplitRecord(
      SplitRecord(
        time: DateTime.now(),
        target: 'www.youtube.com',
        kind: RouteKind.proxy,
        rule: '默认规则',
        outbound: 'vpn',
      ),
    );
    await tester.pump();

    // 切到「分流记录」页
    await tester.tap(find.text('分流记录'));
    await tester.pumpAndSettle();

    expect(find.text('搜索域名或 IP…'), findsOneWidget);
    // 表头改为「流量 / 失败 / 延迟」：规则名移到每行的第二行小字里
    // （它解释「为什么走这条路」，但不该占据一个宽列）。
    expect(find.text('流量 ↓/↑'), findsOneWidget);
    // 命中规则集的域名应命中 geosite-cn。
    //
    // 这里期望的是**归一化之后**的名字：内核返回的 rule 是一整句描述
    // （`rule_set=[geosite-cn geoip-cn] => route`，且 rulePayload 恒为空），
    // 界面必须把它翻译成人话，而不是把内核术语原样丢给用户。
    expect(find.text('geosite-cn + geoip-cn'), findsWidgets);
    expect(
      find.textContaining('rule_set='),
      findsNothing,
      reason: '内核术语不该出现在界面上',
    );

    // 只看走代理
    await tester.tap(find.text('走代理'));
    await tester.pumpAndSettle();
    final proxies = state.filteredRecords(RouteFilter.proxy, '');
    expect(proxies, isNotEmpty);
    expect(proxies.every((SplitRecord r) => r.kind == RouteKind.proxy), isTrue);

    await _stopCore(tester, state);
  });

  // ------------------------------------------------------------ 分流诊断

  testWidgets('判为直连却失败时，界面上给出「疑似规则未覆盖」的归因', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 注入一条真实形态的失败：域名、走 direct、i/o 超时。
    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime.now(),
        target: 'www.example.com:443',
        outbound: 'direct',
        reason: 'dial tcp 1.2.3.4:443: i/o timeout',
      ),
    );
    await tester.pump();

    expect(find.textContaining('疑似规则未覆盖'), findsOneWidget);
    expect(find.textContaining('www.example.com'), findsWidgets);
    expect(state.failureDigest.suspectedMissingRules, <String>[
      'www.example.com',
    ]);

    await _stopCore(tester, state);
  });

  testWidgets('移动端连接页同样有「零配置接管状态」并展示失败归因', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 与桌面端同一份内容：接管状态必须两端一致
    expect(find.text('零配置接管状态'), findsOneWidget);
    expect(find.textContaining('已导入 1 个配置'), findsOneWidget);
    expect(find.text('TUN 虚拟网卡接管'), findsOneWidget);

    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime.now(),
        target: 'www.example.com:443',
        outbound: 'direct',
        reason: 'dial tcp 1.2.3.4:443: i/o timeout',
      ),
    );
    await tester.pump();

    // 归因结论在移动端也要能看到，否则「检测能力」在手机上是不可见的
    expect(find.textContaining('疑似规则未覆盖'), findsOneWidget);

    await _stopCore(tester, state);
  });

  testWidgets('走了隧道却失败时，归因为节点问题而不是规则问题', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime.now(),
        target: 'www.google.com:443',
        outbound: 'vpn',
        reason: 'dial tcp: i/o timeout',
      ),
    );
    await tester.pump();

    // 不能归咎于规则——否则用户会去折腾规则库，而问题其实在节点。
    // 用精确文案定位：'判定正常' 会同时出现在标题与建议里。
    expect(find.text('有连接失败，但判定正常'), findsOneWidget);
    expect(state.failureDigest.suspectedMissingRules, isEmpty);
    expect(state.failureDigest.advice, contains('节点'));

    await _stopCore(tester, state);
  });

  testWidgets('重新连接会清空上一次的失败记录', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime.now(),
        target: 'a.example.com:443',
        outbound: 'direct',
        reason: 'i/o timeout',
      ),
    );
    await tester.pump();
    expect(state.failures, isNotEmpty);

    // 注意不要 await：widget 测试用的是假异步时钟，await 一个依赖定时器的
    // Future 会永远不返回，直接把测试挂死。改为触发后 pump 推进时间。
    unawaited(state.disconnect());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    unawaited(state.connect());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(state.failures, isEmpty, reason: '新一轮连接不应带着旧失败');

    await _stopCore(tester, state);
  });

  // ------------------------------------------------------------ 设置页

  testWidgets('设置页可以关闭分流日志，记录随之清空', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state);

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(state.records, isNotEmpty);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('记录分流日志'), findsOneWidget);

    state.updateSettings(state.settings.copyWith(logSplits: false));
    await tester.pumpAndSettle();
    expect(state.records, isEmpty, reason: '关闭日志后应清空已有记录');

    await _stopCore(tester, state);
  });

  // ------------------------------------------------------------ 移动端功能闭环

  testWidgets('移动端可以删除配置', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    expect(state.profiles, hasLength(1));

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget, reason: '移动端此前完全没有删除入口');

    // 配置卡在设置页底部，先滚进可视区再点，否则点击会落空。
    await tester.ensureVisible(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 删除会断线，因此必须先确认
    expect(find.text('删除配置'), findsOneWidget);
    await tester.tap(find.widgetWithText(XvButton, '删除').last);
    await tester.pumpAndSettle();

    expect(state.profiles, isEmpty);
    await _stopCore(tester, state);
  });

  testWidgets('移动端分流页可以清空记录并搜索', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(state.records, isNotEmpty);

    await tester.tap(find.text('分流'));
    await tester.pumpAndSettle();
    expect(find.text('搜索域名或 IP…'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(state.records, isEmpty);

    await _stopCore(tester, state);
  });

  testWidgets('移动端分流记录显示命中规则，且文案与桌面端一致', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    await tester.tap(find.text('分流'));
    await tester.pumpAndSettle();

    // 筛选文案取自 RouteFilterX.label（「走代理」），而不是移动端自己写的「代理」。
    // 记录行上的 RouteTag 也叫「代理」，所以只在分段控件内部比较。
    expect(
      find.descendant(of: find.byType(XvSegmented), matching: find.text('走代理')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(XvSegmented), matching: find.text('代理')),
      findsNothing,
    );
    // 命中规则是「为什么走这条路」的唯一线索，移动端也要有
    expect(find.textContaining('geosite-cn'), findsWidgets);

    await _stopCore(tester, state);
  });

  testWidgets('移动端分流标签跟随实际分流模式，不再恒为「规则直连」', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('规则直连'), findsWidgets);

    state.updateSettings(
      state.settings.copyWith(splitMode: SplitMode.globalProxy),
    );
    await tester.pumpAndSettle();
    expect(find.text('规则直连'), findsNothing, reason: '全局代理下显示「规则直连」是错误信息');
    expect(find.textContaining('全局代理'), findsWidgets);

    state.updateSettings(
      state.settings.copyWith(splitMode: SplitMode.globalDirect),
    );
    await tester.pumpAndSettle();
    expect(find.text('全部直连'), findsOneWidget);

    await _stopCore(tester, state);
  });

  testWidgets('连接中重复点圆环不会并发跑两遍连接', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    // DemoVpnCore 700ms 后才置为已连接，这里正处于 connecting
    expect(state.status, VpnStatus.connecting);

    await state.toggleConnection();
    await state.toggleConnection();
    await tester.pump();
    expect(state.status, VpnStatus.connecting, reason: '连接中不应被第二次点击打断');

    await tester.pump(const Duration(seconds: 1));
    expect(state.status, VpnStatus.connected);
    await _stopCore(tester, state);
  });

  testWidgets('移动端统计区仍能看到本次累计与失败次数', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('本次累计'), findsOneWidget);
    expect(find.text('无失败连接'), findsOneWidget);

    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime.now(),
        target: 'www.example.com:443',
        outbound: 'vpn',
        reason: 'i/o timeout',
      ),
    );
    await tester.pump();
    expect(find.text('1 次失败'), findsOneWidget);

    await _stopCore(tester, state);
  });

  // ------------------------------------------------------------ 主题与设计变量

  test('暗色调色板与设计稿一致', () {
    expect(XvPalette.dark.bg.toARGB32(), 0xFF06080C);
    expect(XvPalette.dark.sidebar.toARGB32(), 0xFF0E131D);
    expect(XvPalette.dark.panel.toARGB32(), 0xFF121722);
    expect(XvPalette.dark.green.toARGB32(), 0xFF2EE6A8);
    expect(XvPalette.dark.violet.toARGB32(), 0xFFA274FF);
    expect(XvPalette.dark.blue.toARGB32(), 0xFF4C8DFF);
    expect(XV.desktopBreakpoint, 900.0);
  });

  test('亮色调色板沿用同一套语义，主色仍是绿色', () {
    expect(XvPalette.light.green.toARGB32(), 0xFF0FA97A);
    expect(XvPalette.light.bg.toARGB32(), 0xFFF4F4F7);
    expect(XvPalette.light.sidebar.toARGB32(), 0xFFFFFFFF);
    expect(XvPalette.light.text.toARGB32(), 0xFF17161C);
  });

  test('切换调色板后 XV 读到新值', () {
    addTearDown(() => applyPalette(XvPalette.dark));

    applyPalette(XvPalette.light);
    expect(XV.green.toARGB32(), 0xFF0FA97A);
    expect(XV.bg.toARGB32(), 0xFFF4F4F7);

    applyPalette(XvPalette.dark);
    expect(XV.green.toARGB32(), 0xFF2EE6A8);
    expect(XV.bg.toARGB32(), 0xFF06080C);
  });

  test('主题控制器按 跟随系统 → 亮色 → 深色 循环', () {
    final theme = ThemeController();
    addTearDown(theme.dispose);
    expect(theme.value, ThemeMode.system);
    theme.cycle();
    expect(theme.value, ThemeMode.light);
    theme.cycle();
    expect(theme.value, ThemeMode.dark);
    theme.cycle();
    expect(theme.value, ThemeMode.system);
  });

  // ------------------------------------------------------------ 标题栏

  testWidgets('桌面端渲染自绘标题栏，且侧栏不再重复品牌', (WidgetTester tester) async {
    // flutter_test 默认把目标平台当作 Android，这里显式声明为 Windows
    // 才能走到真实的桌面分支（窗口按钮只在 Windows 上渲染）。
    // 复位放在 finally 里：断言失败时也要恢复，否则会泄漏给后续用例。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = AppState();
      addTearDown(state.dispose);
      await _pumpShell(tester, state);

      // 品牌只出现一次（标题栏里），侧栏不再重复
      expect(find.text('XVPN'), findsOneWidget);
      expect(find.byType(XvTitleBar), findsOneWidget);
      // 标题栏右侧是主题切换与三个窗口按钮（按提示文案定位，不绑定具体图标实现）
      expect(find.text('跟随系统'), findsOneWidget);
      expect(find.byTooltip('最小化'), findsOneWidget);
      expect(find.byTooltip('最大化'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('移动端不渲染自绘标题栏，但页头有应用图标', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(390, 844));

    expect(find.byType(XvTitleBar), findsNothing);
    // 移动端没有标题栏，品牌靠页头左侧的图标露出；
    // 这里不能再有 'XVPN' 文字，否则会和页面标题一起出现两个品牌。
    expect(find.text('XVPN'), findsNothing);
    expect(find.byType(XvBrandMark), findsOneWidget);
    expect(_brandImageAsset(), findsOneWidget);
  });

  // ------------------------------------------------------------ 设置页：外观

  testWidgets('移动端设置页可以切换主题', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final theme = ThemeController();
    addTearDown(theme.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: XvShell(state: state, theme: theme),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(XvSegmented), matching: find.text('深色')),
    );
    await tester.pumpAndSettle();
    expect(theme.value, ThemeMode.dark);

    await tester.tap(
      find.descendant(of: find.byType(XvSegmented), matching: find.text('亮色')),
    );
    await tester.pumpAndSettle();
    expect(theme.value, ThemeMode.light);
  });

  testWidgets('桌面端设置页与标题栏共用同一份主题状态', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = AppState();
      addTearDown(state.dispose);
      final theme = ThemeController();
      addTearDown(theme.dispose);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: XvShell(state: state, theme: theme),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      // 从设置页切换后，标题栏上的标签要同步变化
      await tester.tap(
        find.descendant(
          of: find.byType(XvSegmented),
          matching: find.text('亮色'),
        ),
      );
      await tester.pumpAndSettle();
      expect(theme.value, ThemeMode.light);
      expect(find.text('亮色'), findsNWidgets(2), reason: '设置页选项与标题栏标签应同时显示「亮色」');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('桌面端设置页在较矮窗口下不溢出，且域名分流规则卡片可渲染', (WidgetTester tester) async {
    // 桌面设置页是「卡片纵向堆叠 + 整体滚动」，内容比窗口高是常态。
    // 这里特意用小窗口（1280×720 是常见的笔记本可用高度）压一遍：
    // 只要有一处忘了放进滚动容器，就会抛 RenderFlex overflow。
    final state = AppState();
    addTearDown(state.dispose);
    await _pumpShell(tester, state, size: const Size(1280, 720));

    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '桌面设置页在 720 高度下不应溢出');

    // 域名分流规则卡片在独立的「分流规则」页，需要滚动到它才会被构建。
    //
    // 这里手写拖拽循环而不用 dragUntilVisible：那需要精确挑出正确的可滚动
    // 节点，而页面上同时存在页面级滚动与卡片内部滚动，按类型找很容易选错，
    // 失败信息也只是 "Bad state: No element"，排查成本高于直接写循环。
    //
    // 本用例用演示内核（不接真实 sing-box），因此这张卡片走的是「不支持」
    // 分支——接上真实内核的表单渲染由 diagnostics_ui_test 覆盖。
    await tester.tap(find.text('分流规则'));
    await tester.pumpAndSettle();
    final rulesScroll = find.byKey(RulesScreen.desktopScrollKey);
    var scrolled = 0;
    while (find.text('域名分流规则').evaluate().isEmpty && scrolled < 20) {
      await tester.drag(rulesScroll, const Offset(0, -200));
      await tester.pumpAndSettle();
      scrolled++;
    }
    expect(find.text('域名分流规则'), findsOneWidget, reason: '域名分流规则卡片应当存在于分流规则页');
    expect(tester.takeException(), isNull, reason: '滚到底部也不应溢出');

    await _stopCore(tester, state);
  });

  testWidgets('桌面设置页只讲系统代理，不提供无法兑现的 TUN 选项', (WidgetTester tester) async {
    // 桌面端只有系统代理一条可用路径（TUN 需要 wintun 驱动与管理员权限，
    // 当前版本未内置）。此前界面上并排摆着「TUN 虚拟网卡」选项，选了却不生效，
    // 属于安静的假承诺。这个用例锁住「不再提供该选项、且说明原因」。
    //
    // 必须显式指定平台：测试进程跑在桌面上时 defaultTargetPlatform 可能是
    // android，那样拿到的是移动端的文案，断言会莫名其妙地失败。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = AppState();
      addTearDown(state.dispose);
      await _pumpShell(tester, state, size: const Size(1400, 1100));

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.text('流量接管方式'), findsOneWidget);
      expect(find.text('系统代理'), findsOneWidget);
      expect(find.text('TUN 虚拟网卡'), findsNothing, reason: '不能提供无法兑现的选项');
      expect(
        find.textContaining('暂不支持 TUN'),
        findsOneWidget,
        reason: '要说明为什么没有',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('移动端设置页同样有「流量接管方式」，内容按平台给出', (WidgetTester tester) async {
    // 这一块此前**只有桌面端有**，移动端整张卡片缺失——同一份设置在两端
    // 信息结构不一致。现在两端都有这张卡，只是内容按平台不同。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final state = AppState();
      addTearDown(state.dispose);
      await _pumpShell(tester, state, size: const Size(390, 900));

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      var guard = 0;
      while (find.text('流量接管方式').evaluate().isEmpty && guard < 30) {
        await tester.drag(scrollable, const Offset(0, -200));
        await tester.pumpAndSettle();
        guard++;
      }

      expect(find.text('流量接管方式'), findsOneWidget);
      expect(
        find.text('TUN 虚拟网卡'),
        findsOneWidget,
        reason: '安卓走 VpnService 的 TUN',
      );
      expect(find.text('系统代理'), findsNothing, reason: '安卓没有系统代理这条路');
      expect(
        find.textContaining('VpnService'),
        findsWidgets,
        reason: '要说明为什么只能是 TUN',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 定位品牌图标：按资源名匹配，不依赖具体是 Image 还是别的实现。
Finder _brandImageAsset() {
  return find.byWidgetPredicate(
    (Widget w) =>
        w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == 'assets/vpn.png',
    description: 'assets/vpn.png',
  );
}
