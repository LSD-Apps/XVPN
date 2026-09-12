import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/recording_listener.dart';

/// 用**真实的随包内核**跑一遍完整的 connect / disconnect。
///
/// 这是最后一块只靠读代码确认的地方。runner 的运行时位置原本是从
/// `Platform.resolvedExecutable` 旁边推导的，而测试进程旁边没有 sing-box.exe，
/// 于是「把内核拉起来 → 等就绪 → 接管 → 断开 → 收干净」这条主路径一直
/// 没有自动化验证：此前只有零散的片段（配置生成、观测引擎、连接列表）。
///
/// 现在运行位置可注入，这条路径可以整体跑一遍。
///
/// 两个刻意的设计：
///   * 工作目录用临时目录，**绝不碰** `%LOCALAPPDATA%\XVPN`——测试往用户真实
///     的应用状态里写东西是不可接受的；
///   * `probesEnabled: false`：不发起任何额外探测（DNS、自检、直连延迟），
///     它们既不需要也会真的连网。
const _conf = '''
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

void main() {
  final exe = File('assets/bin/sing-box.exe').absolute;
  final assets = Directory('assets/rulesets').absolute;
  final skipReason = !exe.existsSync()
      ? '未找到 ${exe.path}，跳过完整连接路径验证'
      : (!assets.existsSync() ? '未找到规则集目录，跳过完整连接路径验证' : null);

  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('xvpn-connect-path');
  });

  tearDown(() {
    // 容错清理：进程刚被杀掉时目录可能还被占着一瞬间。临时目录残留本身无害，
    // 不值得让它把测试判成失败（那样反而掩盖了真正的断言结果）。
    try {
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 交给系统清理临时目录。
    }
  });

  test(
    '完整连接路径：拉起内核、就绪、断开、收干净',
    () async {
      final recorder = RecordingListener();
      final runner = SingBoxRunner(
        recorder,
        probesEnabled: false,
        // 节点指向不可达地址，就绪门控必然走满超时。把上限压到 1 秒：这条用例
        // 验的是「连接 → 就绪 → 断开 → 收干净」，与门控等多久无关，而默认的
        // 20 秒会让每次跑测试都白等一轮。
        readyGateTimeout: const Duration(seconds: 1),
        runtimeOverride: CoreRuntime(
          singBoxExe: exe,
          ruleSetDir: assets,
          assetDir: assets,
          workDir: workDir,
        ),
      );
      addTearDown(runner.dispose);

      final parsed = VpnProtocolFactory.parse(_conf, 'connect.conf');
      await runner.connect(
        VpnProfile(id: 'p', name: 'connect.conf', parsed: parsed),
        const AppSettings(autoConnectOnImport: false),
      );

      // 1) 状态走到「已连接」。
      expect(
        recorder.statuses,
        containsAllInOrder(<VpnStatus>[
          VpnStatus.connecting,
          VpnStatus.connected,
        ]),
        reason: '完整连接路径没有走到已连接：${recorder.errors}',
      );

      // 2) 内核真的在跑，而且工作目录是**我们给的那个**（没碰用户的应用状态）。
      final pidFile = File('${workDir.path}${Platform.pathSeparator}core.pid');
      expect(pidFile.existsSync(), isTrue, reason: '内核没有留下 PID 文件，说明它没被拉起来');
      final pid = int.parse(pidFile.readAsStringSync().trim());
      final alive = Process.runSync('tasklist', <String>[
        '/FI',
        'PID eq $pid',
        '/NH',
        '/FO',
        'CSV',
      ]).stdout.toString().toLowerCase();
      expect(alive, contains('sing-box.exe'), reason: 'PID $pid 不是活着的内核');

      // 3) 配置写在了工作目录里，而且内核**真的在按它提供服务**。
      final configFile = File(
        '${workDir.path}${Platform.pathSeparator}config.json',
      );
      expect(configFile.existsSync(), isTrue);
      final config =
          jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
      final experimental = config['experimental']! as Map<String, Object?>;
      final controller =
          (experimental['clash_api']!
                  as Map<String, Object?>)['external_controller']
              as String;

      // 就绪不等于「进程活着」——要能应答才算。观测引擎读的就是这个接口，
      // 它不通的话界面上的速率、连接数、分流记录全都没有来源。
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      addTearDown(() => client.close(force: true));
      final request = await client
          .getUrl(Uri.parse('http://$controller/version'))
          .timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      await response.drain<void>();
      expect(response.statusCode, 200, reason: '内核没能应答 $controller/version');

      // 4) 断开：状态回到未连接，进程与 PID 文件都收干净。
      await runner.disconnect();
      expect(recorder.statuses.last, VpnStatus.disconnected);
      expect(pidFile.existsSync(), isFalse, reason: '断开后 PID 文件应当被删掉');

      final stillAlive = Process.runSync('tasklist', <String>[
        '/FI',
        'PID eq $pid',
        '/NH',
        '/FO',
        'CSV',
      ]).stdout.toString().toLowerCase();
      expect(
        stillAlive.contains('sing-box.exe'),
        isFalse,
        reason: '断开之后内核进程还在——它会一直占着端口，下一次连接只能被迫换端口',
      );
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('缺少内核文件时给出可读的提示，并停在未连接', () async {
    // 这条覆盖的是「安装包不完整」这种真实场景：内核没随包带上。
    final recorder = RecordingListener();
    final runner = SingBoxRunner(
      recorder,
      probesEnabled: false,
      runtimeOverride: CoreRuntime(
        singBoxExe: File(
          '${workDir.path}${Platform.pathSeparator}not-here.exe',
        ),
        ruleSetDir: assets,
        assetDir: assets,
        workDir: workDir,
      ),
    );
    addTearDown(runner.dispose);

    await runner.connect(
      VpnProfile(
        id: 'p',
        name: 'x.conf',
        parsed: VpnProtocolFactory.parse(_conf, 'x.conf'),
      ),
      const AppSettings(autoConnectOnImport: false),
    );

    // 提示必须包含「怎么解决」，而不只是把路径抛给用户：
    // sing-box.exe 被杀毒软件隔离是这件事最常见的真实原因。
    expect(recorder.errors.single, contains('缺少内核文件'));
    expect(recorder.errors.single, contains('杀毒软件'));
    expect(recorder.statuses.last, VpnStatus.disconnected);
  });

  test('缺少规则集时给出可读的提示', () async {
    final emptyAssets = Directory.systemTemp.createTempSync('xvpn-no-rulesets');
    addTearDown(() {
      if (emptyAssets.existsSync()) emptyAssets.deleteSync(recursive: true);
    });

    final recorder = RecordingListener();
    final runner = SingBoxRunner(
      recorder,
      probesEnabled: false,
      runtimeOverride: CoreRuntime(
        singBoxExe: exe,
        ruleSetDir: emptyAssets,
        assetDir: emptyAssets,
        workDir: workDir,
      ),
    );
    addTearDown(runner.dispose);

    await runner.connect(
      VpnProfile(
        id: 'p',
        name: 'x.conf',
        parsed: VpnProtocolFactory.parse(_conf, 'x.conf'),
      ),
      const AppSettings(autoConnectOnImport: false),
    );

    expect(recorder.errors.single, contains('缺少内置规则库'));
    expect(recorder.errors.single, contains('重新安装'));
    expect(recorder.statuses.last, VpnStatus.disconnected);
  }, skip: skipReason);
}
