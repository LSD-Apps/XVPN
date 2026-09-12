import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/dns_monitor.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/common.dart';

const _conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ==
Address = 10.0.0.3/32
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = vpn.example.net:51820
AllowedIPs = 0.0.0.0/0
''';

/// 「DNS」这一行的颜色必须与它写的文字是同一件事。
///
/// 这组锁定的是一个真实存在过的观感问题：颜色用的是「**任何**一次失败就变黄」，
/// 而文字用的是「连续两次全失败才算异常」。探测走明文 UDP，丢一个包很正常，
/// 于是最常见的画面是**文字写着「一致」、整行却是黄的**——用户只能得出
/// 「这软件一直报错」，然后去改一个本来没问题的设置。
///
/// 现在颜色与文字共用同一个门槛（[ResolverHealth.downThreshold]）。
void main() {
  Future<void> stop(WidgetTester tester, AppState state) async {
    // 演示内核有周期性定时器，不停掉会在结束时报「仍有定时器未完成」。
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  Future<AppState> pumpConnect(WidgetTester tester) async {
    final state = AppState(coreFactory: (VpnCoreListener l) => DemoVpnCore(l));
    tester.view.physicalSize = const Size(1500, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: XvShell(state: state, theme: ThemeController()),
      ),
    );
    await tester.pumpAndSettle();
    state.importConf(text: _conf, fileName: 'wg.conf');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    state.onStatusChanged(VpnStatus.connected);
    await tester.pumpAndSettle();
    return state;
  }

  /// 找到「DNS」那一行的 CheckRow。
  CheckRow dnsRow(WidgetTester tester) {
    final rows = tester
        .widgetList<CheckRow>(find.byType(CheckRow))
        .where((CheckRow r) => r.title.startsWith('DNS'))
        .toList();
    expect(rows, hasLength(1), reason: '应当恰好有一行 DNS 状态');
    return rows.single;
  }

  DnsReport reportWith({
    required int consecutiveFailures,
    required DnsVerdict verdict,
  }) => DnsReport(
    checkedAt: DateTime(2026, 9, 12),
    resolvers: <ResolverHealth>[
      ResolverHealth(
        server: '223.5.5.5',
        role: '直连',
        samples: 5,
        failures: consecutiveFailures,
        consecutiveFailures: consecutiveFailures,
        lastMillis: consecutiveFailures == 0 ? 12 : null,
        lastSummary: consecutiveFailures == 0 ? '183.2.172.177' : '解析超时',
        lastCheckedAt: DateTime(2026, 9, 12),
      ),
    ],
    direct: LatencyWindow(capacity: 4)..add(12),
    tunnel: LatencyWindow(capacity: 4)..add(96),
    verdict: verdict,
  );

  testWidgets('单次丢包不该让 DNS 这一行变黄', (WidgetTester tester) async {
    final state = await pumpConnect(tester);
    state.onDnsReport(
      reportWith(consecutiveFailures: 1, verdict: DnsVerdict.consistent),
    );
    await tester.pump();

    expect(find.textContaining('DNS ·'), findsOneWidget);
    expect(dnsRow(tester).warn, isFalse, reason: '一次失败只是丢包，此时文字是「一致」，颜色不该报警');
    await stop(tester, state);
  });

  testWidgets('连续失败到门槛后必须变黄', (WidgetTester tester) async {
    final state = await pumpConnect(tester);
    state.onDnsReport(
      reportWith(
        consecutiveFailures: ResolverHealth.downThreshold,
        verdict: DnsVerdict.directResolverDown,
      ),
    );
    await tester.pump();

    expect(find.textContaining('国内解析异常'), findsOneWidget);
    expect(dnsRow(tester).warn, isTrue, reason: '解析器确实不响应了，这一行必须报警');
    await stop(tester, state);
  });

  testWidgets('疑似投毒必须变黄', (WidgetTester tester) async {
    final state = await pumpConnect(tester);
    state.onDnsReport(
      reportWith(consecutiveFailures: 0, verdict: DnsVerdict.suspectPoisoning),
    );
    await tester.pump();

    expect(find.textContaining('疑似投毒'), findsOneWidget);
    expect(dnsRow(tester).warn, isTrue);
    await stop(tester, state);
  });

  testWidgets('一切正常时不报警', (WidgetTester tester) async {
    final state = await pumpConnect(tester);
    state.onDnsReport(
      reportWith(consecutiveFailures: 0, verdict: DnsVerdict.consistent),
    );
    await tester.pump();

    expect(dnsRow(tester).warn, isFalse);
    await stop(tester, state);
  });

  testWidgets('DNS 明细必须能打开，并显示每个解析器的原始证据', (WidgetTester tester) async {
    // 这条守的是「采集到了却没人看得到」：解析器地址、最近耗时、失败次数
    // 都算了出来，但此前没有任何界面读取它们——于是「为什么慢」在产品里
    // 根本问不出来。明细弹窗是这些字段唯一的出口。
    final state = await pumpConnect(tester);
    state.onDnsReport(
      reportWith(consecutiveFailures: 0, verdict: DnsVerdict.consistent),
    );
    await tester.pump();

    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();

    expect(find.text('DNS 明细'), findsOneWidget);
    // 解析器地址与它的状态、耗时、失败计数。
    expect(find.textContaining('223.5.5.5'), findsWidgets);
    expect(find.textContaining('正常'), findsWidgets);
    expect(find.textContaining('失败 0/5'), findsWidgets);
    // 两个方向的耗时窗口。
    expect(find.text('直连解析'), findsOneWidget);
    expect(find.textContaining('中位 12ms'), findsWidgets);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await stop(tester, state);
  });
}
