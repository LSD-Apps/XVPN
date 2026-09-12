import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/update_center.dart';
import 'package:xvpn/core/updater.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/title_bar.dart';
import 'package:xvpn/widgets/update_card.dart';

/// 启动更新检查的行为测试。
///
/// 全部通过注入的检查函数驱动，**不联网**：真实检查要去 api.github.com，
/// 测试不可重复，而这里要锁定的恰恰是几条容易写错的纪律——
/// 失败必须静默、每次进程只查一次、只有「有新版本」才留下痕迹，
/// 以及共享结果不会让设置页卡片自己发起请求。

/// 任何一次真实请求都说明测试走错了分支。
class _NoopHttpClient implements UpdateHttpClient {
  const _NoopHttpClient();

  @override
  Future<UpdateHttpResponse> send(Uri url) =>
      Future<UpdateHttpResponse>.error(UnsupportedError('测试不应发起网络请求'));
}

/// 一旦被查询就抛异常的引擎。卡片从共享结果呈现时不应碰到它。
class _NeverNetworkUpdater extends Updater {
  _NeverNetworkUpdater()
    : super(
        platform: TargetPlatform.windows,
        currentVersion: '1.0.1',
        http: const _NoopHttpClient(),
      );

  int checkCalls = 0;

  @override
  Future<UpdateCheckResult> checkForUpdate() async {
    checkCalls++;
    throw StateError('卡片从启动检查结果呈现时不应发起检查');
  }

  @override
  void dispose() {}
}

UpdateInfo _info({String version = '1.2.0'}) => UpdateInfo(
  tag: 'v$version',
  version: version,
  platform: UpdatePlatform.windows,
  assetName: 'XVPN-$version-windows-x64.zip',
  assetUri: Uri.parse('https://example.net/win.zip'),
  checksumsName: 'SHA256SUMS.txt',
  checksumsUri: Uri.parse('https://example.net/SHA256SUMS.txt'),
  assetSize: 2048,
  pageUri: Uri.parse('https://github.com/LSD-Apps/XVPN/releases/tag/v$version'),
  notes: '修复了若干问题。',
);

/// 用指定结果造一个中心，并预置好检查函数。
UpdateCenter _centerWith(UpdateCheckResult result) {
  return UpdateCenter(check: () async => result);
}

