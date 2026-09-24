import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/system_tray.dart';
import 'package:xvpn/core/update_center.dart';
import 'package:xvpn/core/updater.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/version.dart';

/// 托盘状态的推送。
///
/// 托盘本身在原生侧（Windows：windows/runner/flutter_window.cpp；Linux：
/// linux/runner/my_application.cc），这里能测的只有 Dart 这一半：**推出的载荷
/// 对不对**，以及**该不该推**。两端的原生渲染（灰色图标、tooltip、菜单项）只能
/// 靠真机 `flutter build windows` / `flutter build linux` 之后看——这条边界必须
/// 说清楚，不能靠单元测试假装覆盖了。
///
/// 断言集中在用户可见的事实上：版本号、状态文案（与 [VpnStatusX.label] 同一份
/// 来源）、更新版本号，以及「状态没变就别碰平台通道」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.xvpn.xvpn/platform');
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 只关心托盘那一条方法，避免和窗口控制 / 系统代理的调用混在一起。
  List<MethodCall> trayCalls() =>
      calls.where((MethodCall call) => call.method == 'setTrayState').toList();

  Map<Object?, Object?> argsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// 一个「已经是最新版本」的中心：载荷里不会出现 updateVersion。
  UpdateCenter centerWithoutUpdate() => UpdateCenter(
    check: () async => const UpdateNotAvailable(
      currentVersion: '1.0.1',
      latestVersion: '1.0.1',
    ),
  );

  testWidgets('载荷带真实版本号与状态文案，connected 只对「已连接」为真', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final state = AppState();
    addTearDown(state.dispose);
    final center = centerWithoutUpdate();
    addTearDown(center.dispose);
    final tray = SystemTray(state: state, updateCenter: center);
    addTearDown(tray.dispose);

    for (final status in VpnStatus.values) {
      state.onStatusChanged(status);
      await tray.sync();

      final args = argsOf(trayCalls().last);
      expect(args['version'], appVersion, reason: '托盘上的版本号必须来自 version.dart');
      expect(
        args['status'],
        status.label,
        reason: '${status.name} 的托盘文案必须与 VpnStatusX.label 一致，不能另造一套说法',
      );
      expect(
        args['connected'],
        status == VpnStatus.connected,
        reason: '只有「已连接」才是彩色图标，其余状态都要灰掉',
      );
    }

    // connected 会点亮每秒刷新的计时器；在本体里关掉，别留给 flutter_test 的
    // 「还有未取消的 Timer」检查。dispose 是幂等的，addTearDown 再调一次无害。
    state.dispose();

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('新版本未忽略时载荷带 updateVersion，忽略后撤销', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final state = AppState();
    addTearDown(state.dispose);
    final center = UpdateCenter(
      check: () async => UpdateAvailable(_info(version: '1.2.0')),
    );
    addTearDown(center.dispose);
    // 模拟启动时那次静默检查已经有了结果。
    await center.checkOnStartup();

    final tray = SystemTray(state: state, updateCenter: center);
    addTearDown(tray.dispose);
    tray.attach();
    await tester.pumpAndSettle();

    expect(
      argsOf(trayCalls().last)['updateVersion'],
      '1.2.0',
      reason: '有未忽略的新版本时，托盘必须能说出来',
    );

    center.dismiss();
    await tester.pumpAndSettle();

    expect(trayCalls(), hasLength(2), reason: '出现与撤销各推一次');
    expect(
      argsOf(trayCalls().last).containsKey('updateVersion'),
      isFalse,
      reason: '用户已忽略的提示不该继续出现在托盘上',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('状态没变时不重复推送：未连接时流量刷新不进载荷', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final state = AppState();
    addTearDown(state.dispose);
    final center = centerWithoutUpdate();
    addTearDown(center.dispose);
    final tray = SystemTray(state: state, updateCenter: center);
    addTearDown(tray.dispose);

    tray.attach();
    await tester.pumpAndSettle();
    expect(trayCalls(), hasLength(1), reason: '挂上托盘时同步一次当前状态');

    // 未连接时速率不进载荷：界面每秒流量刷新不应刷平台通道。
    for (var i = 1; i <= 6; i++) {
      state.onTraffic(
        downBps: i.toDouble(),
        upBps: i.toDouble(),
        totalBytes: i,
      );
    }
    await tester.pumpAndSettle();
    expect(trayCalls(), hasLength(1), reason: '未连接时流量变化不该再碰平台通道');

    // 真的变了才推第二次。
    state.onStatusChanged(VpnStatus.connecting);
    await tester.pumpAndSettle();
    expect(trayCalls(), hasLength(2));
    expect(argsOf(trayCalls().last)['status'], VpnStatus.connecting.label);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('已连接时载荷带格式化速率，刻度变化会再推一次', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final state = AppState();
    addTearDown(state.dispose);
    final center = centerWithoutUpdate();
    addTearDown(center.dispose);
    final tray = SystemTray(state: state, updateCenter: center);
    addTearDown(tray.dispose);

    tray.attach();
    await tester.pumpAndSettle();

    state.onStatusChanged(VpnStatus.connected);
    state.onTraffic(
      downBps: 1.2 * 1024 * 1024,
      upBps: 300 * 1024,
      totalBytes: 4096,
    );
    await tray.sync();

    final connectedArgs = argsOf(trayCalls().last);
    expect(connectedArgs['connected'], isTrue);
    expect(connectedArgs['downRate'], '1.20 MB/s');
    expect(connectedArgs['upRate'], '300 KB/s');

    final before = trayCalls().length;
    state.onTraffic(
      downBps: 2.4 * 1024 * 1024,
      upBps: 300 * 1024,
      totalBytes: 8192,
    );
    await tray.sync();
    expect(trayCalls().length, before + 1, reason: '显示刻度变了就必须再推');
    expect(argsOf(trayCalls().last)['downRate'], '2.40 MB/s');

    state.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Linux 同样推送：载荷与 Windows 完全一致', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final state = AppState();
    addTearDown(state.dispose);
    final center = centerWithoutUpdate();
    addTearDown(center.dispose);
    final tray = SystemTray(state: state, updateCenter: center);
    addTearDown(tray.dispose);

    tray.attach();
    await tester.pumpAndSettle();
    expect(trayCalls(), hasLength(1), reason: 'Linux runner 也有托盘，挂上时应推一次');

    state.onStatusChanged(VpnStatus.connecting);
    await tester.pumpAndSettle();

    final args = argsOf(trayCalls().last);
    expect(
      args,
      tray.payload(),
      reason: '两端必须是同一份载荷：托盘文案只有 VpnStatusX.label 一个来源',
    );
    expect(args['version'], appVersion);
    expect(args['status'], VpnStatus.connecting.label);
    expect(args['connected'], isFalse);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('原生侧不存在时静默：推送失败不影响连接主流程', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final state = AppState();
    addTearDown(state.dispose);
    final center = centerWithoutUpdate();
    addTearDown(center.dispose);
    // 没有任何处理器的通道，模拟「原生忘记注册 / 通道不可用」：invokeMethod 会抛
    // MissingPluginException，必须被吞掉，否则托盘会把主流程带崩。
    final tray = SystemTray(
      state: state,
      updateCenter: center,
      channel: const MethodChannel('com.xvpn.xvpn/no-such-native-side'),
    );
    addTearDown(tray.dispose);

    tray.attach();
    state.onStatusChanged(VpnStatus.connecting);
    // 走到这里不抛异常，即说明异常被接住了。
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('外壳重建多次只推一次托盘状态', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    final theme = ThemeController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: XvShell(state: state, theme: theme),
      ),
    );
    await tester.pumpAndSettle();
    expect(trayCalls(), hasLength(1), reason: '外壳挂载时把当前状态推一次');

    for (var i = 1; i <= 4; i++) {
      state.onTraffic(downBps: i.toDouble(), upBps: 0, totalBytes: i);
      await tester.pump();
    }
    expect(trayCalls(), hasLength(1), reason: '无关重建不该重复推送托盘状态');

    // 参照 platform_parity_test 的收尾：先卸下界面再释放状态。
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    theme.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
}

UpdateInfo _info({String version = '1.2.0'}) => UpdateInfo(
  tag: 'v$version',
  version: version,
  platform: UpdatePlatform.windows,
  assetName: 'XVPN-$version-windows-x64.msix',
  assetUri: Uri.parse('https://example.net/win.msix'),
  checksumsName: 'SHA256SUMS.txt',
  checksumsUri: Uri.parse('https://example.net/SHA256SUMS.txt'),
  assetSize: 2048,
  pageUri: Uri.parse('https://example.net/releases/tag/v$version'),
  notes: '示例发布说明。',
);
