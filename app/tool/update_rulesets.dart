// 开发者工具：更新规则库并校验结果。
//
//   dart run tool/update_rulesets.dart
//
// 走的是 App 内「检查更新」完全相同的代码路径（RuleSetStore.update），
// 因此这个工具的成败就代表那个按钮的成败。
import 'dart:io';

import 'package:xvpn/core/rulesets.dart';

Future<void> main() async {
  final dir = RuleSetStore.writableDir();
  stdout.writeln('规则库目录: ${dir.path}');
  stdout.writeln('更新前:');
  _report(dir);

  stdout.writeln('');
  stdout.writeln('正在从上游拉取…');
  final outcome = await RuleSetStore.update();
  stdout.writeln('结果: ${outcome.succeeded ? "成功" : "失败"} — ${outcome.message}');

  stdout.writeln('');
  stdout.writeln('更新后:');
  _report(dir);

  exit(outcome.succeeded ? 0 : 1);
}

void _report(Directory dir) {
  for (final name in RuleSetStore.sources.keys) {
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    if (!f.existsSync()) {
      stdout.writeln('  $name: 不存在');
      continue;
    }
    final bytes = f.readAsBytesSync();
    final magic = String.fromCharCodes(bytes.take(3));
    stdout.writeln(
      '  $name: ${bytes.length} 字节  魔数=$magic  '
      '时间=${f.lastModifiedSync()}',
    );
  }
}
