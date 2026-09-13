import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/tunnel_report.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/tunnel_volume_card.dart';

SplitRecord _record({
  required String target,
  required RouteKind kind,
  int bytes = 0,
  int connections = 1,
  int failures = 0,
  String rule = 'final',
}) {
  return SplitRecord(
    time: DateTime(2026, 2, 14),
    target: target,
    kind: kind,
    rule: rule,
    outbound: kind == RouteKind.proxy ? 'vpn' : 'direct',
    uploadBytes: bytes ~/ 4,
    downloadBytes: bytes - bytes ~/ 4,
    connections: connections,
  )..failures = failures;
}

void main() {
  group('隧道流量去向排序', () {
    test('只统计走隧道的目标，直连不进清单', () {
      final entries = rankTunnelTargets(<SplitRecord>[
        _record(target: 'tunnel.example', kind: RouteKind.proxy, bytes: 100),
        _record(target: 'direct.example', kind: RouteKind.direct, bytes: 999),
      ]);
      expect(entries.map((TunnelVolumeEntry e) => e.target), <String>[
        'tunnel.example',
      ]);
    });

    test('按流量降序；流量相同时按连接数降序，再按目标名升序', () {
      final entries = rankTunnelTargets(<SplitRecord>[
        _record(target: 'small.example', kind: RouteKind.proxy, bytes: 10),
        _record(target: 'big.example', kind: RouteKind.proxy, bytes: 9999),
        // 与 medium-a 同流量，但连接数更多 → 靠前。
        _record(
          target: 'medium-b.example',
          kind: RouteKind.proxy,
          bytes: 100,
          connections: 9,
        ),
        _record(target: 'medium-a.example', kind: RouteKind.proxy, bytes: 100),
      ]);
      expect(
        entries.map((TunnelVolumeEntry e) => e.target),
        <String>[
          'big.example',
          'medium-b.example',
          'medium-a.example',
          'small.example',
        ],
        // 顺序必须稳定：同一份数据两次渲染次序不同会让界面莫名跳动。
      );
    });

    test('IP 目标不给「改为直连」动作，且域名归一化为空', () {
      final entries = rankTunnelTargets(<SplitRecord>[
        _record(target: '198.51.100.7:443', kind: RouteKind.proxy, bytes: 50),
      ]);
      expect(entries.single.domain, isEmpty);
      expect(
        entries.single.canPreferDirect,
        isFalse,
        reason: '按域名的规则对 IP 目标没有意义（自动纠正也一直只作用于域名）',
      );
    });

    test('带端口的目标归一化成域名，可以给出动作', () {
      final entries = rankTunnelTargets(<SplitRecord>[
        _record(target: 'Blocked.Example.COM:443', kind: RouteKind.proxy, bytes: 50),
      ]);
      expect(entries.single.domain, 'blocked.example.com');
      expect(entries.single.canPreferDirect, isTrue);
    });

    test('已有用户规则的目标不再给动作，但已有程序规则仍给', () {
      final table = AutoRouteTable()
        ..setUserRule('user.example', RoutePreference.forceProxy)
        ..recordDirectFailure(
          'learned.example',
          reason: '连接超时',
          dnsVerdict: 'suspectPoisoning',
        );
      final entries = rankTunnelTargets(
        <SplitRecord>[
          _record(target: 'user.example', kind: RouteKind.proxy, bytes: 10),
          _record(target: 'learned.example', kind: RouteKind.proxy, bytes: 10),
          _record(target: 'plain.example', kind: RouteKind.proxy, bytes: 10),
        ],
        table: table,
      );
      final byTarget = <String, TunnelVolumeEntry>{
        for (final entry in entries) entry.target: entry,
      };
      expect(
        byTarget['user.example']!.canPreferDirect,
        isFalse,
        reason: '不该给一个会覆盖用户明确决定的操作',
      );
      expect(byTarget['learned.example']!.canPreferDirect, isTrue);
      expect(byTarget['learned.example']!.hasRule, isTrue);
      expect(byTarget['plain.example']!.hasRule, isFalse);
    });

    test('limit 截断到前 N 条', () {
      final entries = rankTunnelTargets(
        <SplitRecord>[
          for (var i = 0; i < 10; i++)
            _record(
              target: 'host$i.example',
              kind: RouteKind.proxy,
              bytes: i * 10,
            ),
        ],
        limit: 3,
      );
      expect(entries, hasLength(3));
      expect(entries.first.target, 'host9.example');
    });

    test('合计只算走隧道的字节', () {
      expect(
        tunnelVolumeTotal(<SplitRecord>[
          _record(target: 'a', kind: RouteKind.proxy, bytes: 100),
          _record(target: 'b', kind: RouteKind.direct, bytes: 500),
          _record(target: 'c', kind: RouteKind.proxy, bytes: 25),
        ]),
        125,
      );
    });
  });

  group('隧道流量去向卡片', () {
    /// 带真实内核状态的状态对象：`setDomainPreference` 需要有自动纠正表。
    AppState newState() => AppState(
      coreFactory: (VpnCoreListener l) => SingBoxRunner(l, probesEnabled: false),
    );

    /// 造一条分流记录并累加流量。行由 [AppState.onSplitRecord] 建，字节由
    /// [AppState.onConnectionTraffic] 累加——与真实链路完全同一条路径。
    void observe(AppState state, String target, int bytes, RouteKind kind) {
      state.onSplitRecord(
        SplitRecord(
          time: DateTime(2026, 2, 14),
          target: target,
          kind: kind,
          rule: 'final',
          outbound: kind == RouteKind.proxy ? 'vpn' : 'direct',
        ),
      );
      state.onConnectionTraffic(
        ConnectionTraffic(
          target: target,
          kind: kind,
          uploadDelta: bytes ~/ 4,
          downloadDelta: bytes - bytes ~/ 4,
        ),
      );
    }

    testWidgets('列出走隧道目标，一键改为直连会真的写入规则', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      observe(state, 'cn-longtail.example', 4096, RouteKind.proxy);
      observe(state, 'overseas.example', 1024, RouteKind.proxy);
      observe(state, 'www.baidu.com', 999999, RouteKind.direct);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: state,
              builder: (BuildContext context, Widget? _) => SingleChildScrollView(
                child: TunnelVolumeCard(state: state, compact: false),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('隧道流量去向'), findsOneWidget);
      // 直连的流量不进这份清单：它回答的是「隧道被谁占了」。
      expect(find.text('www.baidu.com'), findsNothing);
      expect(find.text('cn-longtail.example'), findsOneWidget);
      // 流量多的排在前面。
      final firstRowY = tester.getTopLeft(find.text('cn-longtail.example')).dy;
      final secondRowY = tester.getTopLeft(find.text('overseas.example')).dy;
      expect(firstRowY, lessThan(secondRowY));

      await tester.tap(find.text('改为直连').first);
      await tester.pumpAndSettle();

      expect(
        state.autoRoute!.match('cn-longtail.example')!.preference,
        RoutePreference.forceDirect,
        reason: '「改为直连」必须真的落到规则表里，否则就是一个没反应的按钮',
      );
      expect(find.textContaining('下一次连接'), findsWidgets);
    });

    testWidgets('没有隧道流量时说明清单会在连接后出现', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            body: TunnelVolumeCard(state: state, compact: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有观察到走隧道的流量'), findsOneWidget);
      expect(find.text('改为直连'), findsNothing);
    });
  });
}
