import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/connect_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/connect_ring.dart';

/// 取消入口在界面上的表达。
///
/// 锁两件事：连接中 / 建立隧道中主控件**可点**，且用户一眼能看出点它是「取消」
/// （此前圆环在 connecting 时直接传 null，点不动；按钮也是禁用态）。
///
/// 单开一个文件：widget 测试会初始化测试 binding，而它会拦掉真实 HTTP，
/// `connect_cancel_test.dart` 里那条真实内核用例就跑不完了。
const _conf = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/0
''';

Future<void> _pumpConnect(
  WidgetTester tester,
  AppState state, {
  required bool compact,
}) async {
  tester.view.physicalSize = compact
      ? const Size(390, 844)
      : const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildXvTheme(XvPalette.dark),
      home: Scaffold(
        // 真实外壳会把页面包在可监听 state 的构建器里；这里照做，
        // 否则 notifyListeners 不会让页面重建。
        body: ListenableBuilder(
          listenable: state,
          builder: (BuildContext context, Widget? child) =>
              ConnectScreen(state: state, compact: compact),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => applyPalette(XvPalette.dark));

  testWidgets('移动端连接中：圆环可点且标注「点击取消」，点击后回到未连接', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
    state.importConf(text: _conf, fileName: 'wg.conf');
    await _pumpConnect(tester, state, compact: true);

    expect(find.text('未连接'), findsOneWidget);
    await tester.tap(find.byType(ConnectRing));
    await tester.pump();
    expect(state.status, VpnStatus.connecting);

    // 连接中：圆环仍可点，且明确写出这是取消动作。
    expect(find.text('连接中…'), findsOneWidget);
    expect(find.text('点击取消'), findsOneWidget);

    await tester.tap(find.byType(ConnectRing));
    await tester.pump();
    expect(state.status, VpnStatus.disconnected);
    expect(state.lastError, isNull);
    // 推过演示内核那 700ms，确认被取代的续跑不会把状态翻回已连接。
    await tester.pump(const Duration(seconds: 1));
    expect(state.status, VpnStatus.disconnected);
  });

  testWidgets('桌面端连接中：主按钮变成「取消连接」', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
    state.importConf(text: _conf, fileName: 'wg.conf');
    await _pumpConnect(tester, state, compact: false);

    expect(find.text('连接'), findsOneWidget);
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(state.status, VpnStatus.connecting);
    expect(find.text('取消连接'), findsOneWidget);
    expect(find.text('点击取消'), findsOneWidget);

    await tester.tap(find.text('取消连接'));
    await tester.pump();
    expect(state.status, VpnStatus.disconnected);
    await tester.pump(const Duration(seconds: 1));
    expect(state.status, VpnStatus.disconnected);
    // 回到未连接态后按钮也回到「连接」。
    expect(find.text('连接'), findsOneWidget);
  });

  testWidgets('建立隧道中：文案仍是「正在建立隧道…」，但可以取消', (WidgetTester tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
    state.importConf(text: _conf, fileName: 'wg.conf');
    await _pumpConnect(tester, state, compact: false);

    // 直接制造预热态：预热与连接中对主控件的诉求一致（都可取消）。
    state.onStatusChanged(VpnStatus.warmingUp);
    await tester.pump();
    expect(find.text('正在建立隧道…'), findsOneWidget);
    expect(find.text('点击取消'), findsOneWidget);

    await tester.tap(find.byType(ConnectRing));
    await tester.pump();
    expect(state.status, VpnStatus.disconnected, reason: '预热期间取消必须真的生效');
    expect(state.lastError, isNull);
  });
}
