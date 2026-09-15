import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/connect_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/connect_ring.dart';

/// 连接失败在界面上的表达。
///
/// 锁的是两条：
///
///   1. **失败与未连接是两件事**。此前一次失败的尝试会让圆环退回中性灰并写着
///      「未连接」，与「从没点过连接」长得一模一样，而那条报错 SnackBar 四秒后
///      就消失了——用户回到屏幕前只看到一个不说话的圆环，既不知道失败了，也不知道
///      该怎么再来一次。
///   2. **主视线上只放一句人话**。内核的原始报错（`parse rule-set: open
///      /data/user/0/…: no such file or directory`）用户看不懂，也没有能做的事；
///      它改为收在「详情」里，台前一句话，幕后一个字不删。
///
/// 单开一个文件，理由同 `connect_cancel_ui_test.dart`：widget 测试会初始化
/// 测试 binding 并拦掉真实 HTTP。
///
/// 失败一律用 [failLikeCore] 直接喂回调，**不走**圆环触发的那次真实连接：
/// [DemoVpnCore] 的 connect 里有一个 700ms 的 `Future.delayed`，它在测试结束
/// 时若还没到点，框架会直接判「A Timer is still pending」——那是测试脚手架的
/// 噪音，会把真正要看的断言淹掉。只有「点击重试」那条必须真的点，它自己在末尾
/// 把这次尝试收干净。
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

/// 内核真实报过的那一句（安卓上默认启用的补充规则集漏解包时）。
const _kernelFailure =
    '内核启动失败：parse rule-set: open /data/user/0/app/files/rulesets/'
    'geosite-cn-extra.srs: no such file or directory';

