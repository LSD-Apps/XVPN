import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/port_allocator.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/core/wireguard_handshake.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

/// 用**随包分发的真实内核**跑通「握手日志 → 解析出结论」的完整链路。
///
/// 这条用例补的是一个此前只有单测覆盖、真实链路却断掉的缺口：
/// `platform_parity_test` 的握手用例是把合成日志行直接喂给 `handleCoreLog`，
/// 于是「内核到底会不会产生那一行」从来没被验证过。而它取决于配置里的
/// `log.level`：`SingBoxConfigBuilder` 一度写死 `warn`，握手行是 DEBUG 级的，
/// 结果两端都拿不到数据——测试却全绿。
///
/// 这里因此刻意不构造日志，而是真的起内核、让它自己写字，再把真日志喂给解析器。
/// 触发握手的办法是 `PersistentKeepalive = 1`：无需任何真实流量，内核就会主动
/// 发握手包；端点指向本机一个没有人监听的端口，于是稳定地停留在「已发出、无应答」。
const _conf = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 1
''';

void main() {
  final exe = File('assets/bin/sing-box.exe');
  final rulesets = Directory('assets/rulesets');
  final skipReason = !exe.existsSync()
      ? '未找到 ${exe.path}，跳过真实内核用例'
      : (!rulesets.existsSync() ? '未找到规则集目录，跳过真实内核用例' : null);

  test('真实内核会产生 WireGuard 握手日志，且解析器认得出来', () async {
    final profile = VpnProtocolFactory.parse(_conf, 'wg.conf');
    expect(profile.wantsDebugLogs, isTrue, reason: 'WireGuard 必须要求 DEBUG 级日志');

    final ports = await PortAllocator.allocate(from: 24080, count: 2);
    if (ports.length < 2) {
      markTestSkipped('24080 起的连续回环端口不可用，跳过');
      return;
    }

    final workDir = Directory.systemTemp.createTempSync('xvpn-hs-e2e-');
    Process? process;
    // 单一收尾：先杀进程、等它真的退出，再删目录。拆成两个 addTearDown 会按
    // LIFO 执行，而 kill() 不等进程退出，删除时文件仍被占用（Windows 上直接
    // 报 PathAccessException），把用例伪装成失败。
    addTearDown(() async {
      final p = process;
      if (p != null) {
        p.kill();
        try {
          await p.exitCode.timeout(const Duration(seconds: 3));
        } on Object {
          // 超时也不影响结论。
        }
      }
      try {
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      } on Object {
        // 临时目录残留不影响测试结论。
      }
    });

    final config = SingBoxConfigBuilder.build(
      profile: profile,
      splitMode: SplitMode.smart,
      ruleSetDir: rulesets.absolute.path,
      mixedPort: ports[0],
      clashApiPort: ports[1],
      logSplits: false,
    );
    final configFile = File(
      '${workDir.path}${Platform.pathSeparator}config.json',
    );
    configFile.writeAsStringSync(SingBoxConfigBuilder.encode(config));

    process = await Process.start(exe.absolute.path, <String>[
      'run',
      '-c',
      configFile.path,
    ], workingDirectory: workDir.path);

    final lines = <String>[];
    final gotHandshake = Completer<void>();
    void onChunk(String chunk) {
      for (final line in const LineSplitter().convert(chunk)) {
        if (line.trim().isEmpty) continue;
        lines.add(line);
        if (!gotHandshake.isCompleted &&
            parseWireGuardHandshake(line) != null) {
          gotHandshake.complete();
        }
      }
    }

    process.stdout.transform(utf8.decoder).listen(onChunk);
    process.stderr.transform(utf8.decoder).listen(onChunk);

    try {
      await gotHandshake.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      fail(
        '15 秒内没有从真实内核日志里读到可解析的握手行。\n'
        '配置里的 log.level = ${(config['log']! as Map<Object?, Object?>)['level']}\n'
        '捕获到的日志（最后 20 行）：\n${lines.skip(lines.length - 20 < 0 ? 0 : lines.length - 20).join('\n')}',
      );
    }

    // 把真实日志按到达顺序喂给解析器，验证结论而不是单个函数。
    var handshake = WireGuardHandshake.unknown;
    for (final line in lines) {
      handshake =
          parseWireGuardHandshake(line, previous: handshake) ?? handshake;
    }
    expect(handshake.isKnown, isTrue, reason: '真实日志喂进解析器后应有明确结论');
    expect(handshake.peerPublicKey, isNotNull, reason: '真实日志里应带上对端公钥短标识');
  }, skip: skipReason);
}
