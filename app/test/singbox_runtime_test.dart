import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/port_allocator.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/recording_listener.dart';

/// 用**真实内核**跑一遍生成的配置，并让流量真的穿过去。
///
/// 这是目前唯一一条覆盖「随包分发的三样东西能不能一起工作」的测试：
///   * 生成的配置（`SingBoxConfigBuilder`）；
///   * 随包分发的规则集（geosite-cn.srs / geoip-cn.srs）；
///   * 随包分发的内核（sing-box.exe）。
///
/// 已有的两处都覆盖不到这一段：
///   * JSON 结构断言只看配置长什么样，不看内核认不认；
///   * `sing-box check` 只校验 schema——**它不加载规则集**。规则集文件损坏或
///     与内核版本不匹配时，check 会通过，而 `run` 会在路由引擎初始化时直接
///     起不来。那正是「用户点了连接却连不上」的一种。
///
/// 不需要真实的 VPN 服务端：请求打向本机地址，会命中内置的
/// `ip_is_private → direct` 规则，因此走直连出站，隧道端点只参与初始化。
const _wireGuard = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
DNS = 223.5.5.5
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
''';

/// 一次跑起来的内核 + 它的端口，以及负责收尾的东西。
class _Runtime {
  _Runtime({
    required this.process,
    required this.log,
    required this.mixedPort,
    required this.apiPort,
    required this.configFile,
  });

  final Process process;
  final StringBuffer log;
  final int mixedPort;
  final int apiPort;
  final File configFile;

  var _stopped = false;

  /// 收尾。**幂等**，因此可以既在用例末尾显式调用、又挂进 tearDown。
  ///
  /// 为什么要显式调用而不只靠 tearDown：tearDown 是后进先出，而这个进程是
  /// 最早注册的，因此它最后才被执行。中间任何一步卡住（例如 `HttpServer.close()`
  /// 等一个没关掉的连接），收尾就会被推迟——开发时留下的那些「跑完测试还在后台
  /// 占着端口的 sing-box」就是这么来的。
  Future<void> shutdown() async {
    if (_stopped) return;
    _stopped = true;
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    if (configFile.existsSync()) configFile.deleteSync();
  }
}

void main() {
  final exe = File('assets/bin/sing-box.exe');
  final rulesets = Directory('assets/rulesets');
  final skipReason = !exe.existsSync()
      ? '未找到 ${exe.path}，跳过运行时校验'
      : (!rulesets.existsSync() ? '未找到规则集目录，跳过运行时校验' : null);

  /// 起一个真实内核。端口用统一的分配器挑：2080 在开发机上很可能被别的东西
  /// 占着，写死端口会让这些测试变成偶发失败。
  Future<_Runtime> boot() async {
    final ports = await PortAllocator.allocate(
      from: SingBoxConfigBuilder.defaultMixedPort,
      count: 2,
    );
    expect(ports, hasLength(2), reason: '找不到两个可用端口，环境不正常');

    final parsed = VpnProtocolFactory.parse(_wireGuard, 'runtime.conf');
    final config = SingBoxConfigBuilder.build(
      profile: parsed,
      splitMode: SplitMode.smart,
      ruleSetDir: rulesets.absolute.path,
      mixedPort: ports[0],
      clashApiPort: ports[1],
      logSplits: true,
    );
    final configFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'xvpn-runtime-${ports[0]}.json',
    );
    configFile.writeAsStringSync(SingBoxConfigBuilder.encode(config));

    final process = await Process.start(
      exe.absolute.path,
      <String>['run', '-c', configFile.path],
      workingDirectory: Directory.systemTemp.path,
      runInShell: false,
    );
    // 内核的输出必须被读走：管道写满之后内核会阻塞在写日志上，
    // 表现成「莫名其妙地卡住」。
    final log = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);

    final runtime = _Runtime(
      process: process,
      log: log,
      mixedPort: ports[0],
      apiPort: ports[1],
      configFile: configFile,
    );
    addTearDown(runtime.shutdown);
    return runtime;
  }

  HttpClient newClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 3);

  test(
    '真实内核能用生成的配置启动，并让流量穿过混合入站',
    () async {
      final runtime = await boot();
      final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      site.listen((HttpRequest request) {
        request.response
          ..statusCode = 200
          ..write('XVPN-RUNTIME-OK');
        request.response.close();
      });
      addTearDown(site.close);

      final client = newClient();
      addTearDown(() => client.close(force: true));

      // 1) 等 Clash API 应答。它能应答就说明配置**与规则集**都已经加载完成。
      expect(
        await _waitForApi(client, runtime.apiPort, const Duration(seconds: 20)),
        isTrue,
        reason: '内核没能就绪——配置或规则集在运行时被拒了，而 check 是查不出来的：\n${runtime.log}',
      );

      // 2) 让一个真实请求穿过混合入站。目标是本机地址，按内置规则应当直连。
      final proxied = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (Uri _) => 'PROXY 127.0.0.1:${runtime.mixedPort}';
      addTearDown(() => proxied.close(force: true));

      final request = await proxied
          .getUrl(Uri.parse('http://127.0.0.1:${site.port}/probe'))
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));

      expect(response.statusCode, 200);
      expect(
        body,
        'XVPN-RUNTIME-OK',
        reason: '请求没有真的穿过内核——入站、规则引擎、直连出站三者中有一环没工作',
      );

      // 3) 内核应当把这条流量计入统计——观测链路读的就是它。
      //
      // 刻意**不**断言 `/connections` 里能看到刚才那条连接：那个列表只包含
      // **还活着**的连接，而请求已经结束、连接已经关闭。这也顺带说明了观测引擎
      // 为什么按秒轮询连接列表——两次轮询之间生灭的连接是看不到的，这是这套观测
      // 方式的固有限制，不是缺陷。
      final stats = await _get(
        client,
        runtime.apiPort,
        '/connections',
        const Duration(seconds: 5),
      );
      expect(stats, isNotNull, reason: 'Clash API 读不到统计，界面上的速率与连接数就没有来源');
      final decoded = jsonDecode(stats!) as Map<String, Object?>;
      expect(
        (decoded['downloadTotal']! as num).toInt(),
        greaterThan(0),
        reason: '内核没有统计到刚才的流量——观测链路是断的',
      );
      expect((decoded['uploadTotal']! as num).toInt(), greaterThan(0));

      // 显式收尾，不等 tearDown：见 _Runtime.shutdown 的说明。
      await runtime.shutdown();
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '观测引擎能从真实内核读到活连接',
    () async {
      // 这一条补的是另一个缺口：观测引擎此前只用假 HTTP 客户端测过——「解析逻辑
      // 对不对」测到了，「内核实际吐出来的东西它认不认」没测到。这里把真实的
      // 连接列表喂给它，断言分流记录真的产生出来（界面上的记录不是模拟数据）。
      final runtime = await boot();

      // 一个「接了但不回」的站点，用来把连接**挂住**：只有活着的连接才会出现在
      // 内核的连接列表里。
      final gate = Completer<void>();
      final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      site.listen((HttpRequest request) async {
        await gate.future;
        request.response
          ..statusCode = 200
          ..write('held');
        await request.response.close();
      });
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await site.close();
      });

      final client = newClient();
      addTearDown(() => client.close(force: true));
      expect(
        await _waitForApi(client, runtime.apiPort, const Duration(seconds: 20)),
        isTrue,
        reason: '内核没能就绪：\n${runtime.log}',
      );

      final listener = RecordingListener();
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: listener,
          clashApiPort: runtime.apiPort,
          // 关掉主动探测：这一条测的是「读内核」，不需要任何额外探测。
          // 两个探针都注入成瞬时返回，否则第一次延迟探测会真的去打隧道端点，
          // 把一个本该一秒结束的用例拖成十几秒。
          probesEnabled: false,
          latencyProbeInterval: const Duration(days: 1),
          tunnelLatencyProbe: () async => null,
          directLatencyProbe: () async => null,
        ),
      );
      addTearDown(monitor.dispose);

      // 发出请求但不等它结束：连接保持活着，内核就能看到它。
      //
      // catchError 是必需的：这条请求会被下面的收尾动作掐断，不接住的话它会变成
      // 一个未处理的异常，把真正的断言结果盖掉。
      final proxied = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (Uri _) => 'PROXY 127.0.0.1:${runtime.mixedPort}';
      addTearDown(() => proxied.close(force: true));

      final pending = () async {
        final request = await proxied.getUrl(
          Uri.parse('http://127.0.0.1:${site.port}/held'),
        );
        final response = await request.close();
        await response.drain<void>();
      }().catchError((Object _) {});

      // 第一次采样只建立速率基准，因此要跑两次，中间隔开一点时间
      // （速率是两次累计值之差除以时间差，同毫秒内连采两次算不出速率）。
      await monitor.tick();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await monitor.tick();

      final traffic = listener.lastTraffic;
      expect(traffic, isNotNull, reason: '对着真实内核采样没有产出流量数据');
      expect(
        traffic!.connectionCount,
        greaterThan(0),
        reason: '内核里明明挂着一条活连接，引擎却数出 0 条',
      );

      final record = listener.records
          .where((SplitRecord r) => r.target.contains('127.0.0.1'))
          .toList();
      expect(record, isNotEmpty, reason: '界面上「分流记录」的来源就是这里；读不到说明记录是空的或假的');
      expect(
        record.first.kind,
        RouteKind.direct,
        reason: '本机地址按内置的 ip_is_private 规则应当判为直连',
      );

      // 放行并等它结束：留一条悬空的请求在收尾时被掐断，只会污染测试输出。
      if (!gate.isCompleted) gate.complete();
      await pending.timeout(const Duration(seconds: 10));

      // 显式收尾，不等 tearDown：见 _Runtime.shutdown 的说明。
      await runtime.shutdown();
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<bool> _waitForApi(HttpClient client, int port, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await _get(client, port, '/version', const Duration(seconds: 2)) !=
        null) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

Future<String?> _get(
  HttpClient client,
  int port,
  String path,
  Duration timeout,
) async {
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port$path'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) return null;
    return await response.transform(utf8.decoder).join().timeout(timeout);
  } on Object {
    return null;
  }
}
