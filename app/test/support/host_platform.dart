import 'dart:io';

import 'package:xvpn/core/platform_paths.dart';

/// 随包分发的内核文件（相对 `app/` 目录）。
///
/// 所有需要真实内核的测试共用这一个入口。此前六个测试文件各自写死
/// `assets/bin/sing-box.exe`，在 Linux 上 `existsSync()` 为假、整批用例被
/// `skip` 掉——测试报告显示「通过」，而实际一行都没跑。
File get hostCoreBinary => File('assets/bin/$hostSingBoxBinaryName').absolute;

/// 内核进程是否还活着。
///
/// Windows 用 `tasklist` 查进程名，Linux 读 `/proc/<pid>`。测试里查的 PID
/// 就是刚拉起的内核，不存在 PID 复用问题，因此 Linux 侧只看目录是否存在。
bool isCoreProcessAlive(int pid) {
  if (Platform.isWindows) {
    final out = Process.runSync('tasklist', <String>[
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]).stdout.toString().toLowerCase();
    return out.contains('sing-box.exe');
  }
  return Directory('/proc/$pid').existsSync();
}
