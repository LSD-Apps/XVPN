// 开发/验证工具：把 WireGuard .conf 生成 sing-box 配置并写盘。
//
//   dart run tool/build_singbox_config.dart <conf> [out.json] [--mode=smart|proxy|direct]
//
// 生成后可用真实内核校验语法（CI 与本地都用这条）：
//
//   assets/bin/sing-box.exe check -c <out.json>
//
// 之所以不在这里直接调用 sing-box，是为了让本工具只做纯文本转换，
// 便于在任意平台上比对输出。
import 'dart:io';

import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/build_singbox_config.dart <conf> [out.json] [--mode=smart|proxy|direct]',
    );
    exit(2);
  }

  final positional = args.where((a) => !a.startsWith('--')).toList();
  final confPath = positional.first;
  final outPath = positional.length > 1 ? positional[1] : 'build/singbox-config.json';

  var mode = SplitMode.smart;
  final modeArg = args.firstWhere((a) => a.startsWith('--mode='), orElse: () => '');
  if (modeArg.isNotEmpty) {
    mode = switch (modeArg.substring('--mode='.length)) {
      'proxy' => SplitMode.globalProxy,
      'direct' => SplitMode.globalDirect,
      _ => SplitMode.smart,
    };
  }

  final confFile = File(confPath);
  if (!confFile.existsSync()) {
    stderr.writeln('配置文件不存在: $confPath');
    exit(2);
  }

  // 规则集目录：优先用 app/assets/rulesets，其次允许用 --rulesets= 指定。
  final rulesetArg = args.firstWhere((a) => a.startsWith('--rulesets='), orElse: () => '');
  final rulesetDir = rulesetArg.isNotEmpty
      ? rulesetArg.substring('--rulesets='.length)
      : '${Directory.current.path}/assets/rulesets';

  final ParsedProfile parsed;
  try {
    parsed = VpnProtocolFactory.parse(confFile.readAsStringSync(), confPath);
  } on VpnConfigException catch (e) {
    stderr.writeln('解析配置失败: ${e.message}');
    exit(1);
  }

  final config = SingBoxConfigBuilder.build(
    profile: parsed,
    splitMode: mode,
    ruleSetDir: rulesetDir,
    logSplits: true,
  );

  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(SingBoxConfigBuilder.encode(config));

  stdout.writeln('已生成: ${out.path}');
  stdout.writeln('协议: ${parsed.protocol.label}');
  stdout.writeln('分流模式: ${mode.label}');
  stdout.writeln('出站端点: ${parsed.serverDisplay}');
  stdout.writeln('规则集目录: $rulesetDir');
  for (final name in <String>['geosite-cn.srs', 'geoip-cn.srs']) {
    final f = File('$rulesetDir${Platform.pathSeparator}$name');
    stdout.writeln('  $name: ${f.existsSync() ? "${f.lengthSync()} 字节" : "缺失！"}');
  }
}
