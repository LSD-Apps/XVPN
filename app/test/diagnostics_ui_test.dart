import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/dns_monitor.dart';
import 'package:xvpn/core/startup_self_check.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/widgets/auto_route_card.dart';
import 'package:xvpn/widgets/common.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';

import 'support/recording_listener.dart';

const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
''';

Future<void> _pump(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(1500, 1000),
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

Future<void> _stop(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
}

/// 导入配置并等到演示内核连上。
///
/// 演示内核的 connect() 里有 700ms 的模拟建连延迟，之后才开始每秒上报流量。
/// 不把它跑完就断言，会先报「A Timer is still pending」——那是测试自己
/// 没等完异步，而不是被测代码有问题。
Future<void> _connect(WidgetTester tester, AppState state) async {
  state.importConf(text: _conf, fileName: 'wg.conf');
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// 造一个带真实内核的状态。
///
/// 用真实的 [SingBoxRunner] 而不是演示内核，是为了让自动纠正表真的存在——
/// 那正是「手工指定」表单渲染的前提；主动探测关掉，测试里不真的连网络。
AppState stateWithRealCore() => AppState(
  coreFactory: (VpnCoreListener listener) =>
      SingBoxRunner(listener, probesEnabled: false),
);

/// 造一条可以手动触发的分流记录。
SplitRecord _record(String target, RouteKind kind, {DateTime? at}) =>
    SplitRecord(
      time: at ?? DateTime(2026, 2, 14, 10, 20, 30),
      target: target,
      kind: kind,
      rule: kind == RouteKind.proxy ? '默认规则' : 'geosite-cn + geoip-cn',
      outbound: kind == RouteKind.proxy ? 'vpn' : 'direct',
    );

void main() {
  group('分流记录页：大数据量', () {
    testWidgets('灌入远超上限的记录后页面仍能正常渲染', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      // 灌入 3000 条：环形缓冲必须把它压到上限，且不能崩、不能卡死。
      final watch = Stopwatch()..start();
      for (var i = 0; i < 3000; i++) {
        state.onSplitRecord(
          _record(
            'host-$i.example',
            i.isEven ? RouteKind.proxy : RouteKind.direct,
            at: DateTime(2026, 2, 14, 10, i ~/ 60, i % 60),
          ),
        );
      }
      await tester.pump();
      watch.stop();

      expect(state.records.length, AppState.recordLimit);
      expect(
        watch.elapsedMilliseconds,
        lessThan(2000),
        reason: '插入 3000 条不该出现二次方级别的开销',
      );

      await tester.tap(find.text('分流记录'));
      await tester.pumpAndSettle();
      // 表头改为「流量 / 失败 / 延迟」：规则名对用户是次要信息，
      // 而「这个目标跑了多少、有没有失败」才是要看的（规则移到行的第二行）。
      expect(find.text('流量 ↓/↑'), findsOneWidget);
      expect(find.text('失败'), findsOneWidget);

      await _stop(tester, state);
    });

    testWidgets('搜索时结果被截断并明确提示', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      for (var i = 0; i < 600; i++) {
        state.onSplitRecord(_record('common-$i.example', RouteKind.proxy));
      }
      await tester.pump();

      await tester.tap(find.text('分流记录'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'common-');
      await tester.pumpAndSettle();

      // 筛选结果受上限约束，并且界面要把这件事说出来，
      // 而不是悄悄截断让用户以为记录丢了。
      expect(
        state.filteredRecords(RouteFilter.all, 'common-').length,
        AppState.searchResultLimit,
      );
      expect(state.isFilterTruncated(RouteFilter.all, 'common-'), isTrue);

      // 列表是懒构建的，脚注在 300 条之后，必须先滚到底才会被创建。
      await tester.dragUntilVisible(
        find.textContaining('只显示前'),
        find.byType(ListView),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('只显示前'), findsOneWidget);

      await _stop(tester, state);
    });

    testWidgets('没有匹配时给出带关键字的空态', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      state.onSplitRecord(_record('www.baidu.com', RouteKind.direct));
      await tester.pump();

      await tester.tap(find.text('分流记录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'zzz-not-found');
      await tester.pumpAndSettle();

      expect(find.textContaining('没有匹配'), findsOneWidget);

      await _stop(tester, state);
    });

    testWidgets('搜索框有清除入口', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      await tester.tap(find.text('分流记录'));
      await tester.pumpAndSettle();

      // 未输入时不显示清除按钮。
      expect(find.text('清除'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'baidu');
      await tester.pumpAndSettle();
      expect(find.text('清除'), findsOneWidget);

      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect(find.text('清除'), findsNothing);

      await _stop(tester, state);
    });
  });

  group('筛选缓存', () {
    test('同一条件重复查询命中缓存，返回同一个列表实例', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.onSplitRecord(_record('a.example', RouteKind.proxy));

      final first = state.filteredRecords(RouteFilter.all, '');
      final second = state.filteredRecords(RouteFilter.all, '');
      expect(
        identical(first, second),
        isTrue,
        reason: '界面每帧都会调用它；不缓存就等于每秒全量重算一遍',
      );
    });

    test('新增记录后缓存失效', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.onSplitRecord(_record('a.example', RouteKind.proxy));
      final before = state.filteredRecords(RouteFilter.all, '');
      state.onSplitRecord(_record('b.example', RouteKind.direct));
      final after = state.filteredRecords(RouteFilter.all, '');
      expect(after.length, before.length + 1);
      expect(identical(before, after), isFalse);
    });

    test('筛选条件或关键字变化时重新计算', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.onSplitRecord(_record('a.example', RouteKind.proxy));
      state.onSplitRecord(_record('b.example', RouteKind.direct));

      expect(state.filteredRecords(RouteFilter.proxy, '').length, 1);
      expect(state.filteredRecords(RouteFilter.direct, '').length, 1);
      expect(state.filteredRecords(RouteFilter.all, 'a.example').length, 1);
    });

    test('失败归因摘要也被缓存', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.onConnectionFailure(
        ConnectionFailure(
          time: DateTime(2026, 2, 14),
          target: 'blocked.example:443',
          outbound: 'direct',
          reason: 'i/o timeout',
        ),
      );
      final first = state.failureDigest;
      final second = state.failureDigest;
      expect(identical(first, second), isTrue);
      expect(first.suspectedMissingRules, contains('blocked.example'));
    });

    test('records 视图是只读的', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.onSplitRecord(_record('a.example', RouteKind.proxy));
      expect(
        () => state.records.add(_record('b.example', RouteKind.proxy)),
        throwsUnsupportedError,
      );
    });
  });

  group('连接页的检测能力展示', () {
    testWidgets('连接后展示流量分布、自检与 DNS', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      // 用高一点的窗口，保证「零配置接管状态」卡片里的检测行都在视口内
      // （桌面端布局在内容超出时靠卡片内部滚动，视口外的行不会被构建）。
      await _pump(tester, state, size: const Size(1500, 1400));
      await _connect(tester, state);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      // 演示内核连接成功后会持续上报流量，其中带有按路径拆分的字节数。
      expect(state.isConnected, isTrue);
      expect(state.proxiedBytes + state.directBytes, greaterThan(0));
      // 面板文案在改口径时变过：以前是「当前活连接：N% 走隧道」，取自活连接快照，
      // 而短连接在 1 秒轮询里基本抓不到，数字常年停在 0%。现在用的是状态层累加
      // 出来的会话累计值。
      expect(find.textContaining('本次分流'), findsWidgets);
      expect(find.textContaining('走隧道'), findsWidgets);

      // 演示内核不做 DNS 探测与自检，先确认占位文案在，
      // 再喂一份真实报告验证渲染路径。
      expect(find.textContaining('正在自检'), findsOneWidget);
      expect(find.textContaining('正在探测 DNS'), findsOneWidget);

      state.onDnsReport(
        DnsReport(
          checkedAt: DateTime(2026, 2, 14),
          resolvers: const <ResolverHealth>[],
          direct: LatencyWindow(capacity: 4)..add(12),
          tunnel: LatencyWindow(capacity: 4)..add(96),
          verdict: DnsVerdict.consistent,
        ),
      );
      await tester.pump();
      expect(find.textContaining('DNS · 一致'), findsOneWidget);
      expect(find.textContaining('直连解析 12ms'), findsWidgets);

      await tester.pump(const Duration(seconds: 3));
      await _stop(tester, state);
    });

    testWidgets('自检发现异常时检查行变成警示色而不是一片绿色', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      await tester.pump(const Duration(seconds: 1));

      state.onSelfCheck(
        StartupSelfCheckReport(
          checkedAt: DateTime(2026, 2, 14),
          probes: const <ProbeResult>[
            ProbeResult(
              name: StartupSelfCheck.directName,
              status: ProbeStatus.failed,
              detail: '无法连接 www.baidu.com:443',
            ),
            ProbeResult(
              name: StartupSelfCheck.tunnelName,
              status: ProbeStatus.passed,
              detail: '经隧道可达',
              millis: 180,
            ),
          ],
          conclusion: '直连这条腿不通，隧道是通的',
          advice: '问题在本地网络或 DNS，不在节点。',
        ),
      );
      await tester.pump();

      expect(find.textContaining('直连这条腿不通'), findsOneWidget);
      expect(find.textContaining('不在节点'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await _stop(tester, state);
    });

    testWidgets('DNS 报告会显示校验结论与建议', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      await tester.pump(const Duration(seconds: 1));

      state.onDnsReport(
        DnsReport(
          checkedAt: DateTime(2026, 2, 14),
          resolvers: const <ResolverHealth>[
            ResolverHealth(
              server: '223.5.5.5',
              role: '直连',
              samples: 4,
              failures: 0,
              consecutiveFailures: 0,
              lastMillis: 12,
              lastSummary: '114.114.114.114',
              lastCheckedAt: null,
            ),
          ],
          direct: LatencyWindow(capacity: 4)..add(12),
          tunnel: LatencyWindow(capacity: 4)..add(96),
          verdict: DnsVerdict.suspectPoisoning,
        ),
      );
      await tester.pump();

      expect(find.textContaining('疑似投毒'), findsOneWidget);
      expect(find.textContaining('走隧道'), findsWidgets);

      await tester.pump(const Duration(seconds: 3));
      await _stop(tester, state);
    });

    testWidgets('自动纠正后会显示学到的域名', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      await tester.pump(const Duration(seconds: 1));

      state.onAutoRouteLearned(
        const AutoRouteDecision(
          domain: 'blocked.example',
          added: true,
          reason: '连续 3 次判为直连但失败，已自动改为走隧道',
        ),
      );
      await tester.pump();

      expect(find.textContaining('已自动纠正 1 个域名'), findsOneWidget);
      expect(find.textContaining('blocked.example'), findsWidgets);

      await tester.pump(const Duration(seconds: 3));
      await _stop(tester, state);
    });

    testWidgets('未连接时不显示检测区块，避免一排「待检测」的噪音', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);
      await _connect(tester, state);
      // 自动导入会触发连接，这里先断开。
      await state.disconnect();
      await tester.pumpAndSettle();

      expect(find.textContaining('正在自检'), findsNothing);
      expect(find.textContaining('正在探测 DNS'), findsNothing);

      await _stop(tester, state);
    });
  });

  group('自动纠正管理卡片', () {
    testWidgets('演示内核下说明不支持，而不是显示一个空列表', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state);

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.text('自动纠正'), findsOneWidget);
      expect(find.textContaining('演示模式'), findsOneWidget);

      await _stop(tester, state);
    });

    testWidgets('接真实内核时可手工指定域名，且非法输入给出明确提示', (WidgetTester tester) async {
      // 用真实的 SingBoxRunner 当内核（关掉主动探测，测试里不真的连网络），
      // 这样自动纠正表存在，卡片会渲染出完整的手工指定表单。
      final state = stateWithRealCore();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(1500, 1400));

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      final scroll = find.byKey(SettingsScreen.desktopScrollKey);
      var guard = 0;
      while (find.text('手工指定').evaluate().isEmpty && guard < 20) {
        await tester.drag(scroll, const Offset(0, -200));
        await tester.pumpAndSettle();
        guard++;
      }
      expect(find.text('手工指定'), findsOneWidget);
      expect(find.textContaining('目前还没有需要纠正的域名'), findsOneWidget);

      // 输入一个 IP：IP 不参与按域名的分流规则，界面必须说清楚而不是静默失败。
      final field = find.widgetWithText(TextField, '例如 example.com');
      await tester.enterText(field, '1.2.3.4');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(find.textContaining('IP 不参与按域名的分流规则'), findsOneWidget);
      expect(state.autoRoute!.isEmpty, isTrue, reason: '非法输入不该写入规则');

      // 输入合法域名：应归一化（小写、去端口）后写入并出现在列表里。
      await tester.enterText(field, 'Blocked.Example.COM:443');
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(state.autoRoute!.length, 1);
      expect(
        state.autoRoute!.match('blocked.example.com'),
        isNotNull,
        reason: '输入应被归一化后写入',
      );
      expect(find.text('blocked.example.com'), findsWidgets);

      await _stop(tester, state);
    });

    test('演示内核没有自动纠正表，手工规则也无处可写', () {
      final state = AppState();
      addTearDown(state.dispose);
      expect(state.autoRoute, isNull, reason: '演示内核不做学习');
      expect(
        state.setDomainPreference('example.com', RoutePreference.forceProxy),
        isFalse,
        reason: '没有表时必须明确返回失败，而不是假装写入成功',
      );
      expect(state.pruneAutoRoute(), isEmpty);
    });
  });

  group('手工指定输入区的宽度', () {
    /// 手工指定输入框的**容器**。
    ///
    /// 必须量容器而不是内部的 TextField：后者还要减去容器左右各 12px 内边距
    /// 与 14px 搜索图标，比容器窄约 48px，量错了会得到一个偏小且难以解释的数。
    Finder inputBox() => find.ancestor(
      of: find.widgetWithText(TextField, '例如 example.com'),
      matching: find.byType(XvSearchField),
    );

    /// 用真实内核渲染桌面设置页，并把手工指定滚进视口。
    Future<void> renderDesktopWithCore(
      WidgetTester tester,
      AppState state,
    ) async {
      await _pump(tester, state, size: const Size(1500, 1400));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final scroll = find.byKey(SettingsScreen.desktopScrollKey);
      var guard = 0;
      while (find.text('手工指定').evaluate().isEmpty && guard < 20) {
        await tester.drag(scroll, const Offset(0, -200));
        await tester.pumpAndSettle();
        guard++;
      }
    }

    testWidgets('窄屏（手机宽度）下输入框不再被三栏挤压', (WidgetTester tester) async {
      // 回归用例：原先「输入框 + 走向选择器 + 添加按钮」三栏并排，
      // 选择器约 178px、按钮最小 88px、两处 8px 间距，一共吃掉约 282px。
      // 手机可用宽度只有 330 上下，留给输入框的只剩 170 上下，
      // 而域名动辄 20 多个字符，用户根本看不见自己输入了什么。
      final state = stateWithRealCore();
      addTearDown(state.dispose);
      // 390 是常见手机的逻辑宽度。
      await _pump(tester, state, size: const Size(390, 900));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      // 手机设置页整体滚动，把手工指定滚进视口。
      final scrollable = find.byType(Scrollable).first;
      var guard = 0;
      while (inputBox().evaluate().isEmpty && guard < 30) {
        await tester.drag(scrollable, const Offset(0, -220));
        await tester.pumpAndSettle();
        guard++;
      }

      expect(inputBox(), findsOneWidget, reason: '应能找到手工指定输入框');
      final width = tester.getSize(inputBox()).width;
      expect(
        width,
        greaterThanOrEqualTo(AutoRouteCard.minInputWidth),
        reason: '窄屏下输入框宽度不应低于 ${AutoRouteCard.minInputWidth}px（实测 $width）',
      );
      expect(tester.takeException(), isNull, reason: '窄屏排布不应溢出');

      await _stop(tester, state);
    });

    testWidgets('宽屏（桌面）下仍是一行，且输入框仍够宽', (WidgetTester tester) async {
      final state = stateWithRealCore();
      addTearDown(state.dispose);
      await renderDesktopWithCore(tester, state);

      expect(inputBox(), findsOneWidget);
      final width = tester.getSize(inputBox()).width;
      expect(
        width,
        greaterThanOrEqualTo(AutoRouteCard.minInputWidth),
        reason: '宽屏下输入框也应满足最小宽度（实测 $width）',
      );
      // 宽屏走一行排布：输入框与选择器在同一水平线上。
      final segmentedY = tester.getCenter(find.text('走代理')).dy;
      expect(
        (tester.getCenter(inputBox()).dy - segmentedY).abs(),
        lessThan(4),
        reason: '宽屏应为一行排布',
      );

      await _stop(tester, state);
    });

    testWidgets('窄屏下走向选择器独占一行且铺满', (WidgetTester tester) async {
      final state = stateWithRealCore();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(390, 900));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      var guard = 0;
      while (inputBox().evaluate().isEmpty && guard < 30) {
        await tester.drag(scrollable, const Offset(0, -220));
        await tester.pumpAndSettle();
        guard++;
      }

      expect(inputBox(), findsOneWidget);
      final fieldTop = tester.getTopLeft(inputBox()).dy;
      final segmentedBottom = tester.getBottomLeft(find.text('走代理')).dy;
      expect(
        segmentedBottom,
        lessThanOrEqualTo(fieldTop + 1),
        reason: '窄屏下选择器应位于输入框上方（分成两行）',
      );

      await _stop(tester, state);
    });

    testWidgets('同一行里输入框、选择器、按钮三者等高', (WidgetTester tester) async {
      // 回归用例：这三者此前分别是 41 / 32 / 36 三种高度，摆在一行里参差不齐。
      // 41 也不是谁定的，而是 TextField 在当前字号下的自然高度——「高度」此前
      // 根本没有被决定过。现在统一由 XvControlMetrics.height 收口。
      final state = stateWithRealCore();
      addTearDown(state.dispose);
      await renderDesktopWithCore(tester, state);

      const expected = XvControlMetrics.height;
      final fieldHeight = tester.getSize(inputBox()).height;
      final buttonHeight = tester
          .getSize(find.widgetWithText(XvButton, '添加'))
          .height;
      final pickerHeight = tester
          .getSize(
            find.descendant(
              of: find.byType(AutoRouteCard),
              matching: find.byType(XvSegmented),
            ),
          )
          .height;

      expect(fieldHeight, expected, reason: '输入框高度应为标准控件高度');
      expect(buttonHeight, expected, reason: '按钮高度应为标准控件高度');
      expect(pickerHeight, expected, reason: '选择器高度应为标准控件高度');

      // 顶边也要对齐：等高但错位一样难看。
      final fieldTop = tester.getTopLeft(inputBox()).dy;
      final buttonTop = tester
          .getTopLeft(find.widgetWithText(XvButton, '添加'))
          .dy;
      expect(buttonTop, closeTo(fieldTop, 1), reason: '同一行控件顶边应对齐');

      await _stop(tester, state);
    });
  });

  group('配置模块的导入入口', () {
    /// 两条导入路径的标题。它们必须**同时存在且规格一致**——
    /// 原先它们散落在三处、权重也各不相同（一个大按钮 + 一行弱化文字链），
    /// 因此这里既断言「都在」，也断言「排布关系」。
    const fileTitle = '选择配置文件';
    const manualTitle = '手动填写';

    testWidgets('桌面端：有配置时两条路径同在一张卡里，并排', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(1400, 900));
      await _connect(tester, state);

      await tester.tap(find.text('配置文件'));
      await tester.pumpAndSettle();

      expect(find.text(fileTitle), findsOneWidget);
      expect(find.text(manualTitle), findsOneWidget);
      // 并排：两者的垂直中心基本一致。
      final fileY = tester.getCenter(find.text(fileTitle)).dy;
      final manualY = tester.getCenter(find.text(manualTitle)).dy;
      expect(
        (fileY - manualY).abs(),
        lessThan(4),
        reason: '宽屏下两条路径应并排在一行，而不是上下割裂',
      );
      // 同规格：两个入口块高度一致。
      expect(
        tester.getSize(find.byType(ImportActionTile).first).height,
        closeTo(tester.getSize(find.byType(ImportActionTile).last).height, 1),
      );

      await _stop(tester, state);
    });

    testWidgets('桌面端：没有配置时两条路径同样可达', (WidgetTester tester) async {
      // 这是原来最割裂的一处：空状态只给「选择 .conf 文件」，粘贴要切到
      // 别的入口或干脆找不到。现在两条路径都不随状态消失。
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(1400, 900));

      await tester.tap(find.text('配置文件'));
      await tester.pumpAndSettle();

      expect(find.text(fileTitle), findsOneWidget);
      expect(find.text(manualTitle), findsOneWidget);
      expect(find.byType(ImportActionTile), findsNWidgets(2));

      await _stop(tester, state);
    });

    testWidgets('移动端：两条路径竖排，且都在设置页的配置卡内', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(390, 900));

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      var guard = 0;
      while (find.text(fileTitle).evaluate().isEmpty && guard < 30) {
        await tester.drag(scrollable, const Offset(0, -200));
        await tester.pumpAndSettle();
        guard++;
      }

      expect(find.text(fileTitle), findsOneWidget);
      expect(find.text(manualTitle), findsOneWidget);
      // 窄屏竖排：手填入口在选文件入口下方。
      expect(
        tester.getTopLeft(find.text(manualTitle)).dy,
        greaterThan(tester.getTopLeft(find.text(fileTitle)).dy),
        reason: '窄屏下应竖排，避免说明被压成多行',
      );
      expect(tester.takeException(), isNull);

      await _stop(tester, state);
    });

    testWidgets('手动填写入口确实打开手填表单', (WidgetTester tester) async {
      // 光有入口不够，要确认它接的是手填流程而不是被画成了装饰。
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(1400, 900));

      await tester.tap(find.text('配置文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(manualTitle));
      await tester.pumpAndSettle();

      expect(find.text('手动添加配置'), findsOneWidget);

      await tester.tap(find.widgetWithText(XvButton, '取消'));
      await tester.pumpAndSettle();
      await _stop(tester, state);
    });

    testWidgets('删除配置后导入入口仍然在，不会退回没有入口的空状态', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await _pump(tester, state, size: const Size(1400, 900));
      await _connect(tester, state);

      await tester.tap(find.text('配置文件'));
      await tester.pumpAndSettle();
      state.removeProfile(state.profiles.first.id);
      await tester.pumpAndSettle();

      expect(find.text('还没有导入任何配置'), findsOneWidget);
      expect(find.text(fileTitle), findsOneWidget, reason: '空状态下入口不应消失');
      expect(find.text(manualTitle), findsOneWidget);

      await _stop(tester, state);
    });
  });

  group('观测引擎：一轮采样的真实上报', () {
    test('按出站拆分字节、统计活连接数、上报内核内存', () async {
      // 这是界面上所有统计数字的唯一来源，因此直接喂一份内核风格的响应，
      // 断言 CoreMonitor 到底上报了什么。只靠读代码确认等于没测。
      final payload = jsonEncode(<String, Object?>{
        'downloadTotal': 10000,
        'uploadTotal': 2000,
        'memory': 65536,
        'connections': <Object?>[
          <String, Object?>{
            'id': 'vpn-1',
            'metadata': <String, Object?>{
              'host': 'www.google.com',
              'destinationPort': '443',
            },
            'chains': <String>['vpn'],
            'rule': 'final',
            'upload': 1000,
            'download': 3000,
          },
          <String, Object?>{
            'id': 'direct-1',
            'metadata': <String, Object?>{
              'host': 'www.baidu.com',
              'destinationPort': '443',
            },
            'chains': <String>['direct'],
            'rule': 'rule_set=[geosite-cn geoip-cn] => route',
            'upload': 500,
            'download': 1500,
          },
        ],
      });

      final listener = RecordingListener();
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: listener,
          clashApiPort: 2081,
          probesEnabled: false,
          httpClient: _FakeClashClient(payload),
        ),
      );
      addTearDown(monitor.dispose);

      // 第一次采样只建立速率基准，因此要先跑两次。
      //
      // 两次之间必须真的隔开一点时间：速率是「两次累计值之差 ÷ 时间差」，
      // 而这里的假 HTTP 客户端是瞬时返回的，同一毫秒内连着采两次的时间差为 0，
      // 计算器会（正确地）返回 null——不隔开的话这条用例会变成一个偶发失败。
      await monitor.tick();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await monitor.tick();

      final traffic = listener.lastTraffic;
      expect(traffic, isNotNull, reason: '第二次采样必须上报流量');
      expect(traffic!.proxiedBytes, 4000, reason: '走隧道的是 vpn-1');
      expect(traffic.directBytes, 2000, reason: '走直连的是 direct-1');
      expect(traffic.connectionCount, 2);
      expect(traffic.kernelMemory, 65536, reason: '内核内存用于自查大数据量压力');
      expect(traffic.totalBytes, 12000);

      // 分流记录：两条新连接，规则名已归一化。
      expect(
        listener.records.map((SplitRecord r) => r.target).toSet(),
        <String>{'www.google.com', 'www.baidu.com'},
      );
      expect(
        listener.records
            .firstWhere((SplitRecord r) => r.target == 'www.baidu.com')
            .rule,
        'geosite-cn + geoip-cn',
        reason: '内核给的是整句描述，界面必须拿到归一化后的名字',
      );

      // 稳态：同一条连接不该被重复上报。
      final before = listener.records.length;
      await monitor.tick();
      expect(listener.records.length, before, reason: '已上报过的连接不该重复记');
    });
  });
}

/// 一个只返回固定正文的假 Clash API 客户端。
///
/// 用于让观测引擎跑完整的「取数 → 解析 → 上报」链路，而不真的去连回环端口。
class _FakeClashClient implements HttpClient {
  _FakeClashClient(this.body);

  final String body;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(body);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.body);

  final String body;

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(String body) : _bytes = utf8.encode(body);

  final List<int> _bytes;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
