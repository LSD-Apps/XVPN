import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/updater.dart';
import 'package:xvpn/screens/settings_screen.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/version.dart';
import 'package:xvpn/widgets/common.dart';
import 'package:xvpn/widgets/update_card.dart';

/// 更新卡片的界面测试。
///
/// 全部用注入的替身引擎驱动，**不联网、不替换任何安装目录**：真实的更新流程要
/// 有已发布的 Release 与可写安装目录才能走通，而这里要锁定的是「引擎的每种
/// 结构化结果分别对应哪种界面」，以及最容易出错的两条纪律——
/// **没有用户确认就不安装**、**桌面端安装后退出而安卓绝不退出**。

/// 替身 HTTP 客户端。任何一次真实请求都说明测试走错了分支。
class _NoopHttpClient implements UpdateHttpClient {
  const _NoopHttpClient();

  @override
  Future<UpdateHttpResponse> send(Uri url) =>
      Future<UpdateHttpResponse>.error(UnsupportedError('测试不应发起网络请求'));
}

/// 可编排的替身引擎。
///
/// 直接继承真实 [Updater] 并覆盖三个操作入口，这样卡片拿到的仍是真类型，
/// 平台判断（[Updater.platform]）也保持一致。
class _FakeUpdater extends Updater {
  // 需要给 [Updater] 传一个不联网的 HTTP 替身，因此不能把这两个参数写成
  // super 参数（显式 `super(...)` 与 super 参数不能并存）。
  // ignore: use_super_parameters
  _FakeUpdater({
    required TargetPlatform platform,
    String currentVersion = '1.0.0',
  }) : super(
         platform: platform,
         currentVersion: currentVersion,
         http: const _NoopHttpClient(),
       );

  UpdateCheckResult checkResult = const UpdateCheckFailure('未设置检查结果');
  UpdateDownloadResult Function(DownloadProgressCallback? onProgress)? onDownload;
  UpdateInstallResult installResult = const UpdateInstallFailure('未设置安装结果');

  /// 非 null 时对应操作挂起，测试据此观察「进行中」状态。
  Completer<UpdateCheckResult>? pendingCheck;
  Completer<UpdateDownloadResult>? pendingDownload;

  /// 最近一次下载收到的进度回调，用于在「下载中」主动推进进度。
  DownloadProgressCallback? lastProgress;
  UpdateCancellation? lastCancellation;

  int checkCalls = 0;
  int installCalls = 0;

  @override
  Future<UpdateCheckResult> checkForUpdate() {
    checkCalls++;
    final pending = pendingCheck;
    if (pending != null) return pending.future;
    return Future<UpdateCheckResult>.value(checkResult);
  }

  @override
  Future<UpdateDownloadResult> download(
    UpdateInfo info, {
    DownloadProgressCallback? onProgress,
    UpdateCancellation? cancellation,
  }) {
    lastCancellation = cancellation;
    lastProgress = onProgress;
    final pending = pendingDownload;
    if (pending != null) return pending.future;
    return Future<UpdateDownloadResult>.value(
      onDownload?.call(onProgress) ?? const UpdateDownloadFailure('未设置下载结果'),
    );
  }

  @override
  Future<UpdateInstallResult> install(UpdateInfo info, File artifact) {
    installCalls++;
    return Future<UpdateInstallResult>.value(installResult);
  }

  @override
  void dispose() {}
}

UpdateInfo _info({
  String version = '1.2.0',
  int? assetSize = 2048,
  String? notes = '修复了若干问题。',
}) => UpdateInfo(
  tag: 'v$version',
  version: version,
  platform: UpdatePlatform.windows,
  assetName: 'XVPN-$version-windows-x64.zip',
  assetUri: Uri.parse('https://example.net/win.zip'),
  checksumsName: 'SHA256SUMS.txt',
  checksumsUri: Uri.parse('https://example.net/SHA256SUMS.txt'),
  assetSize: assetSize,
  pageUri: Uri.parse('https://github.com/LSD-Apps/XVPN/releases/tag/v$version'),
  notes: notes,
);

