import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// 项目开源仓库地址。
///
/// 单独抽成常量、而不是直接写进标题栏按钮里：地址将来若迁移，只需要改这一处，
/// 不至于散落在界面代码中。地址与仓库根目录的 CITATION.cff / index.html 一致。
const String kRepoUrl = 'https://github.com/LSD-Apps/XVPN';

/// 打开外部链接的函数签名。
///
/// 之所以把它做成一个可注入的类型：widget 测试环境里没有浏览器，
/// `url_launcher` 的真实实现必然失败，因此无法用它来断言「点了哪个地址」。
/// 标题栏按钮接受这个类型的参数，测试注入记录器，线上注入 [launchInBrowser]。
typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

/// 默认实现：交给系统默认浏览器打开。
///
/// 用 `externalApplication` 而不是应用内 webview——这是「查看源码」，
/// 用户需要的是完整的 GitHub 页面（登录、star、issue），而不是一个精简壳。
Future<bool> launchInBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// 在系统文件管理器里定位一个文件的函数签名。
///
/// 与 [ExternalUrlLauncher] 同样的理由做成可注入类型：测试环境里没有文件
/// 管理器，真实实现必然失败，无法据此断言「定位到了哪个文件」。
typedef FileRevealer = Future<bool> Function(File file);

/// 默认实现：在系统文件管理器里**选中**这个文件。
///
/// Windows 用 `explorer /select,<path>` 直接选中它——用户此时要做的是双击安装，
/// 或把它拷到别的机器上；只打开父目录会让他自己再找一遍。Linux 没有跨桌面环境
/// 的「选中」协议（文件管理器各家的 D-Bus 接口互不相同），退而打开所在目录。
///
/// 返回 false 表示没能打开（文件不存在、系统里没有 xdg-open、精简桌面等），
/// 由调用方给出「路径可复制」这条退路——而不是静默什么都不发生。
Future<bool> revealInFileManager(File file) async {
  try {
    if (!file.existsSync()) return false;
    if (Platform.isWindows) {
      // `/select,` 必须**紧贴**路径：写成 `/select, <path>` 会被 explorer 当成
      // 两个参数，结果是打开「我的文档」而不是定位这个文件。
      await Process.start(
        'explorer.exe',
        <String>['/select,${file.path}'],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isLinux) {
      final Directory parent = file.parent;
      if (!parent.existsSync()) return false;
      await Process.start(
        'xdg-open',
        <String>[parent.path],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
  } on Object {
    // 打开失败不是异常情况：容器、精简桌面、缺少 xdg-open 都会走到这里。
    return false;
  }
  return false;
}
