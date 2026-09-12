import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
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
  /// 造一个已导入配置但**未连接**的状态。
  ///
  /// 刻意不连接：内核日志最该被看到的时刻恰恰是没连上的时候。
  Future<AppState> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    // 关掉「导入后自动连接」：演示内核一连上就会起每秒刷新的定时器，而这里
    // 的断言只关心日志视图——何况本组用例刻意要在**未连接**状态下验证。
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

  testWidgets('没有日志时不占位置', (WidgetTester tester) async {
    final state = await pumpShell(tester);

    expect(find.textContaining('内核日志'), findsNothing);

    await teardown(tester, state);
  });

  testWidgets('有日志时显示行数与最后一行，未连接也照常显示', (WidgetTester tester) async {
    final state = await pumpShell(tester);

    state.core.handleCoreLog('WARN outbound/vpn: handshake timeout');
    await tester.pump();

    expect(find.text('内核日志 1 行'), findsOneWidget);
    expect(
      find.text('WARN outbound/vpn: handshake timeout'),
      findsOneWidget,
      reason: '卡片里先给最后一行——多数时候它就是结论',
    );

    state.core.handleCoreLog('ERROR dial failed');
    await tester.pump();
    expect(find.text('内核日志 2 行'), findsOneWidget);
    expect(find.text('ERROR dial failed'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('丢弃早期日志时如实说明', (WidgetTester tester) async {
    final state = await pumpShell(tester);

    // 缓冲默认 500 行，这里灌满并溢出。
    for (var i = 0; i < 505; i++) {
      state.core.handleCoreLog('第 $i 行');
    }
    await tester.pump();

    expect(find.textContaining('内核日志 500 行'), findsOneWidget);
    expect(
      find.textContaining('更早的 5 行已滚出'),
      findsOneWidget,
      reason: '不说明的话，用户会以为问题就发生在日志开头那一行',
    );

    await teardown(tester, state);
  });

  testWidgets('弹窗里能看完整日志、复制全部、清空', (WidgetTester tester) async {
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
    state.core.handleCoreLog('第一行');
    state.core.handleCoreLog('第二行');
    await tester.pump();

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();

    expect(find.text('内核日志'), findsWidgets);
    expect(find.text('第一行\n第二行'), findsOneWidget, reason: '完整内容要能看到并可以选中');
    expect(find.text('2 行'), findsOneWidget);

    await tester.tap(find.text('复制全部'));
    await tester.pumpAndSettle();
    expect(clipboard.single, '第一行\n第二行', reason: '手抄几百行日志不现实，复制是这里最重要的动作');

    // 复制后弹窗自动关闭，重新打开来验证清空。
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(state.kernelLog, isEmpty);
    expect(find.text('（暂无日志）'), findsOneWidget, reason: '清空后弹窗还在，要给出空态而不是一片空白');

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('内核日志'), findsNothing, reason: '没有日志了，入口也该收起来');

    await teardown(tester, state);
  });
}
