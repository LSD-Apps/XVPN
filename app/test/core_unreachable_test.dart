import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/tunnel_health.dart';

import 'support/recording_listener.dart';

/// 可控的假 Clash API：能在「正常应答」与「完全不应答」之间切换。
class _SwitchableClashClient implements HttpClient {
  bool failing = false;
  int requests = 0;

  /// 每次成功应答返回的正文。
  String body = jsonEncode(<String, Object?>{
    'downloadTotal': 1000,
    'uploadTotal': 500,
    'memory': 1024,
    'connections': <Object?>[],
  });

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    if (failing) {
      // 与真实情况一致：连接被拒 / 超时都表现为抛异常，_get 会吞掉并返回 null。
      throw const SocketException('内核不应答');
    }
    return _FakeRequest(body);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.body);

  final String body;

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(String body) : _bytes = utf8.encode(body);

  final List<int> _bytes;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late RecordingListener listener;
  late _SwitchableClashClient client;
  late CoreMonitor monitor;

  CoreMonitor build({
    int threshold = 2,
    bool probesEnabled = false,
    Future<int?> Function()? tunnel,
    Future<int?> Function()? direct,
  }) {
    listener = RecordingListener();
    client = _SwitchableClashClient();
    return CoreMonitor(
      CoreMonitorHooks(
        listener: listener,
        clashApiPort: 2081,
        probesEnabled: probesEnabled,
        unreachableThreshold: threshold,
        latencyProbeInterval: Duration.zero,
        httpClient: client,
        tunnelLatencyProbe: tunnel,
        directLatencyProbe: direct,
      ),
    );
  }

  tearDown(() => monitor.dispose());

  test('偶尔一次读不到内核不下结论', () async {
    monitor = build();

    client.failing = true;
    await monitor.tick();

    expect(listener.healthReports, isEmpty, reason: '内核正忙时偶尔超时是正常的');
  });

  test('连续读不到内核时判定为内核卡住，并要求恢复', () async {
    monitor = build(threshold: 3);

    client.failing = true;
    for (var i = 0; i < 3; i++) {
      await monitor.tick();
    }

    expect(listener.healthReports, hasLength(1));
    final health = listener.healthReports.single;
    expect(health.verdict, TunnelHealthVerdict.coreUnreachable);
    expect(health.consecutiveFailures, 3);
    expect(health.shouldRecover, isTrue, reason: '内核卡住时重启是唯一能立刻恢复的手段');
    expect(health.summary, contains('内核'));
    expect(
      health.directLatencyMillis,
      isNull,
      reason: '回环上的失败与本地网络无关，不需要也不该拿直连做对照',
    );
  });

  test('同一结论只上报一次', () async {
    monitor = build(threshold: 2);

    client.failing = true;
    for (var i = 0; i < 8; i++) {
      await monitor.tick();
    }

    expect(listener.healthReports, hasLength(1), reason: '每秒钟重复一句同样的话只会刷屏');
  });

  test('恢复应答后补报一次健康', () async {
    monitor = build(threshold: 2);

    client.failing = true;
    await monitor.tick();
    await monitor.tick();
    expect(
      listener.healthReports.single.verdict,
      TunnelHealthVerdict.coreUnreachable,
    );

    client.failing = false;
    await monitor.tick();

    expect(listener.healthReports, hasLength(2));
    expect(
      listener.healthReports.last.verdict,
      TunnelHealthVerdict.healthy,
      reason: '没有这条「已恢复」，自愈限流器会永远停在上一次事故里',
    );
  });

  test('恢复后重新计数：不会因为历史失败而立刻再次判定', () async {
    monitor = build(threshold: 3);

    client.failing = true;
    await monitor.tick();
    await monitor.tick();

    // 中间恢复一次。
    client.failing = false;
    await monitor.tick();

    // 再失败两次：计数应当从头开始，不该凑够 3。
    client.failing = true;
    await monitor.tick();
    await monitor.tick();

    expect(
      listener.healthReports.where((TunnelHealth h) => h.isProblem),
      isEmpty,
      reason: '计数必须真的清零，否则零星的失败会累积成一次误判',
    );
  });

  test('读不到内核不会顺带得出「隧道不通」的结论', () async {
    // 两条信号是正交的：读不到内核时连延迟探测都做不了，
    // 硬报「隧道不通」等于在没证据的情况下下判断。
    monitor = build(threshold: 2);

    client.failing = true;
    for (var i = 0; i < 5; i++) {
      await monitor.tick();
    }

    expect(
      listener.healthReports.map((TunnelHealth h) => h.verdict),
      everyElement(TunnelHealthVerdict.coreUnreachable),
    );
    expect(listener.latencies, isEmpty, reason: '读不到内核时不该上报任何延迟');
  });

  test('成功采样不会冲掉「隧道不通」的结论', () async {
    // 共用同一个结论字段，两条信号谁都不该清对方：
    // 隧道不通但 API 正常应答是完全可能的（隧道卡住、进程还活着）。
    monitor = build(
      probesEnabled: true,
      tunnel: () async => null,
      direct: () async => 20,
    );

    for (var i = 0; i < 3; i++) {
      await monitor.tick();
    }
    expect(
      listener.healthReports.last.verdict,
      TunnelHealthVerdict.tunnelDown,
      reason: '前提：此刻 API 是通的，结论应当是隧道不通',
    );

    // API 继续正常应答，隧道仍然不通。
    final before = listener.healthReports.length;
    await monitor.tick();
    await monitor.tick();

    expect(
      listener.healthReports.length,
      before,
      reason: '每次成功采样都补报一次健康，会把「隧道不通」冲成「恢复正常」',
    );
  });

  group('等内核就绪的轮询节奏', () {
    test('开头密集，随后逐步放宽', () {
      // 内核实测 540–600ms 就绪，而探测点原本落在 0/300/600/900ms 上，
      // 于是最坏情况会白等将近一整个间隔。这条守住「开头要密」。
      expect(
        CoreMonitor.readinessPollDelay(const Duration(milliseconds: 0)),
        const Duration(milliseconds: 25),
      );
      expect(
        CoreMonitor.readinessPollDelay(const Duration(milliseconds: 550)),
        const Duration(milliseconds: 25),
        reason: '内核就绪的时间点正落在这个区间，必须仍然密集探测',
      );
      expect(
        CoreMonitor.readinessPollDelay(const Duration(milliseconds: 1500)),
        const Duration(milliseconds: 100),
      );
      expect(
        CoreMonitor.readinessPollDelay(const Duration(seconds: 8)),
        const Duration(milliseconds: 300),
        reason: '明显失败时不必空转，放宽即可',
      );
    });

    test('间隔随时间单调放宽，不会来回跳', () {
      var previous = Duration.zero;
      for (var ms = 0; ms <= 12000; ms += 50) {
        final delay = CoreMonitor.readinessPollDelay(
          Duration(milliseconds: ms),
        );
        expect(
          delay >= previous,
          isTrue,
          reason: '$ms ms 处的间隔比上一档更短了，探测节奏会变得不可预测',
        );
        previous = delay;
      }
    });
  });
}
