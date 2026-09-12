import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';

const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32
DNS = 223.5.5.5
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0, ::/0
''';

void main() {
  Future<AppState> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 用真实内核（关掉主动探测）：演示内核没有自动纠正表，
    // 而「一键改走代理」要写的正是那张表——用演示内核测等于测了个寂寞。
    final state = AppState(
      coreFactory: (VpnCoreListener listener) =>
          SingBoxRunner(listener, probesEnabled: false),
    );
    state.updateSettings(const AppSettings(autoConnectOnImport: false));
    state.importConf(text: _conf, fileName: 'wg-hk-01.conf');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: XvShell(state: state, theme: ThemeController()),
      ),
    );
    return state;
  }

  Future<void> teardown(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  void fail(
    WidgetTester tester,
    AppState state,
    String target, {
    String outbound = 'direct',
  }) {
    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime(2026, 2, 14, 12),
        target: target,
        outbound: outbound,
        reason: 'dial tcp: i/o timeout',
      ),
    );
  }

  testWidgets('没有失败时不显示诊断行，也就没有详情入口', (WidgetTester tester) async {
    final state = await pumpShell(tester);

    expect(find.text('详情'), findsNothing);

    await teardown(tester, state);
  });

  testWidgets('失败后会给出诊断结论与详情入口', (WidgetTester tester) async {
    final state = await pumpShell(tester);

    fail(tester, state, 'blocked.example.com:443');
    await tester.pump();

    expect(find.textContaining('疑似规则未覆盖'), findsWidgets);
    expect(find.text('详情'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('详情里能看到分组，并能把可疑域名一键改为走代理', (WidgetTester tester) async {
    final state = await pumpShell(tester);
    fail(tester, state, 'blocked.example.com:443');
    fail(tester, state, 'blocked.example.com:443');
    fail(tester, state, '8.8.8.8:53', outbound: 'vpn');
    await tester.pump();

    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();

    // 断言一律限定在弹窗内：诊断行本身也会列出可疑域名，不限定就会把
    // 「弹窗里有一份」和「背后的行里也有一份」混在一起数成两个。
    Finder inDialog(Finder matching) =>
        find.descendant(of: find.byType(Dialog), matching: matching);

    // 分组：同一目标两次算一组，并显示次数与方向。
    expect(inDialog(find.text('blocked.example.com')), findsOneWidget);
    expect(inDialog(find.text('×2')), findsOneWidget);
    expect(inDialog(find.text('直连失败')), findsOneWidget);
    expect(inDialog(find.text('8.8.8.8')), findsOneWidget);
    expect(inDialog(find.text('隧道失败')), findsOneWidget);

    // 只有「疑似规则未覆盖」的那一组给出「改走代理」。
    expect(
      inDialog(find.text('改走代理')),
      findsOneWidget,
      reason: 'IP 目标与走隧道的失败都不该出现这个入口——改了也没用',
    );

    await tester.tap(find.text('改走代理'));
    await tester.pumpAndSettle();

    expect(
      state.autoRoute?.match('blocked.example.com'),
      isNotNull,
      reason: '一键改判要真的写进自动纠正表，否则用户白点',
    );
    // 处理过之后不再重复给入口。
    expect(inDialog(find.text('改走代理')), findsNothing);
    expect(inDialog(find.text('已指定走向')), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('可以复制整份失败记录', (WidgetTester tester) async {
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

    final state = await pumpShell(tester);
    fail(tester, state, 'blocked.example.com:443');
    await tester.pump();

    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制记录'));
    await tester.pumpAndSettle();

    expect(clipboard.single, contains('blocked.example.com'));
    expect(clipboard.single, contains('疑似规则未覆盖'));
    expect(clipboard.single, contains('最后原因：dial tcp: i/o timeout'));

    await teardown(tester, state);
  });

  testWidgets('清空只清失败记录，不动分流记录', (WidgetTester tester) async {
    final state = await pumpShell(tester);
    fail(tester, state, 'blocked.example.com:443');
    state.onSplitRecord(
      SplitRecord(
        time: DateTime(2026, 2, 14, 12),
        target: 'www.google.com:443',
        kind: RouteKind.proxy,
        rule: '默认',
        outbound: 'vpn',
      ),
    );
    await tester.pump();

    expect(state.failures, hasLength(1));
    expect(state.records, hasLength(1));

    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(state.failures, isEmpty);
    expect(
      state.records,
      hasLength(1),
      reason: '用户在失败面板点清空，意思是「这一批我看过了」，不该顺手清掉分流记录',
    );

    await teardown(tester, state);
  });
}
