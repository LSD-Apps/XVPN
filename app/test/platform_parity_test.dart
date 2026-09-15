import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/dns_monitor.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/startup_self_check.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/screens/rules_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/auto_route_card.dart';
import 'package:xvpn/widgets/common.dart';
import 'package:xvpn/widgets/update_card.dart';

/// PC 与移动端的一致性。
///
/// 这个产品两端共用同一份状态层与大部分组件，但布局是分开写的（桌面侧栏 +
/// 独立页 / 移动底部标签 + 并入设置页）。分叉是必要的，问题在于**分叉很容易
/// 悄悄变成功能缺失**——此前的实际例子：
///
///   * 分段选择器的标签两端叫法不同（桌面「走代理」/ 移动「代理」）；
///   * 「流量接管方式」整张卡片只有桌面端有；
///   * DNS 探测与启动自检结论两端都能看，但**都没有**重测入口
///     （`AppState.refreshDns` / `runSelfCheck` 写了却没有任何界面调用）；
///   * 移动端一度完全没有删除配置的入口。
///
/// 这个文件的作用就是把「两端该有的东西」显式写成断言，让下一次分叉在测试里
/// 暴露出来，而不是等用户发现。原则是：**能力可以因平台而异，但呈现结构必须
/// 一致**——该讲清楚的信息两端都要讲，该有的操作两端都要有。
void main() {
  const conf = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ==
Address = 10.7.0.2/32
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
''';

  /// 一份需要账号密码的 OpenVPN 配置。
  ///
  /// 两端一致性用例需要它：`auth-user-pass` 让 `requiresCredentials` 为真，
  /// 于是配置列表上必须出现补填入口。
  const needCreds = '''
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

  /// 是否走桌面布局。Linux 与 Windows 共用同一套桌面界面，因此凡是按平台
  /// 分尺寸/分文案的地方都必须把它算进桌面侧。
  bool isDesktopPlatform(TargetPlatform p) =>
      p == TargetPlatform.windows || p == TargetPlatform.linux;

  /// 造一个带真实内核的状态：自动纠正表与 DNS/自检入口都需要它。
  AppState stateWithRealCore() => AppState(
    coreFactory: (VpnCoreListener l) => SingBoxRunner(l, probesEnabled: false),
  );

  /// 渲染并回到指定平台。
  ///
  /// 平台用 `debugDefaultTargetPlatformOverride` 指定，**必须在测试体内复位**
  /// （由 [resetPlatform] 完成）：flutter_test 在测试体结束、tearDown 之前就会
  /// 校验 foundation 的调试变量有没有被改动过，放进 tearDown 会得到
  /// 「The value of a foundation debug variable was changed by the test」，
  /// 而且这条错误会把真正的断言结果盖掉。
  Future<void> pumpOn(
    WidgetTester tester,
    AppState state,
    TargetPlatform platform, {
    required Size size,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
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

  /// 让界面稳定下来，但**允许存在不会停的动画**。
  ///
  /// 预热态的流转弧是无限循环的，`pumpAndSettle` 会一直等它静止从而超时。
  /// 这不是缺陷（那圈弧本来就该一直转到连上为止），所以这类用例用固定次数的
  /// `pump` 代替等待静止。
  Future<void> settleWithAnimation(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 复位平台覆盖。每个用例结束前必须调用。
  void resetPlatform() => debugDefaultTargetPlatformOverride = null;

  /// 切到某个页面/标签，并把目标文案滚进视口（如果它在视口外）。
  ///
  /// 两端导航不同（桌面点侧栏、移动点底部标签），因此按文案点即可。
  ///
  /// 注意**不能假定存在 Scrollable**：桌面设置页内容够高时就是一个不产生
  /// Scrollable 的普通布局（SingleChildScrollView 在内容不超出时不会建
  /// Scrollable），此时 `find.byType(Scrollable).first` 会直接抛
  /// 「Bad state: No element」。因此这里先看目标在不在，在就直接返回；
  /// 只有确实需要滚动时才去找可滚动节点，找不到就当作「已经在视口里」。
  Future<void> openAndReveal(
    WidgetTester tester,
    String tab,
    String target,
  ) async {
    await tester.tap(find.text(tab).first);
    await tester.pumpAndSettle();

    if (find.text(target).evaluate().isNotEmpty) return;

    // 页面级滚动容器（移动端设置页）或卡片内滚动区域，取第一个能用的。
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) return;

    var guard = 0;
    while (find.text(target).evaluate().isEmpty && guard < 30) {
      await tester.drag(scrollable.first, const Offset(0, -200));
      await tester.pumpAndSettle();
      guard++;
    }
  }

  Future<void> stop(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  group('两端都有的能力', () {
    testWidgets('两端设置页都含 外观 / 启动 / 流量接管方式 / 记录 四块', (
      WidgetTester tester,
    ) async {
      // 「配置」块在桌面端是独立页面、在移动端并入设置页，因此不在这条断言里，
      // 由下面的「配置入口」用例按各自的位置分别检查。
      //
      // 「分流」块已搬去独立的「分流规则」页——设置页不再做分流配置。
      // 记录分流明细留在设置里（它是记录偏好，不是路由规则），因此设置页现在
      // 应含「记录」这一块。
      for (final target in <String>['外观', '启动', '流量接管方式', '记录']) {
        // 桌面侧的两个平台（Windows / Linux）信息结构必须一致：
        // 只测 Windows 会让 Linux 的整块卡片缺失悄悄溜过去。
        for (final desktopPlatform in <TargetPlatform>[
          TargetPlatform.windows,
          TargetPlatform.linux,
        ]) {
          final desktop = stateWithRealCore();
          await pumpOn(
            tester,
            desktop,
            desktopPlatform,
            size: const Size(1400, 1200),
          );
          await openAndReveal(tester, '设置', target);
          expect(
            find.text(target),
            findsWidgets,
            reason: '$desktopPlatform 桌面设置页应包含「$target」',
          );
          await stop(tester, desktop);
        }

        final mobile = stateWithRealCore();
        await pumpOn(
          tester,
          mobile,
          TargetPlatform.android,
          size: const Size(390, 900),
        );
        await openAndReveal(tester, '设置', target);
        expect(
          find.text(target),
          findsWidgets,
          reason: '移动设置页应包含「$target」——两端信息结构必须一致',
        );
        await stop(tester, mobile);
        resetPlatform();
      }
    });

    testWidgets('两端都有「分流规则」入口，且都能进到规则页', (WidgetTester tester) async {
      // 新增的模块：桌面在侧栏（在「设置」之上），移动是第四个底部标签。
      // 入口在两端都必须在，而且点进去确实能到规则页——只断言入口文字存在
      // 会漏掉「入口点了没反应」这类断链。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final desktop = isDesktopPlatform(platform);
        final state = stateWithRealCore();
        await pumpOn(
          tester,
          state,
          platform,
          size: desktop ? const Size(1400, 1400) : const Size(390, 900),
        );
        await openAndReveal(tester, desktop ? '分流规则' : '规则', '分流模式');
        expect(
          find.byType(RulesScreen),
          findsOneWidget,
          reason: '$platform 应能从导航进到「分流规则」页',
        );
        for (final text in <String>['规则集', '直连白名单', '隧道流量去向', '域名分流规则']) {
          expect(
            find.text(text),
            findsWidgets,
            reason: '$platform 的分流规则页应包含「$text」',
          );
        }
        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('配置模块：桌面是独立页、移动并入设置页，但内容同源', (WidgetTester tester) async {
      // 位置不同是设计决定（移动端标签栏只有三项），但两块内容必须都在：
      // 配置列表与两条导入路径。
      const fileTitle = '选择配置文件';
      const manualTitle = '手动填写';

      for (final desktopPlatform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final desktop = stateWithRealCore();
        await pumpOn(
          tester,
          desktop,
          desktopPlatform,
          size: const Size(1400, 1200),
        );
        await openAndReveal(tester, '配置文件', fileTitle);
        expect(find.text(fileTitle), findsOneWidget);
        expect(find.text(manualTitle), findsOneWidget);
        expect(find.text('自备订阅'), findsOneWidget);
        await stop(tester, desktop);
      }

      final mobile = stateWithRealCore();
      await pumpOn(
        tester,
        mobile,
        TargetPlatform.android,
        size: const Size(390, 900),
      );
      await openAndReveal(tester, '设置', fileTitle);
      expect(find.text(fileTitle), findsOneWidget, reason: '移动端也要能选文件导入');
      expect(find.text(manualTitle), findsOneWidget, reason: '移动端也要能手填导入');
      expect(find.text('自备订阅'), findsOneWidget, reason: '移动端也要能导入自备订阅');
      await stop(tester, mobile);
      resetPlatform();
    });

    testWidgets('流量接管方式：两端都有这张卡，内容按平台给', (WidgetTester tester) async {
      // 能力不同（桌面系统代理 / 安卓 TUN），但「用什么接管、有什么限制」
      // 这件事两端都要讲清楚。
      for (final desktopPlatform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final desktop = stateWithRealCore();
        await pumpOn(
          tester,
          desktop,
          desktopPlatform,
          size: const Size(1400, 1200),
        );
        await openAndReveal(tester, '设置', '流量接管方式');
        expect(find.text('系统代理'), findsOneWidget);
        expect(
          find.text('TUN 虚拟网卡'),
          findsNothing,
          reason: '$desktopPlatform 桌面不提供无法兑现的选项',
        );
        await stop(tester, desktop);
      }

      final mobile = stateWithRealCore();
      await pumpOn(
        tester,
        mobile,
        TargetPlatform.android,
        size: const Size(390, 900),
      );
      await openAndReveal(tester, '设置', '流量接管方式');
      expect(find.text('TUN 虚拟网卡'), findsOneWidget);
      expect(find.text('系统代理'), findsNothing);
      await stop(tester, mobile);
      resetPlatform();
    });

    testWidgets('两端设置页都有「开源许可」入口', (WidgetTester tester) async {
      // 许可与第三方声明随包分发是一回事，用户能否在应用内读到是另一回事。
      // 这个入口此前两端都没有，导致「文本已分发但读不到」。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = stateWithRealCore();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        await openAndReveal(tester, '设置', '开源许可');
        expect(
          find.text('开源许可'),
          findsOneWidget,
          reason: '$platform 设置页应有「开源许可」入口',
        );
        expect(
          find.widgetWithText(XvButton, '查看'),
          findsOneWidget,
          reason: '$platform 应能从这里打开许可页',
        );
        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('两端设置页都有「法律与使用声明」入口', (WidgetTester tester) async {
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = stateWithRealCore();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        await openAndReveal(tester, '设置', '法律与使用声明');
        expect(
          find.text('法律与使用声明'),
          findsOneWidget,
          reason: '$platform 设置页应有「法律与使用声明」入口',
        );
        expect(
          find.widgetWithText(XvButton, '阅读'),
          findsOneWidget,
          reason: '$platform 应能从这里打开使用声明',
        );
        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('两端设置页都有「版本更新」入口', (WidgetTester tester) async {
      // 自动更新在三个平台上都存在（安装方式不同：桌面自替换、安卓交给系统
      // 安装器），入口不能在某一端缺席——本项目把「某个操作只有一端有」当作缺陷。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = stateWithRealCore();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        await openAndReveal(tester, '设置', '版本更新');
        expect(
          find.byType(UpdateCard),
          findsOneWidget,
          reason: '$platform 设置页应有「版本更新」卡片',
        );
        expect(
          find.text('版本更新'),
          findsOneWidget,
          reason: '$platform 的更新入口应能被用户看到',
        );
        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('分流记录页：筛选叫法两端一致', (WidgetTester tester) async {
      // 曾经移动端写「代理」、桌面写「走代理」，同一个筛选器两种叫法。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = AppState();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 900)
              : const Size(390, 900),
        );
        await tester.tap(
          find.text(isDesktopPlatform(platform) ? '分流记录' : '分流').first,
        );
        await tester.pumpAndSettle();

        for (final label in <String>['全部', '走代理', '直连']) {
          expect(
            find.text(label),
            findsWidgets,
            reason: '$platform 的分流筛选应有「$label」，两端叫法必须一致',
          );
        }
        await stop(tester, state);
        resetPlatform();
      }
    });
  });

  group('两端都有的操作', () {
    testWidgets('DNS 与自检结论两端都能手动重测', (WidgetTester tester) async {
      // 这是本轮补上的缺口：结论两端都能看，但重测入口此前**两端都没有**——
      // AppState.refreshDns / runSelfCheck 写了却没有任何界面调用它们。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = stateWithRealCore();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        // 必须先有配置：连接页在没有配置时走的是「导入引导」空状态，
        // 检测区块根本不会渲染。
        state.importConf(text: conf, fileName: 'wg.conf');
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));

        // 连接后才显示检测区块。
        state.onStatusChanged(VpnStatus.connected);
        state.onDnsReport(_sampleDnsReport());
        state.onSelfCheck(_sampleSelfCheck());
        await tester.pumpAndSettle();

        expect(
          find.text('重测'),
          findsWidgets,
          reason: '$platform 应能手动重测 DNS 与自检',
        );
        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('移动端也能删除配置', (WidgetTester tester) async {
      // 曾经移动端只能增不能删。
      final state = AppState();
      await pumpOn(
        tester,
        state,
        TargetPlatform.android,
        size: const Size(390, 900),
      );
      state.importConf(text: conf, fileName: 'wg.conf');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      await openAndReveal(tester, '设置', '删除');
      expect(find.text('删除'), findsOneWidget, reason: '移动端必须有删除入口');
      await stop(tester, state);
      resetPlatform();
    });

    testWidgets('两端都能补填账号密码', (WidgetTester tester) async {
      // 需要账号密码的配置（OpenVPN 的 auth-user-pass）在两端都必须有补填入口。
      // 移动端一直有；桌面配置卡片此前**完全没有**，用户在导入对话框里选了
      // 「稍后填写」之后就卡住了——而那个对话框明确承诺了「之后在配置页补填」。
      // 结果是 OpenVPN 在桌面端不可用，唯一绕法是重新导入一遍。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final desktop = isDesktopPlatform(platform);
        final state = AppState();
        state.updateSettings(const AppSettings(autoConnectOnImport: false));
        state.importConf(text: needCreds, fileName: 'need.ovpn');
        expect(
          state.profileNeedsCredentials(state.profiles.single.id),
          isTrue,
          reason: '这份配置就是「需要账号密码但还没填」',
        );

        await pumpOn(
          tester,
          state,
          platform,
          size: desktop ? const Size(1400, 1200) : const Size(390, 900),
        );
        await openAndReveal(
          tester,
          desktop ? '配置文件' : '设置',
          '缺账号密码',
        );

        expect(
          find.text('缺账号密码'),
          findsWidgets,
          reason: '$platform 应把「还缺账号密码」标出来',
        );
        expect(
          find.text('填写'),
          findsWidgets,
          reason: '$platform 必须有补填账号密码的入口，否则用户只能重新导入',
        );

        // 补填之后状态切换成「改密码」，缺失提示消失。
        state.setProfileCredentials(
          state.profiles.single.id,
          username: 'alice',
          password: 'pw-123',
        );
        await tester.pumpAndSettle();

        expect(
          find.text('改密码'),
          findsWidgets,
          reason: '$platform 补填成功后应给出「改密码」入口',
        );
        expect(
          find.text('缺账号密码'),
          findsNothing,
          reason: '$platform 已经填好了就不该再标缺失',
        );

        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('配置的激活动作两端叫法一致', (WidgetTester tester) async {
      // 本项目把「同一个动作两种叫法」当作缺陷：移动端曾写「切换」、桌面端
      // 写「设为当前」。统一成更清楚的「设为当前」——它直接说出了结果状态。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final desktop = isDesktopPlatform(platform);
        final state = AppState();
        state.updateSettings(const AppSettings(autoConnectOnImport: false));
        // 导入两份：后导入的那份成为当前配置，于是第一份显示激活入口。
        state.importConf(text: conf, fileName: 'wg.conf');
        state.importConf(text: needCreds, fileName: 'need.ovpn');

        await pumpOn(
          tester,
          state,
          platform,
          size: desktop ? const Size(1400, 1200) : const Size(390, 900),
        );
        await openAndReveal(
          tester,
          desktop ? '配置文件' : '设置',
          '设为当前',
        );

        expect(
          find.text('设为当前'),
          findsWidgets,
          reason: '$platform 的非当前配置应有「设为当前」入口',
        );
        expect(
          find.text('切换'),
          findsNothing,
          reason: '$platform 不该再用「切换」这个第二种叫法',
        );

        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('两端都能手工指定域名走向', (WidgetTester tester) async {
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = stateWithRealCore();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        await openAndReveal(
          tester,
          isDesktopPlatform(platform) ? '分流规则' : '规则',
          '手工指定',
        );
        expect(find.text('手工指定'), findsOneWidget, reason: '$platform 应有手工指定入口');
        expect(find.byType(AutoRouteCard), findsOneWidget);
        await stop(tester, state);
        resetPlatform();
      }
    });
  });

  group('连接过程的状态两端都要讲清楚', () {
    /// 造一个「正在建立隧道」的状态。
    ///
    /// 用真实内核才能在导入后从内核拿到握手状态——预热与握手都是**内核侧**的
    /// 事实，用演示内核测等于自己骗自己。
    AppState warmingState() => AppState(
      coreFactory: (VpnCoreListener l) =>
          SingBoxRunner(l, probesEnabled: false),
    );

    testWidgets('预热态两端都由圆环说明「正在建立隧道」，不能显示成已连接', (WidgetTester tester) async {
      // 这一条锁定的是本轮改动要消掉的那种误导：内核就绪但隧道还不能载流量，
      // 界面若显示「已连接」，用户就会认为软件坏了。两端必须都改口。
      //
      // 断言的是**圆环里的文案**：页头的状态标签已按设计移除（它只是把圆环
      // 已经说清楚的事重复一遍），因此状态表达的唯一出口就是圆环本身——
      // 两端共用同一个组件，这里的一致性是由结构保证的，不是靠巧合。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = warmingState();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        state.importConf(text: conf, fileName: 'wg.conf');
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));

        state.onStatusChanged(VpnStatus.warmingUp);
        await settleWithAnimation(tester);

        expect(
          find.text('正在建立隧道…'),
          // 至少一处：圆环里一定有；桌面端按钮在预热时也用它当标签
          // （按钮此时不可点，标签必须说明为什么），因此不能要求「恰好一处」。
          findsWidgets,
          reason: '$platform 的圆环应说明隧道仍在建立，而不是笼统的「连接中」或「已连接」',
        );
        expect(
          find.text('已连接'),
          findsNothing,
          reason: '$platform 在隧道还不能载流量时不能显示「已连接」',
        );
        await stop(tester, state);
        resetPlatform();
      }
    });

    testWidgets('握手状态：桌面显示并给出结论', (WidgetTester tester) async {
      // 握手是「连不上」时唯一能区分病因的证据（未被服务端受理 vs 数据面问题），
      // 桌面端必须看得到。
      const initiating =
          '+0800 2026-09-11 22:18:03 DEBUG endpoint/wireguard[vpn]: '
          'peer(Qk9y…7tZa) - sending handshake initiation';
      const retrying =
          '+0800 2026-09-11 22:18:08 DEBUG endpoint/wireguard[vpn]: '
          'peer(Qk9y…7tZa) - handshake did not complete after 5 seconds, retrying (try 3)';

      final state = warmingState();
      await pumpOn(
        tester,
        state,
        TargetPlatform.windows,
        size: const Size(1400, 1400),
      );
      state.importConf(text: conf, fileName: 'wg.conf');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      state.onStatusChanged(VpnStatus.warmingUp);
      await settleWithAnimation(tester);

      for (final text in <String>['隧道握手', '正在读取内核握手状态…']) {
        expect(find.text(text), findsOneWidget, reason: '桌面端应有「$text」');
      }

      (state.core as SingBoxRunner).handleCoreLog(initiating);
      (state.core as SingBoxRunner).handleCoreLog(retrying);
      await settleWithAnimation(tester);

      expect(
        find.textContaining('无应答'),
        findsWidgets,
        reason: '桌面端应显示握手无应答——这是「未被服务端受理」的唯一线索',
      );
      await stop(tester, state);
      resetPlatform();
    });

    testWidgets('握手状态：平台不上报时整行不显示，而不是永远「正在读取」', (WidgetTester tester) async {
      // 这一条锁定的是「能力标志为 false 时不要留下占位」这条分支本身。
      // 之所以用**覆盖值**而不是真平台：能力标志定义在内核侧，而 widget 测试
      // 注入的替身内核无法在两个平台实现之间切换；覆盖值就是为这条分支准备的
      // 注入点（真按平台算，两端现在都是 true，因为这个分支在真机上几乎不可能
      // 被走到，只能靠注入来锁定）。
      //
      final state = warmingState();
      state.debugSupportsHandshakeOverride = false;
      await pumpOn(
        tester,
        state,
        TargetPlatform.android,
        size: const Size(390, 900),
      );
      state.importConf(text: conf, fileName: 'wg.conf');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      state.onStatusChanged(VpnStatus.warmingUp);
      await settleWithAnimation(tester);

      expect(find.text('隧道握手'), findsNothing, reason: '平台不上报握手状态时，这一行必须整行消失');
      expect(
        find.textContaining('正在读取内核握手状态'),
        findsNothing,
        reason: '留下一个永远「正在读取」的占位，比不显示更糟',
      );
      await stop(tester, state);
      resetPlatform();
    });
  });

  group('MTU 校验两端都有，能力按平台写明', () {
    testWidgets('桌面端能校验并给结论，移动端说明由内核处理', (WidgetTester tester) async {
      // 这一条锁定的是「能力可以不同，但呈现结构必须一致」：MTU 这一项两端都
      // 显示，只是内容按平台给。若哪天移动端整行消失，这条会失败。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = AppState();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 1400)
              : const Size(390, 900),
        );
        state.importConf(text: conf, fileName: 'wg.conf');
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));

        await openAndReveal(
          tester,
          isDesktopPlatform(platform) ? '连接' : '连接',
          'MTU 校验',
        );

        if (isDesktopPlatform(platform)) {
          expect(
            find.text('MTU 校验'),
            findsWidgets,
            reason: '$platform 桌面端应能校验配置里声明的 MTU',
          );
        } else {
          // 安卓走 TUN、没有本地混合入站端口，因此没有可校验的入口——
          // 但这一行必须在，并把原因说出来。
          expect(
            find.text('MTU'),
            findsWidgets,
            reason: '移动端也要有这一行，说明 MTU 由谁处理',
          );
          expect(find.textContaining('内核自行处理'), findsWidgets);
        }
        await stop(tester, state);
        resetPlatform();
      }
    });
  });

  group('两端都不该出现的东西', () {
    testWidgets('两端都不出现内核术语', (WidgetTester tester) async {
      // 内核的 rule 字段是「条件 => 动作」的描述文本，任何一端把它原样显示
      // 都是把内部实现泄漏给了用户。
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.android,
      ]) {
        final state = AppState();
        await pumpOn(
          tester,
          state,
          platform,
          size: isDesktopPlatform(platform)
              ? const Size(1400, 900)
              : const Size(390, 900),
        );
        state.onSplitRecord(
          SplitRecord(
            time: DateTime(2026, 2, 14),
            target: 'www.baidu.com',
            kind: RouteKind.direct,
            rule: 'geosite-cn + geoip-cn',
            outbound: 'direct',
          ),
        );
        await tester.pump();
        expect(
          find.textContaining('rule_set='),
          findsNothing,
          reason: '$platform 不应出现内核术语',
        );
        await stop(tester, state);
        resetPlatform();
      }
    });
  });
}

DnsReport _sampleDnsReport() => DnsReport(
  checkedAt: DateTime(2026, 2, 14),
  resolvers: const <ResolverHealth>[],
  direct: LatencyWindow(capacity: 4)..add(12),
  tunnel: LatencyWindow(capacity: 4)..add(96),
  verdict: DnsVerdict.consistent,
);

StartupSelfCheckReport _sampleSelfCheck() => StartupSelfCheckReport(
  checkedAt: DateTime(2026, 2, 14),
  probes: const <ProbeResult>[],
  conclusion: '两条路径都正常',
  advice: '可以正常使用',
);
