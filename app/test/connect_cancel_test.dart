import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/system_proxy.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/host_platform.dart';
import 'support/recording_listener.dart';

/// 「一次连接尝试可以被取消」这条能力的回归用例。
///
/// 之前没有任何取消路径：圆环在 connecting / warmingUp 时是禁用的，用户只能
/// 干等门控超时（最多 20 秒）。这里的重点不是「按钮点了有反应」，而是**被取消
/// 的尝试不会在之后把状态翻回来**——否则取消只是把界面刷了一下，几秒后它又
/// 显示「已连接」，比没有取消按钮更糟。
///
/// 三个层次各测一遍：
///   1. 真实 [DemoVpnCore]：取消后驱动被取代的续跑走完，状态不被翻回；
///   2. 可控替身：取消立刻收手、未连接时是空操作、已连接时按断开处理；
///   3. 真实随包内核（缺少二进制时跳过）：取消后进程、PID 文件、系统代理都收干净。
/// 本文件起真实内核时用的端口基准。
///
/// 必须与其它**并发跑**的测试文件不同：`PortAllocator` 是「探测到空闲就释放、
/// 内核随后再绑」，两步之间有窗口（见其文档）。若两个文件都从默认的 2080 起步，
/// 它们可能在同一瞬间各自探到「2080 可用」，于是其中一个内核绑定失败——表现为
/// 随机、难以复现的用例失败。按文件分段即可根除这类竞争。
/// 详见 `SingBoxRunner.portBase`。
const int _portBase = 25080;

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

/// 一个「每轮连接都停在可控门控上」的替身内核。
///
/// 它遵守与真实内核相同的取消约定（每个 await 之后复查令牌），因此可以用它
/// 精确构造「取消 → 被取代的续跑才走完」这个顺序，而不依赖任何定时器。
class _ControllableCore extends VpnCore {
  _ControllableCore(super.listener);

  @override
  String get name => 'controllable';

  @override
  bool get supportsHandshakeState => false;

  final List<ConnectAttempt?> attempts = <ConnectAttempt?>[];
  int disconnectCalls = 0;

  /// 本轮是否占着「进程 / 系统代理 / VpnService」这类需要收尾的资源。
  bool resourcesHeld = false;

  Completer<void>? _pending;