void main() {
  group('UpdateCenter 启动检查', () {
    test('检查失败时静默：不抛异常，也不留下任何提示', () async {
      final center = UpdateCenter(
        check: () async => const UpdateCheckFailure('无法连接更新服务器，请检查网络后重试。'),
      );
      addTearDown(center.dispose);

      await center.checkOnStartup();

      expect(center.notice.value, isNull, reason: '启动检查失败必须与「没有更新」一致');
    });

    test('检查函数直接抛异常时同样静默，不冒泡给调用方', () async {
      final center = UpdateCenter(
        check: () async => throw StateError('意外的解析崩溃'),
      );
      addTearDown(center.dispose);

      // 若异常逃逸，这个 await 会让用例失败——能走到断言本身就说明被吞掉了。
      await center.checkOnStartup();

      expect(center.notice.value, isNull);
    });

    test('「已经是最新版本」不留下提示', () async {
      final center = _centerWith(
        const UpdateNotAvailable(currentVersion: '1.0.1', latestVersion: '1.0.1'),
      );
      addTearDown(center.dispose);

      await center.checkOnStartup();

      expect(center.notice.value, isNull);
    });

    test('只有真的有新版本时才记录提示，并带上完整更新信息', () async {
      final info = _info(version: '1.2.0');
      final center = _centerWith(UpdateAvailable(info));
      addTearDown(center.dispose);

      await center.checkOnStartup();

      final notice = center.notice.value;
      expect(notice, isNotNull);
      expect(notice!.version, '1.2.0');
      expect(notice.info, same(info));
      expect(notice.dismissed, isFalse);
    });

    test('每次进程只检查一次：重复调用不会发第二次请求', () async {
      var calls = 0;
      final center = UpdateCenter(
        check: () async {
          calls++;
          return const UpdateNotAvailable(
            currentVersion: '1.0.1',
            latestVersion: '1.0.1',
          );
        },
      );
      addTearDown(center.dispose);

      await Future.wait(<Future<void>>[
        center.checkOnStartup(),
        center.checkOnStartup(),
      ]);
      await center.checkOnStartup();

      expect(calls, 1, reason: '启动检查必须幂等，不能每次进设置页就查一次');
    });

    test('超时按失败处理：不抛异常，也不留下提示', () async {
      final never = Completer<UpdateCheckResult>();
      final center = UpdateCenter(
        check: () => never.future,
        timeout: const Duration(milliseconds: 20),
      );
      addTearDown(center.dispose);

      await center.checkOnStartup();

      expect(center.notice.value, isNull);
    });

    test('忽略后保持忽略：会话内不再出现', () async {
      final center = _centerWith(UpdateAvailable(_info()));
      addTearDown(center.dispose);

      await center.checkOnStartup();
      expect(center.notice.value!.dismissed, isFalse);

      center.dismiss();
      expect(center.notice.value!.dismissed, isTrue);
      expect(center.notice.value!.version, '1.2.0', reason: '忽略只是标记，不应丢掉版本号');

      // 再次忽略是幂等的。
      center.dismiss();
      expect(center.notice.value!.dismissed, isTrue);
    });

    test('没有提示时忽略是空操作，不会凭空造出一条', () {
      final center = UpdateCenter(check: () async => const UpdateNotAvailable(
        currentVersion: '1.0.1',
        latestVersion: '1.0.1',
      ));
      addTearDown(center.dispose);

      center.dismiss();

      expect(center.notice.value, isNull);
    });
  });

  group('设置页卡片读取共享结果', () {
    Future<void> pumpCard(WidgetTester tester, UpdateCenter center) async {
      tester.view.physicalSize = const Size(720, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: UpdateCard(
                updater: _NeverNetworkUpdater(),
                updateCenter: center,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('已有启动检查结果时直接呈现，且卡片自己不发请求', (WidgetTester tester) async {
      final updater = _NeverNetworkUpdater();
      final center = _centerWith(UpdateAvailable(_info(version: '1.2.0')));
      addTearDown(center.dispose);
      await center.checkOnStartup();

      tester.view.physicalSize = const Size(720, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: UpdateCard(updater: updater, updateCenter: center),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('有新版本'), findsOneWidget);
      expect(find.textContaining('1.2.0'), findsOneWidget);
      expect(find.text('下载更新'), findsOneWidget);
      expect(find.text('忽略'), findsOneWidget);
      expect(
        find.text('检查更新'),
        findsNothing,
        reason: '已经有可用更新时不该再显示「先点一次检查」的初始态',
      );
      expect(
        updater.checkCalls,
        0,
        reason: '从共享结果呈现不得触发卡片自己的检查',
      );
    });

    testWidgets('点「忽略」后卡片退回初始态，共享结果也保持忽略', (WidgetTester tester) async {
      final center = _centerWith(UpdateAvailable(_info()));
      addTearDown(center.dispose);
      await center.checkOnStartup();
      await pumpCard(tester, center);

      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();

      expect(center.notice.value!.dismissed, isTrue);
      expect(find.text('检查更新'), findsOneWidget, reason: '忽略后回到初始态，手动检查仍在');
      expect(find.text('有新版本'), findsNothing);
    });

    testWidgets('卡片仍能在不知道共享结果时正常显示初始态', (WidgetTester tester) async {
      final center = UpdateCenter(
        check: () async => const UpdateNotAvailable(
          currentVersion: '1.0.1',
          latestVersion: '1.0.1',
        ),
      );
      addTearDown(center.dispose);
      await pumpCard(tester, center);

      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('有新版本'), findsNothing);
    });
  });

  group('桌面标题栏指示器', () {
    Future<void> pumpTitleBar(
      WidgetTester tester,
      UpdateCenter center,
      VoidCallback onOpen,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      final theme = ThemeController();
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                XvTitleBar(
                  theme: theme,
                  state: state,
                  updateCenter: center,
                  onOpenUpdate: onOpen,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('没有提示时不渲染指示器，有提示时出现并可点击', (WidgetTester tester) async {
      var opened = 0;
      final center = _centerWith(UpdateAvailable(_info(version: '1.2.0')));
      addTearDown(center.dispose);

      await pumpTitleBar(tester, center, () => opened++);
      expect(find.text('发现新版本'), findsNothing, reason: '没有更新时标题栏不应多出任何东西');

      await center.checkOnStartup();
      await tester.pump();

      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.byTooltip('发现新版本 v1.2.0，点击查看'), findsOneWidget);

      await tester.tap(find.byTooltip('发现新版本 v1.2.0，点击查看'));
      await tester.pump();
      expect(opened, 1, reason: '点击应把用户带去更新界面');

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('忽略后指示器消失', (WidgetTester tester) async {
      final center = _centerWith(UpdateAvailable(_info()));
      addTearDown(center.dispose);
      await center.checkOnStartup();
      await pumpTitleBar(tester, center, () {});

      expect(find.text('发现新版本'), findsOneWidget);

      center.dismiss();
      await tester.pump();

      expect(find.text('发现新版本'), findsNothing, reason: '忽略后标题栏不该继续提示');

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('桌面外壳导航接线', () {
    testWidgets('点击标题栏更新入口切到设置页的「版本更新」卡片', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final center = _centerWith(UpdateAvailable(_info()));
      addTearDown(center.dispose);
      await center.checkOnStartup();
      // 外壳内部的标题栏不接收注入参数，走全局单例。
      UpdateCenter.instance = center;
      addTearDown(() => UpdateCenter.instance = null);

      final state = AppState();
      addTearDown(state.dispose);
      final theme = ThemeController();
      addTearDown(theme.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: XvShell(state: state, theme: theme),
        ),
      );
      await tester.pumpAndSettle();

      // 连接页没有「外观」这块设置项。
      expect(find.text('外观'), findsNothing);

      await tester.tap(find.byTooltip('发现新版本 v1.2.0，点击查看'));
      await tester.pumpAndSettle();

      expect(find.text('外观'), findsOneWidget, reason: '应切到设置页');
      expect(find.text('版本更新'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
