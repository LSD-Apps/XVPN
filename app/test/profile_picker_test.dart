import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/screen_navigation.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/connect_screen.dart';
import 'package:xvpn/screens/profiles_screen.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/common.dart';

/// 「切换配置」弹窗里新增的引导入口。
///
/// 锁四件事：
///   * 从两条布局都能看到「管理 / 添加配置」；
///   * 点击它会关闭弹窗，并发出「去配置区」的跳转意图（意图由外壳消费，
///     见 [ScreenNavigation]）；
///   * 一份配置都没有时入口照常出现——那正是用户最需要它的时候；
///   * 原有的切换行为不受影响。
///
/// 配置值全部是合成值（保留段 / 递增字节的 base64），不是真实服务器。
const _confA = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.2/32
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

const _confB = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 203.0.113.11:51820
AllowedIPs = 0.0.0.0/0
''';

/// 只改端口，用来造多份互不相同的配置（多到弹窗必须滚动）。
String _confWithPort(int port) =>
    '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.2/32
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 203.0.113.10:$port
AllowedIPs = 0.0.0.0/0
''';

/// 直接打开弹窗的宿主。
///
/// 空配置时连接页走导入引导、根本不渲染「切换配置」按钮，因此不能从按钮
/// 打开弹窗；这个宿主用于覆盖「空列表」与「移动端尺寸」两种情形。
class _PickerHost extends StatelessWidget {
  const _PickerHost({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (BuildContext inner) => XvButton(
            label: '打开配置弹窗',
            onPressed: () => showProfilePicker(inner, state),
          ),
        ),
      ),
    );
  }
}

Widget _connectHome(AppState state, {required bool compact}) => Scaffold(
  body: ListenableBuilder(
    listenable: state,
    builder: (BuildContext context, Widget? child) =>
        ConnectScreen(state: state, compact: compact),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: buildXvTheme(XvPalette.dark), home: home),
  );
  await tester.pumpAndSettle();
}

AppState _stateWith({bool autoConnect = false}) {
  final state = AppState();
  addTearDown(state.dispose);
  state.updateSettings(
    state.settings.copyWith(autoConnectOnImport: autoConnect),
  );
  return state;
}