  /// 放行停在门控上的那一轮连接。
  void release() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  @override
  Future<void> connect(
    VpnProfile profile,
    AppSettings settings, {
    ConnectAttempt? attempt,
  }) async {
    attempts.add(attempt);
    listener.onStatusChanged(VpnStatus.connecting);
    resourcesHeld = true;
    final gate = _pending = Completer<void>();
    await gate.future;
    // 与真实内核同一条约定：被取消的尝试必须收手，不能宣布已连接、也不能
    // 继续占着资源。
    if (isDisposed || (attempt?.isCancelled ?? false)) {
      resourcesHeld = false;
      return;
    }
    listener.onStatusChanged(VpnStatus.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    resourcesHeld = false;
    release();
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  @override
  void initAutoRoute(Object? saved) {}

  @override
  List<Map<String, Object?>> exportAutoRoute() =>
      const <Map<String, Object?>>[];
}

/// 一个把「等隧道能载流量」交给真实就绪门控的替身。
///
/// 用它来量「预热期间取消」到底多快收手：门控的超时设成 30 秒，取消若真要等
/// 满超时就不可能通过，因此这条断言能抓住「取消被忽略、继续干等」的回归。
class _WarmingCore extends VpnCore {
  _WarmingCore(super.listener);

  @override
  String get name => 'warming';

  @override
  bool get supportsHandshakeState => false;

  @override
  Future<void> connect(
    VpnProfile profile,
    AppSettings settings, {
    ConnectAttempt? attempt,
  }) async {
    listener.onStatusChanged(VpnStatus.connecting);
    await runTunnelReadyGate(
      listener: listener,
      // 永远探测不通：模拟「门控要等满超时」的那种坏配置。
      probe: () async => null,
      isAborted: () => attempt?.isCancelled ?? false,
      timeout: const Duration(seconds: 30),
      interval: const Duration(milliseconds: 10),
    );
  }

  @override
  Future<void> disconnect() async {
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  @override
  void initAutoRoute(Object? saved) {}

  @override
  List<Map<String, Object?>> exportAutoRoute() =>
      const <Map<String, Object?>>[];
}

/// 记录并被注入的假系统代理，用来断言取消后没有留下死端口。
class _RecordingProxy implements SystemProxyController {
  final List<String> calls = <String>[];

  int get setCalls => calls.where((String c) => c.startsWith('set')).length;

  int get clearCalls => calls.where((String c) => c == 'clear').length;

  @override
  Future<bool> set({required String host, required int port}) async {
    calls.add('set $host:$port');
    return true;
  }

  @override
  Future<bool> clear() async {
    calls.add('clear');
    return true;
  }

  @override
  Future<bool> recoverIfNeeded() async {
    calls.add('recover');
    return false;
  }
}

void main() {
  group('取消连接尝试（真实演示内核）', () {
    test('连接中取消：落到未连接、不报错，被取代的续跑不会把状态翻回去', () async {
      final state = AppState();
      addTearDown(state.dispose);
      state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
      state.importConf(text: _conf, fileName: 'wg.conf');

      final connectFuture = state.connect();
      // DemoVpnCore 先广播 connecting、700ms 后才宣布已连接，此刻正是用户
      // 会看到「连接中…」并且应该能取消的时刻。
      expect(state.status, VpnStatus.connecting);

      await state.cancelConnect();
      expect(state.status, VpnStatus.disconnected);
      expect(state.lastError, isNull, reason: '取消是用户的选择，不该留下错误');

      // 驱动被取代的续跑走完（DemoVpnCore 的 700ms 之后会复查令牌）。
      await connectFuture;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        state.status,
        VpnStatus.disconnected,
        reason: '被取消的尝试事后把状态翻回已连接，取消就等于没做',
      );
      expect(state.lastError, isNull);
    });

    test('未连接时取消是无害的空操作', () async {
      final state = AppState(
        coreFactory: (VpnCoreListener l) => _ControllableCore(l),
      );
      final core = state.core as _ControllableCore;
      addTearDown(state.dispose);
      state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
      state.importConf(text: _conf, fileName: 'wg.conf');

      await state.cancelConnect();

      expect(core.attempts, isEmpty, reason: '没有尝试在飞时取消不该顺手发起任何连接');
      expect(core.disconnectCalls, 0, reason: '没有在飞的尝试时不必去动内核');
      expect(state.status, VpnStatus.disconnected);
      expect(state.lastError, isNull);
    });
  });

  group('取消连接尝试（可控替身）', () {
    late _ControllableCore core;
    late AppState state;

    setUp(() {
      state = AppState(
        coreFactory: (VpnCoreListener l) => _ControllableCore(l),
      );
      core = state.core as _ControllableCore;
      state.updateSettings(state.settings.copyWith(autoConnectOnImport: false));
      state.importConf(text: _conf, fileName: 'wg.conf');
    });

    tearDown(() {
      state.dispose();
    });

    test('取消把令牌交给内核，并等到确实收手：状态与资源都不被续跑改动', () async {
      final connectFuture = state.connect();
      expect(state.status, VpnStatus.connecting);
      expect(core.resourcesHeld, isTrue);
      expect(core.attempts.single, isNotNull, reason: '核心没拿到取消令牌，就无法判断自己已被取代');

      await state.cancelConnect();
      expect(core.attempts.single!.isCancelled, isTrue);
      expect(core.disconnectCalls, 1);
      expect(core.resourcesHeld, isFalse);
      expect(state.status, VpnStatus.disconnected);
      expect(state.lastError, isNull);

      // 明确地驱动「被取代的续跑」走完，再断言它没有把状态翻回来。
      core.release();
      await connectFuture;
      await Future<void>.delayed(Duration.zero);
      expect(state.status, VpnStatus.disconnected);
      expect(core.resourcesHeld, isFalse);
      expect(state.lastError, isNull);
    });

    test('建立隧道中取消：立刻收手，不等满 30 秒的就绪超时', () async {
      final warmingState = AppState(
        coreFactory: (VpnCoreListener l) => _WarmingCore(l),
      );
      addTearDown(warmingState.dispose);
      warmingState.updateSettings(
        warmingState.settings.copyWith(autoConnectOnImport: false),
      );
      warmingState.importConf(text: _conf, fileName: 'wg.conf');

      final connectFuture = warmingState.connect();
      expect(
        warmingState.status,
        VpnStatus.warmingUp,
        reason: '门控一开始就应广播「建立隧道中」，而不是停在连接中',
      );

      final watch = Stopwatch()..start();
      await warmingState.cancelConnect();
      await connectFuture;
      watch.stop();

      expect(warmingState.status, VpnStatus.disconnected);
      expect(warmingState.lastError, isNull);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: '取消若被忽略，这里会一直等到 30 秒的门控超时',
      );
    });

    test('取消是幂等的：连点两次不会出错，第二次仍是未连接', () async {
      final connectFuture = state.connect();
      expect(state.status, VpnStatus.connecting);

      await state.cancelConnect();
      await state.cancelConnect();

      expect(state.status, VpnStatus.disconnected);
      expect(core.disconnectCalls, 1, reason: '第二次取消时已经没有在飞的尝试，应直接返回');
      core.release();
      await connectFuture;
      expect(state.status, VpnStatus.disconnected);
    });

    test('尝试已经成功时取消：按普通断开处理', () async {
      final connectFuture = state.connect();
      core.release();
      await connectFuture;
      expect(state.status, VpnStatus.connected);

      await state.cancelConnect();

      expect(state.status, VpnStatus.disconnected);
      expect(core.disconnectCalls, 1);
      expect(state.lastError, isNull);
    });

    test('取消之后立刻重连是新一轮，而不是同一轮被启动两遍', () async {
      final connectFuture = state.connect();
      expect(core.attempts, hasLength(1));

      await state.cancelConnect();
      final reconnect = state.connect();
      await Future<void>.delayed(Duration.zero);
      expect(core.attempts, hasLength(2), reason: '取消不是第二次连接，重连才产生新一轮');
      expect(core.attempts.first!.isCancelled, isTrue);
      expect(core.attempts.last!.isCancelled, isFalse);

      core.release();
      await connectFuture;
      await reconnect;
      await Future<void>.delayed(Duration.zero);
      // 新一轮也应能正常到达已连接：取消不该把整条链路弄坏。
      expect(state.status, anyOf(VpnStatus.connecting, VpnStatus.connected));
    });
  });

  group('等待内核就绪的轮询在取消时收手', () {
    test('waitForApi 被取消后立刻返回，不等满超时', () async {
      // 端口指向一个没人监听的回环端口：探测会很快失败，循环继续下一次；
      // 取消若被忽略，这里会一直轮到 30 秒上限。全程只有本机连接尝试。
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: RecordingListener(),
          clashApiPort: 1,
          probesEnabled: false,
        ),
      );
      addTearDown(monitor.dispose);

      var cancelled = false;
      final timer = Timer(
        const Duration(milliseconds: 50),
        () => cancelled = true,
      );
      addTearDown(timer.cancel);

      final watch = Stopwatch()..start();
      final ready = await monitor.waitForApi(
        const Duration(seconds: 30),
        isCancelled: () => cancelled,
      );
      watch.stop();

      expect(ready, isFalse);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: '取消必须让等就绪这一步立刻收手，而不是把 12 / 25 秒的上限等满',
      );
    });
  });

  group('取消真实内核（需要随包二进制）', () {
    final exe = hostCoreBinary;
    final assets = Directory('assets/rulesets').absolute;
    final skipReason = !exe.existsSync()
        ? '未找到 ${exe.path}，跳过真实内核的取消路径验证'
        : (!assets.existsSync() ? '未找到规则集目录，跳过真实内核的取消路径验证' : null);

    late Directory workDir;

    setUp(() {
      workDir = Directory.systemTemp.createTempSync('xvpn-cancel');
    });

    tearDown(() {
      try {
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 进程刚退出时目录可能还被占着一瞬间，交给系统清理。
      }
    });

    test('等待就绪时取消：进程、PID 文件、系统代理都收干净', () async {
      final recorder = RecordingListener();
      final proxy = _RecordingProxy();
      final runner = SingBoxRunner(
        recorder,
        probesEnabled: false,
        proxy: proxy,
        // 节点不可达，取消若无效就会一直等到这个上限。
        readyGateTimeout: const Duration(seconds: 3),
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

      final parsed = VpnProtocolFactory.parse(_conf, 'cancel.conf');
      final attempt = ConnectAttempt(1);
      final connectFuture = runner.connect(
        VpnProfile(id: 'p', name: 'cancel.conf', parsed: parsed),
        const AppSettings(autoConnectOnImport: false),
        attempt: attempt,
      );

      // 等到内核就绪并接管了系统代理——那一刻之后的等待正是「建立隧道中」。
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (proxy.setCalls == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(proxy.setCalls, greaterThan(0), reason: '内核没能在预期时间内就绪');

      final pidFile = File('${workDir.path}${Platform.pathSeparator}core.pid');
      final pid = int.parse(pidFile.readAsStringSync().trim());
      expect(isCoreProcessAlive(pid), isTrue);

      // 用户取消。AppState 的路径是「作废令牌 + 调用内核的断开」，这里照做。
      attempt.cancel();
      await connectFuture;
      await runner.disconnect();

      expect(recorder.statuses.last, VpnStatus.disconnected);
      expect(
        proxy.clearCalls,
        greaterThan(0),
        reason: '取消后系统代理必须还原，否则浏览器会全部打不开',
      );
      expect(pidFile.existsSync(), isFalse, reason: '取消后 PID 文件应当清掉');
      expect(
        isCoreProcessAlive(pid),
        isFalse,
        reason: '取消后不能留下孤儿内核进程——它会一直占着端口',
      );
      expect(
        recorder.errors.where((String e) => e.contains('启动失败')),
        isEmpty,
        reason: '取消是用户的选择，不该被报成启动失败：${recorder.errors}',
      );
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 2)));
  });
}
