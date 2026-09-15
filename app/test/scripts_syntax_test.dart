import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `scripts/` 下的每个 `.ps1` 都要满足两条，缺一条就会在别人机器上以
/// 「看不懂的语法错误」或「部署到一半才炸」的形式暴露出来。
///
/// 1. **必须带 UTF-8 BOM。** 本机（以及多数 Windows 用户机器）只有
///    Windows PowerShell 5.1，它按 **ANSI** 解码没有 BOM 的脚本——文件里的中文
///    注释会变成乱码，还常常因此报出「Try 语句缺少 Catch / Finally」这种与真实
///    原因毫无关系的语法错误。麻烦在于 `write` / `edit` 工具**不保留 BOM**：
///    实测每改一次就掉一次，改完必须手工补回。指望人记得，不如让一条断言兜住。
///
/// 2. **必须能被真正的解释器解析。** 字符串断言只能证明「该有的片段在」，
///    证明不了整份脚本能被解析。一个语法错误的部署脚本，会在真机部署进行到
///    一半时才暴露——那时手机上已经出现了拦截页，而脚本自己正卡在那儿。
void main() {
  final scriptsDir = Directory('../scripts');

  List<File> powerShellScripts() {
    expect(
      scriptsDir.existsSync(),
      isTrue,
      reason: '找不到 scripts/ 目录（测试的工作目录是 app/）',
    );
    final files =
        scriptsDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.ps1'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'scripts/ 下一个 .ps1 都没有');
    return files;
  }

  test('每个 .ps1 都带 UTF-8 BOM', () {
    for (final file in powerShellScripts()) {
      final bytes = file.readAsBytesSync();
      final hasBom =
          bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF;
      expect(
        hasBom,
        isTrue,
        reason:
            '${file.path} 缺少 UTF-8 BOM：PowerShell 5.1 会按 ANSI 解码，'
            '中文注释变成乱码并导致语法错误',
      );
    }
  });

  test('每个 .ps1 都能被真正的 PowerShell 解析', () async {
    if (!Platform.isWindows) return; // Linux runner 上没有 PowerShell。

    for (final file in powerShellScripts()) {
      final result = await Process.run(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          // 只用解析器，不执行任何东西。
          r'$errors = $null;'
          r'[System.Management.Automation.Language.Parser]::ParseFile('
          r'$env:XVPN_PARSE_PATH, [ref]$null, [ref]$errors) | Out-Null;'
          r'if ($errors.Count -gt 0) {'
          r'$errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" };'
          r'exit 1 }',
        ],
        // 路径经环境变量传进去，而不是拼进命令串：路径里的引号会把检查自己写坏。
        environment: <String, String>{'XVPN_PARSE_PATH': file.absolute.path},
      );
      expect(
        result.exitCode,
        0,
        reason: '${file.path} 解析失败：\n${result.stdout}${result.stderr}',
      );
    }
  });
}
