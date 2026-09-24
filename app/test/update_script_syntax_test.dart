import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/updater.dart';

/// 更新器**在运行时生成**的 Windows 助手脚本必须能被真正的 PowerShell 解析。
///
/// 这是一个只在用户点「安装更新」那一刻才会跑起来的脚本：它由
/// [buildWindowsRelaunchScript] 拼出来，写进暂存目录，然后交给
/// `powershell.exe -File`。拼错一个引号或漏掉一个 `}` 的代价是：
///
///   * 应用已经退出，而升级**没有发生**——用户看到的是「点了更新，然后什么都没
///     发生」，或者更糟：旧版本也没被重新拉起来；
///   * 脚本里的路径来自用户机器（`C:\Users\Bob's PC\...`），含单引号是常态，
///     而单引号正是 PowerShell 字符串的转义字符——[buildWindowsRelaunchScript]
///     为此有专门的引号处理，这里就用那类路径去撞它。
///
/// 与 `test/scripts_syntax_test.dart` 同一套做法：字符串断言只能证明「该有的片段
/// 在」，证明不了整份脚本能被解析。Linux 的 sh 脚本这里不检查——开发机是
/// Windows，没有 `sh -n` 可跑；它由 `updater_test.dart` 的内容断言守着。
void main() {
  test('生成的 Windows 助手脚本能被 PowerShell 解析器接受', () async {
    if (!Platform.isWindows) return; // 其它平台没有 powershell.exe。

    // 路径刻意带上单引号与空格：这是转义最容易出错、而真实用户目录里很常见的形态
    // （`C:\Users\Bob's PC\...`）。
    final String source = buildWindowsRelaunchScript(
      pid: 4242,
      archivePath: r"C:\Users\Bob's PC\AppData\Local\Temp\xvpn-update"
          r'\downloads\XVPN-1.4.0-windows-x64.zip',
      stagingDir: r"C:\Users\Bob's PC\AppData\Local\Temp\xvpn-update",
      installDir: r"C:\Program Files\XVPN\Bob's app",
      launchPath: r"C:\Program Files\XVPN\Bob's app\xvpn.exe",
    );

    final File script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'xvpn-update-script-syntax-test.ps1',
    );
    // 与运行时一致：带 UTF-8 BOM。少了它 PowerShell 5.1 会按 ANSI 解码脚本里的
    // 中文，报出的却是与真实原因毫无关系的语法错误。
    script.writeAsStringSync('\uFEFF$source', flush: true);

    final ProcessResult result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      // 只用解析器，不执行任何东西——这段脚本会等待 PID 退出并真的替换安装目录。
      r'$errors = $null;'
          r'[System.Management.Automation.Language.Parser]::ParseFile('
          r'$env:XVPN_PARSE_PATH, [ref]$null, [ref]$errors) | Out-Null;'
          r'if ($errors.Count -gt 0) {'
          r'$errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" };'
          r'exit 1 }',
    ], environment: <String, String>{'XVPN_PARSE_PATH': script.absolute.path});

    expect(
      result.exitCode,
      0,
      reason: '生成的更新助手脚本语法不合法：\n${result.stdout}${result.stderr}',
    );

    // 顺带钉住三条只能在真机暴露的语义：先等退出，再解压、确认可执行文件、覆盖
    // 安装目录；顺序反了会以「文件被占用」或「覆盖到一半」收场。
    final int waitAt = source.indexOf('Wait-Process -Id 4242');
    final int extractAt = source.indexOf('Expand-Archive');
    final int checkAt = source.indexOf("Join-Path", extractAt);
    final int copyAt = source.indexOf('Copy-Item');
    expect(waitAt, greaterThanOrEqualTo(0));
    expect(extractAt, greaterThan(waitAt));
    expect(checkAt, greaterThan(extractAt));
    expect(copyAt, greaterThan(checkAt));
  });
}