/// 一份需要账号密码、而用户还没填的配置（OpenVPN 的 `auth-user-pass`）。
const _needCredsConf = '''
client
dev tun
proto udp
remote vpn.example.net 1194
auth-user-pass
cipher AES-256-CBC
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

Future<AppState> _stateWithProfile() async {
  final state = AppState();
  addTearDown(state.dispose);
  state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
  state.importConf(text: _conf, fileName: 'wg.conf');
  return state;
}

/// 同上一份，但换成「必须先填账号密码」的配置。
///
/// 两种失败在界面上的待遇不同，因此都得有：一种是内核已经试过并报了错（有原文
/// 可查），另一种是应用压根没去连（只有一句指令）。
Future<AppState> _stateNeedingCredentials() async {
  final state = AppState();
  addTearDown(state.dispose);
  state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
  state.importConf(text: _needCredsConf, fileName: 'need.ovpn');
  return state;
}

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

/// 一次失败的连接在监听器上长什么样：内核先报错，收尾时再广播已断开。
///
/// 顺序是照 `AndroidVpnCore._startTunnel` 抄的：`listener.onError(...)` 之后
/// 才是 `_teardown(notifyStatus: true)` 里的 `disconnected`。顺序反过来的话，
/// 错误会被「已断开」的清理逻辑撇下，正是这里要防的那一类失真。
void failLikeCore(AppState state, [String message = _kernelFailure]) {
  state.onStatusChanged(VpnStatus.connecting);
  state.onError(message);
  state.onStatusChanged(VpnStatus.disconnected);
}

void main() {
  setUp(() => applyPalette(XvPalette.dark));

  testWidgets('连接失败：圆环标出失败，旁边只给一句人话，内核原文不上主视线', (
    WidgetTester tester,
  ) async {
    final state = await _stateWithProfile();
    await _pumpConnect(tester, state, compact: true);
    expect(find.text('未连接'), findsOneWidget);

    failLikeCore(state);
    await tester.pump();

    expect(find.text('连接失败'), findsOneWidget);
    expect(
      find.text('未连接'),
      findsNothing,
      reason: '失败之后还写着「未连接」，等于把一次失败说成「什么都没发生过」',
    );
    expect(find.text('点击重试'), findsOneWidget);
    expect(
      find.text(connectFailureSummary),
      findsOneWidget,
      reason: '失败行要给一句用户读得懂的话，而不是什么都不说',
    );
    expect(
      find.textContaining('geosite-cn-extra.srs'),
      findsNothing,
      reason: '内核的原始报错不该占着主视线：用户看不懂，也没有能做的事',
    );
    expect(
      find.textContaining('no such file or directory'),
      findsNothing,
      reason: '同上：技术细节留在「详情」里',
    );
  });

  testWidgets('失败原文收在「详情」里：要拿它去反馈的人一步就能看到', (WidgetTester tester) async {
    final state = await _stateWithProfile();
    await _pumpConnect(tester, state, compact: true);

    failLikeCore(state);
    await tester.pump();

    expect(state.connectFailureDetail, _kernelFailure);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();

    expect(find.text('失败原因'), findsOneWidget);
    expect(
      find.textContaining('geosite-cn-extra.srs'),
      findsOneWidget,
      reason: '原文一个字都不能少：排查时它是唯一的事实来源',
    );

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('失败原因'), findsNothing);
    expect(
      find.textContaining('geosite-cn-extra.srs'),
      findsNothing,
      reason: '关掉之后又回到「台前只有一句人话」',
    );
  });

  testWidgets('需要账号密码时给的是指令，而不是一句泛泛的失败结论', (WidgetTester tester) async {
    final state = await _stateNeedingCredentials();
    await _pumpConnect(tester, state, compact: true);

    // 这条路径压根没去连（缺凭据就不该建隧道），因此没有内核原文可给。
    await state.connect();
    await tester.pump();

    expect(find.text('连接失败'), findsOneWidget);
    expect(
      find.textContaining('需要账号密码'),
      findsOneWidget,
      reason: '用户下一步该做什么必须写在屏幕上，否则他只会反复点重试',
    );
    expect(
      find.text('详情'),
      findsNothing,
      reason: '没有技术原文时摆一个点了没内容的入口，比不摆更糟',
    );
  });

  testWidgets('失败态点击圆环即重试：圆环立刻回到连接中，不再红着', (WidgetTester tester) async {
    final state = await _stateWithProfile();
    await _pumpConnect(tester, state, compact: true);

    failLikeCore(state);
    await tester.pump();
    expect(find.text('连接失败'), findsOneWidget);

    await tester.tap(find.byType(ConnectRing));
    await tester.pump();

    expect(state.status, VpnStatus.connecting);
    expect(find.text('连接中…'), findsOneWidget);
    expect(
      find.text('连接失败'),
      findsNothing,
      reason: '用户按下的动作没有即时反馈，他会以为这个按钮坏了',
    );

    // 收干净这次真实尝试，别把 700ms 未决定时器留给测试框架。
    await state.cancelConnect();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('「知道了」能撤掉失败态：不想重连的人不必被迫连一次', (WidgetTester tester) async {
    final state = await _stateWithProfile();
    await _pumpConnect(tester, state, compact: true);

    failLikeCore(state);
    await tester.pump();
    expect(find.text('连接失败'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pump();

    expect(state.connectFailure, isNull);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接失败'), findsNothing);
  });

  testWidgets('桌面端同样标出失败：不因为排布不同而少说一句', (WidgetTester tester) async {
    final state = await _stateWithProfile();
    await _pumpConnect(tester, state, compact: false);

    failLikeCore(state);
    await tester.pump();

    expect(find.text('连接失败'), findsOneWidget);
    expect(find.text(connectFailureSummary), findsOneWidget);
    expect(
      find.textContaining('no such file or directory'),
      findsNothing,
      reason: '两侧一视同仁：技术原文都不上主视线',
    );
  });

  testWidgets('与连接无关的错误不会把圆环染红', (WidgetTester tester) async {
    final state = await _stateWithProfile();
    await _pumpConnect(tester, state, compact: true);

    // 导入失败走的是 reportError，此时状态是「未连接」而非「连接中」。
    state.reportError('导入失败：这份配置的内容无法识别');
    await tester.pump();

    expect(state.lastError, isNotNull);
    expect(state.connectFailure, isNull);
    expect(find.text('连接失败'), findsNothing);
    expect(find.text('未连接'), findsOneWidget);
  });

  group('失败结论的留存与撤销不靠 SnackBar 的寿命', () {
    test('技术原文与那句人话同生共死', () async {
      final state = await _stateWithProfile();
      failLikeCore(state);
      expect(state.connectFailure, connectFailureSummary);
      expect(state.connectFailureDetail, _kernelFailure);

      // 撤掉结论的两条路都必须把原文一起带走。只清一个的表现是：红色已经不在了，
      // 点开「详情」却还挂着上一轮的报错。
      state.dismissConnectFailure();
      expect(state.connectFailure, isNull);
      expect(state.connectFailureDetail, isNull);
    });

    test('连上之后失败结论作废', () async {
      final state = await _stateWithProfile();
      failLikeCore(state, '启动失败：握手超时');
      expect(state.connectFailed, isTrue);

      state.onStatusChanged(VpnStatus.connected);
      expect(state.connectFailure, isNull);
      expect(state.connectFailed, isFalse);
    });

    test('用户主动断开等于表态不要连了，红色随之撤掉', () async {
      final state = await _stateWithProfile();
      failLikeCore(state);
      expect(state.connectFailure, isNotNull);

      await state.disconnect();
      expect(state.connectFailure, isNull);
    });

    test('连接过程中报的错才算连接失败；已连上时的健康告警不算', () async {
      final state = await _stateWithProfile();

      state.onStatusChanged(VpnStatus.connected);
      state.onError('隧道不通，正在尝试自动恢复');
      expect(
        state.connectFailure,
        isNull,
        reason: '健康自愈的告警说的是「当前这条隧道不好」，不是「连接没起来」',
      );
    });

    test('重试期间先维持「连接中」，由内核给出结论', () async {
      final state = await _stateWithProfile();
      failLikeCore(state);
      expect(state.connectFailed, isTrue);

      state.onStatusChanged(VpnStatus.connecting);
      expect(
        state.connectFailed,
        isFalse,
        reason: '新一轮正在飞，此时还举着上一轮的失败结论会让界面自相矛盾',
      );
    });
  });
}
