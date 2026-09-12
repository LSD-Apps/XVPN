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
