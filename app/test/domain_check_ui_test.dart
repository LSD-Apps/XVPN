import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/dns_client.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/split_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/common.dart';

/// 桩解析器：查证会真的发 DNS 查询，而测试环境里不该连网。
///
/// 注意不能靠关掉主动探测来回避——「重测 / 查证」这类**用户主动发起**的探测
/// 与 DNS 监测、启动自检一致，不受 probesEnabled 限制（那个开关管的是「别在
/// 背后偷偷发流量」）。因此这里注入一个固定答案的解析器。
class _StubResolver implements DnsResolver {
  @override
  Future<DnsOutcome> query(
    String server,
    String domain, {
    Duration? timeout,
    int type = 1,
  }) async {
    return DnsOutcome(
      server: server,
      name: domain,
      answers: <String>['93.184.216.34'],
      elapsed: const Duration(milliseconds: 8),
    );
  }

  @override
  void close() {}
}

void main() {
  /// 造一个带真实内核（关主动探测）的状态。
  ///
  /// 用真实内核而不是演示内核：查证要读自动纠正表，而演示内核没有那张表，
  /// 「改为走代理」会静默失败——测试会通过却什么都没验证。
  ///
  /// probesEnabled 关掉是必须的：查证会真的发 DNS 查询，测试环境里不该连网。
  AppState newState() {
    final state = AppState(
      coreFactory: (VpnCoreListener listener) => SingBoxRunner(
        listener,
        probesEnabled: false,
        dnsResolver: _StubResolver(),
      ),
    );
    state.updateSettings(const AppSettings(autoConnectOnImport: false));
    return state;
  }

  Future<void> pumpScreen(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(body: SplitScreen(state: state, compact: false)),
      ),
    );
  }

  Future<void> teardown(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  /// 打开查证弹窗。
  ///
  /// 注意入口按钮的文字与弹窗标题相同，因此只能在弹窗还没打开时点它；
  /// 打开之后的断言一律限定在弹窗内——背景里还有一个搜索框，也是 TextField。
  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(XvButton, '查证域名'));
    await tester.pumpAndSettle();
  }

  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(Dialog), matching: matching);

  Finder dialogField() => find.descendant(
    of: find.byType(Dialog),
    matching: find.byType(TextField),
  );

  Future<void> query(WidgetTester tester, String domain) async {
    await tester.enterText(dialogField(), domain);
    await tester.tap(inDialog(find.text('查证')));
    await tester.pumpAndSettle();
  }

  testWidgets('可以查证一个已经观察过的域名', (WidgetTester tester) async {
    final state = newState();
    state.onSplitRecord(
      SplitRecord(
        time: DateTime(2026, 2, 14, 12),
        target: 'www.baidu.com:443',
        kind: RouteKind.direct,
        rule: 'geosite-cn + geoip-cn',
        outbound: 'direct',
      ),
    );
    await pumpScreen(tester, state);

    await openDialog(tester);
    await query(tester, 'www.baidu.com');

    expect(inDialog(find.textContaining('最近一次直连')), findsOneWidget);
    expect(inDialog(find.text('最近记录')), findsOneWidget);
    expect(
      inDialog(find.textContaining('geosite-cn + geoip-cn')),
      findsOneWidget,
    );

    await teardown(tester, state);
  });

  testWidgets('输入框预填当前搜索词', (WidgetTester tester) async {
    // 用户多半是先搜了域名、没得到想要的答案才来查证，让他再打一遍是多余的。
    final state = newState();
    await pumpScreen(tester, state);

    await tester.enterText(find.byType(TextField).first, 'pasted.example.com');
    await tester.pumpAndSettle();
    await openDialog(tester);

    final field = tester.widget<TextField>(dialogField());
    expect(field.controller?.text, 'pasted.example.com');

    await teardown(tester, state);
  });

  testWidgets('空输入时提示，并且不给复制', (WidgetTester tester) async {
    final state = newState();
    await pumpScreen(tester, state);

    await openDialog(tester);
    await tester.tap(inDialog(find.text('查证')));
    await tester.pumpAndSettle();

    expect(inDialog(find.text('请先填写域名')), findsOneWidget);
    final copyButton = tester.widget<XvButton>(
      find.ancestor(of: find.text('复制结论'), matching: find.byType(XvButton)),
    );
    expect(copyButton.onPressed, isNull, reason: '没有结论时不该能复制一段空话');

    await teardown(tester, state);
  });

  testWidgets('可以从查证结果直接改判走向', (WidgetTester tester) async {
    final state = newState();
    state.onSplitRecord(
      SplitRecord(
        time: DateTime(2026, 2, 14, 12),
        target: 'blocked.example.com:443',
        kind: RouteKind.direct,
        rule: 'geosite-cn + geoip-cn',
        outbound: 'direct',
      ),
    );
    await pumpScreen(tester, state);

    await openDialog(tester);
    await query(tester, 'blocked.example.com');

    await tester.tap(inDialog(find.text('改为走代理')));
    await tester.pumpAndSettle();

    expect(
      state.autoRoute?.match('blocked.example.com')?.preference,
      RoutePreference.forceProxy,
      reason: '从证据到处置不该需要用户记住域名再跑去别的页面手打一遍',
    );

    await teardown(tester, state);
  });

  testWidgets('关掉弹窗时不会用到已释放的输入控制器', (WidgetTester tester) async {
    // 这条守的是一类很容易复发的错误：showDialog 的 Future 在退场动画播完
    // 之前就已返回，若那一刻就释放 TextEditingController，动画里的输入框会
    // 用到已释放对象并抛异常。必须走完退场动画才暴露得出来。
    final state = newState();
    await pumpScreen(tester, state);

    await openDialog(tester);
    expect(find.byType(Dialog), findsOneWidget);

    await tester.tap(inDialog(find.text('关闭')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing, reason: '退场动画走完不该抛「控制器已被释放」');

    await teardown(tester, state);
  });

  testWidgets('可以复制结论', (WidgetTester tester) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final state = newState();
    await pumpScreen(tester, state);

    await openDialog(tester);
    await query(tester, 'a.example.com');
    await tester.tap(inDialog(find.text('复制结论')));
    await tester.pumpAndSettle();

    expect(clipboard.single, contains('a.example.com'));
    expect(
      clipboard.single,
      contains('DNS 对照'),
      reason: '复制出去的结论要带上判断依据，否则对方拿到一句话也无从复核',
    );

    await teardown(tester, state);
  });
}
