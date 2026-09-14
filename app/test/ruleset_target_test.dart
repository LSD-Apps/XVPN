import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/android_vpn_core.dart';
import 'package:xvpn/core/rulesets.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/host_platform.dart';
import 'support/recording_listener.dart';

/// 「检查更新」写到的目录必须就是内核读取规则库的目录。
///
/// 这是一条被真实 bug 破过的不变量：安卓端的更新按桌面端的路径规则写到了
/// `<systemTemp>/XVPN/rulesets`，而内核读的是 APK 资源解包出来的应用私有
/// 目录。界面报告成功、显示的日期也变了，内核却永远用旧规则——用户被明确
/// 告知了一件**没有发生**的事。
///
/// 这里按内核逐条锁住这个等式：更新的目标与交给 `SingBoxConfigBuilder.build`
/// 的目录必须是同一个。
const _wireGuard = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 127.0.0.1:51820
''';

/// 本文件起真实内核时用的端口基准。
///
/// 必须与其它**并发跑**的测试文件不同：`PortAllocator` 是「探测到空闲就释放、
/// 内核随后再绑」，两步之间有窗口（见其文档）。若两个文件都从默认的 2080 起步，
/// 它们可能在同一瞬间各自探到「2080 可用」，于是其中一个内核绑定失败——表现为
/// 随机、难以复现的用例失败。按文件分段即可根除这类竞争。
/// 详见 `SingBoxRunner.portBase`。
const int _portBase = 26080;

/// 假的 APK 资源：内容只需「非空且大于 64 字节」，因为解包的跳过阈值按长度判。
Future<ByteData> _fakeAsset(String asset) async {
  final bytes = Uint8List.fromList(List<int>.generate(128, (i) => i & 0xff));
  return ByteData.sublistView(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.xvpn.xvpn/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('安卓内核：更新目录 == 内核读取目录', () {
    late Directory appDir;

    setUp(() {
      appDir = Directory.systemTemp.createTempSync('xvpn-android-app');
    });
    tearDown(() {
      try {
        if (appDir.existsSync()) appDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 交给系统清理临时目录。
      }
    });

    AndroidVpnCore newCore(RecordingListener listener) {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'filesDir':
            return appDir.path;
          case 'prepareVpn':
            return true;
          case 'status':
            return <String, Object?>{'running': false};
          default:
            return null;
        }
      });
      return AndroidVpnCore(
        listener,
        probesEnabled: false,
        assetLoader: _fakeAsset,
        // 就绪等待压到 0：这条用例只关心「交给 build 的目录」，测试环境里
        // 没有内核可等。
        readyTimeout: Duration.zero,
      );
    }

    test('更新写到解包目录，且该目录就是交给内核的目录', () async {
      final core = newCore(RecordingListener());
      addTearDown(core.dispose);
      String? buildDir;
      core.debugRuleSetDirObserver = (String dir) => buildDir = dir;

      // 更新入口解析出的目录（解包会把出厂副本先落进去）。
      final updateDir = await core.ruleSetUpdateDir();
      expect(updateDir, isNotNull, reason: '安卓内核必须能给出更新目标目录');

      // 走一遍连接启动路径，把「真正交给 build 的目录」记下来。
      final parsed = VpnProtocolFactory.parse(_wireGuard, 'x.conf');
      await core.connect(
        VpnProfile(id: 'x', name: 'x.conf', parsed: parsed),
        const AppSettings(autoConnectOnImport: false),
      );

      expect(buildDir, isNotNull, reason: '连接路径没有走到配置生成');
      expect(
        updateDir!.path,
        buildDir,
        reason: '更新目录与内核读取目录分叉，正是「界面说更新成功、内核照旧用旧规则」的成因',
      );
    });

    test('更新落进解包目录后，下一次连接仍用同一目录且不会被出厂副本盖回', () async {
      final core = newCore(RecordingListener());
      addTearDown(core.dispose);

      final dir = (await core.ruleSetUpdateDir())!.path;
      // 模拟「检查更新」写入的新规则：比出厂副本更长，内容可辨认。
      final updated = File('$dir${Platform.pathSeparator}geosite-cn.srs');
      final marker = Uint8List.fromList(
        List<int>.generate(256, (i) => (i + 1) & 0xff),
      );
      updated.writeAsBytesSync(marker);

      // 再解析一次目标（连接会经过解包）：更新过的文件必须原样保留。
      final again = (await core.ruleSetUpdateDir())!.path;
      expect(again, dir, reason: '解包目录本身不该变化');
      expect(
        updated.readAsBytesSync(),
        marker,
        reason: '更新过的规则被出厂副本盖了回去：用户点了更新，内核却回到旧规则',
      );
    });
  });

  group('桌面内核：更新目录 == 内核读取目录', () {
    test('ensure 与 update 共用同一份目标解析', () {
      final target = Directory.systemTemp.createTempSync('xvpn-target');
      final bundled = Directory.systemTemp.createTempSync('xvpn-bundled');
      addTearDown(() {
        if (target.existsSync()) target.deleteSync(recursive: true);
        if (bundled.existsSync()) bundled.deleteSync(recursive: true);
      });

      // 显式目标：不会碰用户真实的 %LOCALAPPDATA%\XVPN。
      expect(
        RuleSetStore.ensure(bundled, targetDir: target).path,
        target.path,
        reason: 'ensure 必须把显式目标原样交出去，否则内核读的与更新写的会分叉',
      );
      // 未显式指定时退回桌面端可写目录；这里只比较路径，不落盘。
      expect(
        RuleSetStore.resolveTargetDir().path,
        RuleSetStore.writableDir().path,
      );
    });

    test('生产路径上 update 与 build 都取自同一个可写目录', () async {
      // 生产环境没有 runtimeOverride：ruleSetUpdateDir 就是 RuleSetStore
      // 的可写目录，也正是 `_resolveRuntimePaths` 中 ensure 的落点。
      final runner = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(runner.dispose);

      final updateDir = await runner.ruleSetUpdateDir();
      expect(updateDir!.path, RuleSetStore.writableDir().path);
    });

    final exe = hostCoreBinary;
    final assets = Directory('assets/rulesets').absolute;
    final skipReason = !exe.existsSync()
        ? '未找到 ${exe.path}，跳过桌面端的目录等值验证'
        : (!assets.existsSync() ? '未找到规则集目录，跳过桌面端的目录等值验证' : null);

    test(
      'runtimeOverride 下 updater 与 build 拿到同一个目录',
      () async {
        final workDir = Directory.systemTemp.createTempSync('xvpn-ruleset-work');
        final target = Directory.systemTemp.createTempSync('xvpn-ruleset-target');
        addTearDown(() {
          for (final d in <Directory>[workDir, target]) {
            try {
              if (d.existsSync()) d.deleteSync(recursive: true);
            } on FileSystemException {
              // 交给系统清理。
            }
          }
        });

        final runner = SingBoxRunner(
          RecordingListener(),
          probesEnabled: false,
          // 节点不可达，门控必然走满超时；这条用例只关心目录，压到 1 秒。
          readyGateTimeout: const Duration(seconds: 1),
          // 与本文件外的并发用例分段，避免争同一对端口（见 [_portBase]）。
          portBase: _portBase,
          runtimeOverride: CoreRuntime(
            singBoxExe: exe,
            // 内核读的规则集在 target；出厂副本仍取自 assets（检查的是它）。
            ruleSetDir: target,
            assetDir: assets,
            workDir: workDir,
          ),
        );
        addTearDown(runner.dispose);
        String? buildDir;
        runner.debugRuleSetDirObserver = (String dir) => buildDir = dir;

        final updateDir = await runner.ruleSetUpdateDir();
        expect(updateDir!.path, target.path);

        final parsed = VpnProtocolFactory.parse(_wireGuard, 'x.conf');
        await runner.connect(
          VpnProfile(id: 'x', name: 'x.conf', parsed: parsed),
          const AppSettings(autoConnectOnImport: false),
        );

        expect(buildDir, isNotNull, reason: '连接路径没有走到配置生成');
        expect(
          buildDir,
          updateDir.path,
          reason: '桌面端更新目录与交给 build 的目录也必须一致',
        );
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
