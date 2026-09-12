import 'dart:io';

import 'package:flutter/foundation.dart';

/// 桌面端可写目录的解析结果。
///
/// 单列一个类型而不是散着返回两条 `Directory`：数据目录（配置、规则库、系统
/// 代理备份）与运行目录（内核的 `config.json` 与 `core.pid`）必须成对使用，
/// 而它们此前各自在 `store.dart`、`rulesets.dart`、`singbox_runner.dart` 里
/// 用 `LOCALAPPDATA` 拼一遍——三处一旦分叉，用户会看到「配置在一个目录、
/// 规则库在另一个目录」，排查时几乎不可能想到。
class DesktopPaths {
  const DesktopPaths({required this.dataDir, required this.runtimeDir});

  /// 应用数据目录。
  final Directory dataDir;

  /// 内核运行目录。
  final Directory runtimeDir;
}

/// 解析桌面端的可写目录。
///
/// **参数全部显式传入**：这是一条只有 Ubuntu 桌面上才会走到的分支，而开发机是
/// Windows，本机没有 `/proc`、没有 `$XDG_*`。把平台与环境抽成参数之后，Linux
/// 的取值就能在 Windows 上被单元测试锁定（见 `test/linux_platform_test.dart`）。
/// 换成一个直接读 [Platform.environment] 的实现，这条路径就只能靠肉眼复核。
DesktopPaths resolveDesktopPaths({
  required TargetPlatform platform,
  required Map<String, String> environment,
  String? systemTempPath,
}) {
  final String temp = systemTempPath ?? Directory.systemTemp.path;
  // 分隔符按**目标平台**而不是宿主平台决定：这条函数要在 Windows 上被测出
  // Linux 的取值，反过来也要成立。Windows 也接受正斜杠，反过来不成立。
  final String sep = platform == TargetPlatform.windows ? r'\' : '/';

  String join(List<String> parts) => parts.join(sep);

  if (platform == TargetPlatform.linux) {
    // 遵循 XDG 基本目录规范：用户可写的数据放 $XDG_DATA_HOME（缺省
    // ~/.local/share），而不是像 Windows 那样用 LOCALAPPDATA。
    final String? home = _nonEmpty(environment['HOME']);
    final String? dataHome =
        _nonEmpty(environment['XDG_DATA_HOME']) ??
        (home == null ? null : join(<String>[home, '.local', 'share']));
    final Directory dataDir = Directory(
      join(<String>[dataHome ?? temp, 'XVPN']),
    );
    // 运行期文件优先放 $XDG_RUNTIME_DIR：它是 tmpfs、每次登录自动清空，
    // 因此「上次被强杀留下的 core.pid」不会跨会话存活。该目录由系统按
    // 0700 创建，正好适合放 PID 与生成的配置。
    // 没有它时（例如 SSH 会话或非 systemd 环境）退回到数据目录，
    // 而不是落到 /tmp —— 后者是全局共享的，多用户下会互相干扰。
    final String? runtimeHome = _nonEmpty(environment['XDG_RUNTIME_DIR']);
    final Directory runtimeDir = Directory(
      runtimeHome == null
          ? join(<String>[dataDir.path, 'runtime'])
          : join(<String>[runtimeHome, 'XVPN']),
    );
    return DesktopPaths(dataDir: dataDir, runtimeDir: runtimeDir);
  }

  // Windows（以及尚未单列的其它桌面平台）：沿用原有语义，不做任何改变。
  final String base =
      _nonEmpty(environment['LOCALAPPDATA']) ??
      _nonEmpty(environment['APPDATA']) ??
      temp;
  final Directory dataDir = Directory(join(<String>[base, 'XVPN']));
  return DesktopPaths(
    dataDir: dataDir,
    runtimeDir: Directory(join(<String>[dataDir.path, 'runtime'])),
  );
}

/// 当前宿主平台上随包分发的内核文件名。
///
/// Windows 的内核是 `sing-box.exe`，其它平台是 `sing-box`。抽成一处是为了让
/// 运行时解析与测试里的路径拼接用同一个名字——此前测试六个文件各自写死
/// `assets/bin/sing-box.exe`，Linux 上会集体静默跳过（`existsSync()` 为假），
/// 也就是这些用例在 Linux CI 上**全部不跑**却显示为「通过」。
String get hostSingBoxBinaryName =>
    Platform.isWindows ? 'sing-box.exe' : 'sing-box';

/// 按目标平台给出内核文件名。纯函数，便于测试 Linux 上的取值。
String singBoxBinaryName(TargetPlatform platform) =>
    platform == TargetPlatform.windows ? 'sing-box.exe' : 'sing-box';

String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;