/// 渲染卡片并注入所有替身。
Future<void> _pumpCard(
  WidgetTester tester,
  _FakeUpdater updater, {
  bool compact = false,
  List<int>? exits,
  List<Uri>? opened,
}) async {
  tester.view.physicalSize = const Size(720, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildXvTheme(XvPalette.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: UpdateCard(
            compact: compact,
            updater: updater,
            openExternalUrl: (Uri uri) async {
              opened?.add(uri);
              return true;
            },
            exitProcess: (int code) => exits?.add(code),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('初始状态显示当前版本与「检查更新」，且不自动联网', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.windows);
    await _pumpCard(tester, updater);

    expect(find.text('版本更新'), findsOneWidget);
    expect(find.textContaining(appVersion), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(updater.checkCalls, 0, reason: '打开设置页不应自动发起检查');
  });

  testWidgets('检查中：出现进度指示且「检查更新」被禁用', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..pendingCheck = Completer<UpdateCheckResult>();
    await _pumpCard(tester, updater);

    await tester.tap(find.text('检查更新'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<XvButton>(
      find.widgetWithText(XvButton, '检查更新'),
    );
    expect(button.onPressed, isNull, reason: '检查进行中重复点击不应再触发一次');
    expect(updater.checkCalls, 1);

    updater.pendingCheck!.complete(const UpdateCheckFailure('网络不可用'));
    await tester.pumpAndSettle();
  });

  testWidgets('没有更新时给出平静的「已是最新版本」，不渲染成错误', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..checkResult = const UpdateNotAvailable(
        currentVersion: '1.0.0',
        latestVersion: '1.0.0',
      );
    await _pumpCard(tester, updater);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已是最新版本'), findsOneWidget);
    expect(find.textContaining('1.0.0'), findsWidgets, reason: '应带上最新版本号');
    expect(
      find.byIcon(Icons.error_outline),
      findsNothing,
      reason: '「已经最新」是最常见的结果，不该用告警样式吓人',
    );
    // 仍然可以再查一次。
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('有更新时显示新版本号、说明与「下载更新」', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..checkResult = UpdateAvailable(_info(version: '1.2.0'));
    await _pumpCard(tester, updater);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1.2.0'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);
    expect(find.text('查看发布页'), findsOneWidget);
  });

  testWidgets('「查看发布页」走应用既有的外部打开机制', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..checkResult = UpdateAvailable(_info(version: '1.2.0'));
    final opened = <Uri>[];
    await _pumpCard(tester, updater, opened: opened);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看发布页'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.toString(), contains('/releases/tag/v1.2.0'));
  });

  testWidgets('下载中：显示确定进度与「取消」，取消会触发取消令牌', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..checkResult = UpdateAvailable(_info())
      ..pendingDownload = Completer<UpdateDownloadResult>();
    await _pumpCard(tester, updater);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pump();

    updater.lastProgress!(512, 1024);
    await tester.pump();
    expect(find.textContaining('512 B'), findsOneWidget);
    expect(find.textContaining('1 KB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(updater.lastCancellation!.isCancelled, isTrue);

    updater.pendingDownload!.complete(const UpdateDownloadCancelled());
    await tester.pumpAndSettle();
    expect(find.textContaining('已取消下载'), findsOneWidget);
  });

  testWidgets('下载失败：直接渲染引擎给出的中文原因', (WidgetTester tester) async {
    const message = '下载校验文件失败：无法连接更新服务器，请检查网络后重试。';
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..checkResult = UpdateAvailable(_info())
      ..onDownload = (_) => const UpdateDownloadFailure(message);
    await _pumpCard(tester, updater);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('重试下载'), findsOneWidget);
  });

  testWidgets('下载完成后必须先确认，安装才会真的发生', (WidgetTester tester) async {
    final separator = Platform.pathSeparator;
    final file = File('${Directory.systemTemp.path}${separator}xvpn-test.zip');
    final updater = _FakeUpdater(platform: TargetPlatform.windows)
      ..checkResult = UpdateAvailable(_info())
      ..onDownload = ((_) => UpdateDownloaded(file, 'a' * 64))
      ..installResult = const UpdateInstallStarted('更新程序已启动。');
    final exits = <int>[];
    await _pumpCard(tester, updater, exits: exits);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();

    expect(updater.installCalls, 0, reason: '下载完成不等于用户同意安装');
    expect(find.text('安装更新'), findsOneWidget, reason: '必须先问一次再替换');

    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pump();

    expect(updater.installCalls, 1);
    expect(
      exits,
      <int>[0],
      reason: '桌面端重启助手在等进程退出，确认安装后必须退出应用',
    );
  });

  testWidgets('安卓：缺权限时给出重试入口，且任何结果都不退出应用', (WidgetTester tester) async {
    final updater = _FakeUpdater(platform: TargetPlatform.android)
      ..checkResult = UpdateAvailable(_info())
      ..onDownload = ((_) => UpdateDownloaded(File('xvpn.apk'), 'a' * 64))
      ..installResult = const UpdateInstallPermissionRequired(
        '需要先允许 XVPN 安装未知应用。已为你打开系统设置，授权后请返回重试。',
      );
    final exits = <int>[];
    await _pumpCard(tester, updater, exits: exits);

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('未知应用'), findsOneWidget);
    expect(find.text('重试安装'), findsOneWidget);
    expect(exits, isEmpty, reason: '安卓的安装界面由系统弹出，应用绝不能自行退出');

    await tester.tap(find.text('重试安装'));
    await tester.pump();
    expect(updater.installCalls, 2, reason: '授权后应能直接重试');
  });

  testWidgets('设置页仍保留「关于 / 开源许可」，并新增「版本更新」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
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
          body: SettingsScreen(state: state, compact: false, theme: theme),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('版本更新'), findsOneWidget);
    expect(find.byType(UpdateCard), findsOneWidget);
    // 新卡片不能把已有的「关于」卡片挤掉。
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
  });
}
