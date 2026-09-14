import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/split_screen.dart';
import 'package:xvpn/theme.dart';

const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.0.0.3/32

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 1.2.3.4:51820
''';

/// 分流记录页上的「连接汇总」。
///
/// 这一块存在的理由是**关联**：判定出问题时，用户下一个问题是「规则判错了还是
/// 节点不通」，而回答它需要延迟与失败记录同屏——同一个目标反复失败、且延迟同时
/// 变差，多半是节点的问题；只有直连失败、延迟正常，才是规则的事。
void main() {
  AppState newState() {
    final state = AppState(
      coreFactory: (VpnCoreListener listener) =>
          SingBoxRunner(listener, probesEnabled: false),
    );
    state.updateSettings(const AppSettings(autoConnectOnImport: false));
    state.importConf(text: _conf, fileName: 'wg.conf');
    return state;
  }

  Future<void> pump(
    WidgetTester tester,
    AppState state, {
    bool compact = false,
  }) async {
    tester.view.physicalSize = compact
        ? const Size(780, 360)
        : const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Scaffold(
          body: SplitScreen(state: state, compact: compact),
        ),
      ),
    );
  }

  Future<void> teardown(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  testWidgets('没有失败时如实说明，且不给失败详情入口', (WidgetTester tester) async {
    final state = newState();
    await pump(tester, state);

    expect(find.text('连接汇总'), findsOneWidget);
    expect(find.textContaining('连接失败：暂无'), findsOneWidget);
    expect(find.textContaining('本次连接'), findsOneWidget);
    expect(find.textContaining('尚无隧道/直连拆分'), findsOneWidget);
    expect(find.text('失败详情'), findsNothing);

    await teardown(tester, state);
  });

  testWidgets('有隧道/直连拆分时展示占比，并说明与总量口径不同', (
    WidgetTester tester,
  ) async {
    final state = newState();
    state.onTraffic(downBps: 0, upBps: 0, totalBytes: 50 * 1024);
    state.onConnectionTraffic(
      const ConnectionTraffic(
        target: 'a.example',
        kind: RouteKind.proxy,
        uploadDelta: 0,
        downloadDelta: 30 * 1024,
      ),
    );
    state.onConnectionTraffic(
      const ConnectionTraffic(
        target: 'b.example',
        kind: RouteKind.direct,
        uploadDelta: 0,
        downloadDelta: 10 * 1024,
      ),
    );
    await pump(tester, state);

    expect(find.textContaining('本次连接：50KB'), findsOneWidget);
    expect(find.textContaining('隧道 30KB'), findsOneWidget);
    expect(find.textContaining('约 75% 走隧道'), findsOneWidget);
    expect(find.textContaining('可能略少于上方总量'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('延迟与失败数都出现在汇总里', (WidgetTester tester) async {
    final state = newState();
    state.onLatency(42);
    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime(2026, 2, 14, 12),
        target: 'blocked.example.com:443',
        outbound: 'direct',
        reason: 'dial tcp: i/o timeout',
      ),
    );
    await pump(tester, state);

    expect(find.textContaining('延迟：42 ms'), findsOneWidget);
    expect(find.textContaining('连接失败：1 条'), findsOneWidget);
    expect(find.textContaining('直连 1'), findsOneWidget);
    // 可疑域名要直接摆出来：它是「该改规则」的唯一线索。
    expect(find.textContaining('blocked.example.com'), findsWidgets);

    await teardown(tester, state);
  });

  testWidgets('失败详情入口打开完整记录，并能一键改走代理', (WidgetTester tester) async {
    final state = newState();
    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime(2026, 2, 14, 12),
        target: 'blocked.example.com:443',
        outbound: 'direct',
        reason: 'dial tcp: i/o timeout',
      ),
    );
    await pump(tester, state);

    await tester.tap(find.text('失败详情'));
    await tester.pumpAndSettle();

    expect(find.text('连接失败记录'), findsOneWidget);
    await tester.tap(find.text('改走代理'));
    await tester.pumpAndSettle();

    expect(
      state.autoRoute?.match('blocked.example.com'),
      isNotNull,
      reason: '从汇总点进详情再改判，是这条链路存在的意义',
    );

    await teardown(tester, state);
  });

  testWidgets('移动端用单行汇总：矮屏下不溢出', (WidgetTester tester) async {
    // 手机横屏可用高度只有三百来点，三行汇总会把列表挤到溢出。
    final state = newState();
    state.onLatency(38);
    state.onConnectionFailure(
      ConnectionFailure(
        time: DateTime(2026, 2, 14, 12),
        target: 'a.example.com:443',
        outbound: 'direct',
        reason: 'dial tcp: i/o timeout',
      ),
    );
    await pump(tester, state, compact: true);

    expect(find.textContaining('延迟 38 ms'), findsOneWidget);
    expect(find.textContaining('连接失败 1 条'), findsOneWidget);
    expect(find.text('连接汇总'), findsNothing, reason: '紧凑版不带标题，省下的正是矮屏最缺的高度');
    expect(tester.takeException(), isNull);

    await teardown(tester, state);
  });
}
