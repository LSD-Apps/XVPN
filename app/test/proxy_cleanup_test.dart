import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/system_proxy.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/host_platform.dart';
import 'support/recording_listener.dart';

/// 系统代理的接管 / 还原契约。
///
/// 这两条是整个应用里**唯一会把用户的网络弄坏**的地方：系统代理是全局设置，
/// 一旦「已接管」与「已还原」不配对，用户关掉应用之后所有网站都打不开，而现象
/// 与隧道毫无关系——没人会想到去代理设置里找原因。因此这里把契约写成断言：
///
///   1. 连接成功后确实接管了系统代理；
///   2. 断开时确实还原；
///   3. **还原失败必须出声**——这是此前缺失的一条：失败被静默吞掉，
///      用户只会看到「网络坏了」而拿不到任何线索。
///
/// 用注入的替身来模拟「还原失败」：真实世界里它对应注册表被组策略锁定、权限
/// 不足等情况，测试里没法真的去破坏注册表。**刻意不用平台通道替身**——那需要
/// 初始化 widget binding，而它会拦掉所有真实 HTTP，连接路径（内核就绪要轮询
/// Clash API）根本走不完。
/// 本文件起真实内核时用的端口基准。
///
/// 必须与其它**并发跑**的测试文件不同：`PortAllocator` 是「探测到空闲就释放、
/// 内核随后再绑」，两步之间有窗口（见其文档）。若两个文件都从默认的 2080 起步，
/// 它们可能在同一瞬间各自探到「2080 可用」，于是其中一个内核绑定失败——表现为
/// 随机、难以复现的用例失败。按文件分段即可根除这类竞争。
/// 详见 `SingBoxRunner.portBase`。
const int _portBase = 22080;

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

/// 记录并被注入的假系统代理。
class _FakeProxy implements SystemProxyController {
  _FakeProxy({required this.clearResult});

  /// 还原系统代理的返回值。false 用来模拟「还原失败」。
  final bool clearResult;

  final List<String> calls = <String>[];

  @override
  Future<bool> set({required String host, required int port}) async {
    calls.add('set $host:$port');
    return true;
  }

  @override
  Future<bool> clear() async {
    calls.add('clear');
    return clearResult;
  }

  @override
  Future<bool> recoverIfNeeded() async {
    calls.add('recover');
    return false;
  }
}

void main() {
  final exe = hostCoreBinary;
  final assets = Directory('assets/rulesets').absolute;
  final skipReason = !exe.existsSync()
      ? '未找到 ${exe.path}，跳过系统代理契约验证'
      : (!assets.existsSync() ? '未找到规则集目录，跳过系统代理契约验证' : null);

  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('xvpn-proxy');
  });

  tearDown(() {
    try {
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 进程刚退出时目录可能还被占着一瞬间，交给系统清理。
    }
  });

  /// 跑一轮连接 + 断开，返回（监听器、假代理）。
  Future<({RecordingListener recorder, _FakeProxy proxy})> cycle({
    required bool clearResult,
  }) async {
    final recorder = RecordingListener();
    final fake = _FakeProxy(clearResult: clearResult);
    final runner = SingBoxRunner(
      recorder,
      probesEnabled: false,
      proxy: fake,
      // 指向不可达节点 → 就绪门控必然走满超时。把上限压到 1 秒，否则每个
      // 用例都要白等 20 秒，而这条路径本身与门控无关。
      readyGateTimeout: const Duration(seconds: 1),
      // 与本文件外的并发用例分段，避免争同一对端口（见 [_portBase]）。
      portBase: _portBase,
      runtimeOverride: CoreRuntime(
        singBoxExe: exe,
        ruleSetDir: assets,
        assetDir: assets,
        workDir: workDir,
      ),
    );
    addTearDown(runner.dispose);

    final parsed = VpnProtocolFactory.parse(_conf, 'proxy.conf');
    await runner.connect(
      VpnProfile(id: 'p', name: 'proxy.conf', parsed: parsed),
      const AppSettings(autoConnectOnImport: false),
    );
    await runner.disconnect();
    return (recorder: recorder, proxy: fake);
  }

  test('连接接管系统代理，断开时还原', () async {
    final r = await cycle(clearResult: true);

    expect(
      r.proxy.calls.where((String c) => c.startsWith('set')),
      isNotEmpty,
      reason: '连接成功后必须接管系统代理，否则桌面端根本没有流量入口',
    );
    expect(
      r.proxy.calls,
      contains('clear'),
      reason: '断开时必须还原系统代理，否则用户断网且看不出原因',
    );
    expect(
      r.recorder.errors.any((String e) => e.contains('没能还原系统代理')),
      isFalse,
      reason: '还原成功时不该报错：${r.recorder.errors}',
    );
  }, skip: skipReason);

  test('还原系统代理失败时必须告知用户，而不是静默失败', () async {
    final r = await cycle(clearResult: false);

    expect(
      r.recorder.errors.any((String e) => e.contains('没能还原系统代理')),
      isTrue,
      reason:
          '还原失败意味着系统代理仍指着已退出的内核，用户所有网站都打不开；'
          '此时必须给出可操作的提示。实际错误：${r.recorder.errors}',
    );
  }, skip: skipReason);

  test('断开后内核进程与 PID 文件都收干净', () async {
    await cycle(clearResult: true);

    final pidFile = File('${workDir.path}${Platform.pathSeparator}core.pid');
    expect(
      pidFile.existsSync(),
      isFalse,
      reason: '断开后 PID 文件应当被删掉，否则下次启动会去杀一个已经不在的进程',
    );
  }, skip: skipReason);
}