void main() {
  setUp(() {
    applyPalette(XvPalette.dark);
    // 全局单例在用例之间共享，必须清掉上一个用例留下的待处理意图。
    ScreenNavigation.instance.consume();
  });

  testWidgets('桌面布局：入口存在，点击后关闭弹窗并发出跳转意图', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = _stateWith();
      state.importConf(text: _confA, fileName: 'a.conf');
      state.importConf(text: _confB, fileName: 'b.conf');
      await _pump(
        tester,
        _connectHome(state, compact: false),
        size: const Size(1400, 900),
      );

      await tester.tap(find.text('切换配置'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget, reason: '「切换配置」应打开弹窗');
      expect(find.text('管理 / 添加配置'), findsOneWidget, reason: '弹窗应有去配置页的引导入口');

      await tester.tap(find.text('管理 / 添加配置'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing, reason: '点击入口后弹窗应关闭');
      expect(
        ScreenNavigation.instance.value,
        AppSection.profiles,
        reason: '点击入口应发出「去配置区」的跳转意图，由外壳翻译成当前布局的页面',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('移动布局：同一个弹窗同样含引导入口', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final state = _stateWith();
      state.importConf(text: _confA, fileName: 'a.conf');
      await _pump(
        tester,
        _PickerHost(state: state),
        size: const Size(390, 844),
      );

      await tester.tap(find.text('打开配置弹窗'));
      await tester.pumpAndSettle();

      expect(
        find.text('管理 / 添加配置'),
        findsOneWidget,
        reason: '弹窗是两端共用的，移动端也必须能看到入口',
      );

      await tester.tap(find.text('管理 / 添加配置'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(ScreenNavigation.instance.value, AppSection.profiles);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('空配置：入口照常出现，点击后关闭并发出意图', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = _stateWith();
      await _pump(
        tester,
        _PickerHost(state: state),
        size: const Size(1400, 900),
      );

      await tester.tap(find.text('打开配置弹窗'));
      await tester.pumpAndSettle();

      expect(find.text('还没有导入任何配置'), findsOneWidget);
      expect(
        find.text('管理 / 添加配置'),
        findsOneWidget,
        reason: '一份配置都没有时，入口恰恰最有用，不能缺席',
      );

      await tester.tap(find.text('管理 / 添加配置'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(ScreenNavigation.instance.value, AppSection.profiles);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('原有切换行为不变：点某份配置把它设为当前并关闭弹窗', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = _stateWith();
      state.importConf(text: _confA, fileName: 'a.conf');
      state.importConf(text: _confB, fileName: 'b.conf');
      final inactive = state.profiles.firstWhere(
        (VpnProfile p) => p.id != state.activeProfile!.id,
      );
      await _pump(
        tester,
        _connectHome(state, compact: false),
        size: const Size(1400, 900),
      );

      await tester.tap(find.text('切换配置'));
      await tester.pumpAndSettle();
      expect(find.text('当前'), findsOneWidget, reason: '当前配置要标出来');

      await tester.tap(find.text(inactive.name));
      await tester.pumpAndSettle();

      expect(state.activeProfile!.id, inactive.id, reason: '点击某份配置应把它设为当前');
      expect(find.byType(Dialog), findsNothing, reason: '切换后弹窗应关闭');
      expect(
        ScreenNavigation.instance.value,
        isNull,
        reason: '切换配置不是跳转，不应发出导航意图',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('关闭按钮仍然可用且不发出跳转意图', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = _stateWith();
      state.importConf(text: _confA, fileName: 'a.conf');
      await _pump(
        tester,
        _PickerHost(state: state),
        size: const Size(1400, 900),
      );

      await tester.tap(find.text('打开配置弹窗'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(ScreenNavigation.instance.value, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('配置很多时列表可滚动且不溢出，入口始终可见', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final state = _stateWith();
      for (var i = 0; i < 20; i++) {
        state.importConf(text: _confWithPort(20300 + i), fileName: 'c$i.conf');
      }
      await _pump(
        tester,
        _connectHome(state, compact: false),
        size: const Size(1400, 900),
      );

      await tester.tap(find.text('切换配置'));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: '配置多时列表必须能滚，不能抛 RenderFlex overflow',
      );
      expect(
        find.text('管理 / 添加配置'),
        findsOneWidget,
        reason: '入口固定在列表之外，不随列表滚动消失',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// 外壳确实消费了跳转意图。
  ///
  /// 上面几条只锁到「页面发出了意图」。发出意图与实际跳到那一页之间还隔着
  /// 外壳的翻译（意图 → 本布局的标签索引），缺了这条测试，外壳那一侧断了也
  /// 不会被发现。
  testWidgets('外壳消费意图：桌面落到「配置文件」页，移动端落到设置标签', (WidgetTester tester) async {
    // 「配置」在两端的落点不同：桌面是侧栏独立的「配置文件」页，
    // 移动端则是设置标签（配置列表内嵌其中），因此期望的页面类型也不同。
    final cases = <({TargetPlatform platform, Size size, Type page})>[
      (
        platform: TargetPlatform.windows,
        size: const Size(1400, 900),
        page: ProfilesScreen,
      ),
      (
        platform: TargetPlatform.android,
        size: const Size(390, 900),
        page: SettingsScreen,
      ),
    ];

    for (final testCase in cases) {
      debugDefaultTargetPlatformOverride = testCase.platform;
      try {
        // 每一轮用不同的 key：同类型 widget 再 pump 一次会**复用** State，
        // 上一轮 setState 改过的 _mobileTab 会被带进这一轮的「初始状态」，
        // 于是初始断言看到的其实是上一轮的结果。
        final state = _stateWith();
        final theme = ThemeController();
        addTearDown(theme.dispose);
        await _pump(
          tester,
          XvShell(key: ValueKey(testCase.platform), state: state, theme: theme),
          size: testCase.size,
        );

        expect(
          find.byType(testCase.page),
          findsNothing,
          reason: '${testCase.platform} 初始应停在连接页',
        );

        ScreenNavigation.instance.request(AppSection.profiles);
        await tester.pumpAndSettle();

        expect(
          find.byType(testCase.page),
          findsOneWidget,
          reason: '${testCase.platform} 收到意图后应落到配置区',
        );
        expect(
          ScreenNavigation.instance.value,
          isNull,
          reason: '意图必须被消费，否则下一次重建会重复跳转',
        );
      } finally {
        // 让本轮的外壳先 dispose（它挂着监听），再进入下一轮。
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });
}
