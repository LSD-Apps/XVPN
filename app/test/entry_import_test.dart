import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/main.dart';

/// 入口导入（桌面启动参数 / 安卓分享）必须真的弹出确认表单。
///
/// 这两条路径以前都把「本 State 的 context」交给 `showDialog`，而那个 context
/// 在 Navigator **之上**——确认层为了盖住导入对话框，刻意包在 Navigator 外面
/// （见 `main.dart` 的 `MaterialApp.builder`）。于是 `showDialog` 找不到
/// Navigator 直接抛错，被 `_consumeSharedConfig` 的 catch 吞成一条提示，
/// 配置本身**一份都没导入**。
///
/// 真机证据：Kotlin 侧确实收到了分享内容并暂存（logcat 有「已暂存分享的配置」），
/// 但界面毫无反应、`config.json` 里 `profiles` 始终为空。
void main() {
  /// 一份能通过解析的 WireGuard 配置（端点用 RFC 5737 保留地址，不会连出去）。
  const String wireGuardConf = '''
[Interface]
PrivateKey = gPsFLBV6ao4SCIni3vpNP0ZgwGTSXA5ogQ2HzN6ZaFE=
Address = 10.7.0.2/32

[Peer]
PublicKey = WGkkO/PNClTordmGGcrkOJE5jv6Uh0g5zRrUioQvZ2w=
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0
''';

  /// 建一个「已经确认过法律声明」的存档目录。
  ///
  /// 不这样做的话首次启动会盖一层确认层，而它挡住的正是要被观察的那个对话框，
  /// 断言会因为一个与本题无关的原因失败。
  Directory storeWithLegalAck() {
    final dir = Directory.systemTemp.createTempSync('xvpn-entry-import');
    AppStore(dir).save(<String, Object?>{'legalNoticeAcknowledged': true});
    return dir;
  }

  testWidgets('启动参数里的配置会弹出确认表单，而不是静默丢弃', (WidgetTester tester) async {
    final dir = storeWithLegalAck();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final conf = File(
      '${dir.path}${Platform.pathSeparator}launch.conf',
    )..writeAsStringSync(wireGuardConf);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      XvpnApp(launchConfPath: conf.path, store: AppStore(dir)),
    );
    await tester.pumpAndSettle();

    // 确认表单的主按钮。它出现 = 配置走到了「让用户核对再写入」这一步。
    expect(find.text('添加'), findsOneWidget);
    // 底线：绝不能因为弹不出表单就把这份配置丢掉。
    expect(find.text('导入配置'), findsNothing, reason: '配置应当已经进入表单流程');
  });

  testWidgets('确认表单走完之后配置真的写进了存档', (WidgetTester tester) async {
    final dir = storeWithLegalAck();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final conf = File(
      '${dir.path}${Platform.pathSeparator}launch.conf',
    )..writeAsStringSync(wireGuardConf);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      XvpnApp(launchConfPath: conf.path, store: AppStore(dir)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    final saved = AppStore(dir).load();
    final profiles = saved['profiles'];
    expect(profiles, isA<List<Object?>>());
    expect((profiles! as List<Object?>), hasLength(1));
  });

  testWidgets('安卓分享进来的配置同样会弹出确认表单', (WidgetTester tester) async {
    // 安卓拿不到命令行参数，这是除界面导入之外唯一的入口；而它比启动参数那条路
    // 更早——`initState` 里就发起了取内容的通道调用，所以要覆盖的是「第一帧还没
    // 建好时收到分享」这一种时序。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final dir = storeWithLegalAck();
      // 规则集解包目录：安卓的 `filesDir`。给一个真实存在的空临时目录，让
      // `_core.ruleSetUpdateDir()` 不至于直接抛「无法获取应用目录」——那条错误
      // 会被 `unawaited(refreshRuleSetSizes())` 报成未处理异常，淹掉本用例真正
      // 要看的对话框断言。目录为空时解包会停在读 asset 那一步（测试里那是一次
      // 不会推进的真实异步 I/O），不影响本用例。
      final filesDir = Directory.systemTemp.createTempSync('xvpn-shared-files');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        // 解包可能正卡在写第一个文件上（见上），刚创建的临时目录会被 Windows 判
        // 为占用。清不掉就算了：它在系统临时目录里，比让断言失败更有价值。
        try {
          if (filesDir.existsSync()) filesDir.deleteSync(recursive: true);
        } on FileSystemException {
          // 忽略：见上。
        }
      });

      const channel = MethodChannel('com.xvpn.xvpn/vpn');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'takeSharedConfig':
            return <String, Object?>{
              'name': 'xvpn-shared.conf',
              'text': wireGuardConf,
            };
          case 'filesDir':
            return filesDir.path;
          case 'status':
            // 没有正在运行的隧道：让状态接管那条分支直接判定为「没在跑」。
            return <String, Object?>{'running': false};
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(XvpnApp(store: AppStore(dir)));
      await tester.pumpAndSettle();

      expect(
        find.text('添加'),
        findsOneWidget,
        reason: '分享进来的配置必须走确认表单，而不是被静默丢弃或静默写入',
      );
      expect(AppStore(dir).load()['profiles'], isNull, reason: '用户还没确认，不该落盘');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
