import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'update_center.dart';
import 'updater.dart';

/// 用户主动发起的更新流程（检查 → 下载 → 校验 → 安装）的**进程级**状态机。
///
/// 为什么不能把它留在 `UpdateCard` 的 State 里——这是真机上很容易撞到的现象：
/// **下载更新时切到别的页面，下载就断了**。设置页在桌面与移动各放一张卡片，
/// 而切换页面会把设置页连同卡片一起销毁；销毁时原先会调 `Updater.dispose()`
/// 关掉 HTTP 客户端，正在传的字节流随之被切断。即便网络层侥幸没断，进度、
/// 已下载的文件与结果也全都随 State 一起没了——用户切回来看到的是一个
/// 「还没开始」的卡片，于是只能重下。
///
/// 这不该由用户的操作顺序决定：下载是应用的事，不是某个页面的临时状态。
/// 因此把状态提到进程级，卡片只是它的一个视图，来去都不影响下载。
/// 取消只有一条路径——用户显式点「取消」。
///
/// 与 [UpdateCenter] 的分工：那个负责**启动时那一次静默检查**并把「有新版本」
/// 共享给标题栏与卡片；本类负责**用户点下去之后**的完整流程。
class UpdateSession extends ChangeNotifier {
  UpdateSession({
    required this.updater,
    required this.center,
    void Function(int code)? exitProcess,
  }) : _exitProcess = exitProcess ?? exit;

  /// 进程级单例。真实运行时卡片用的就是它，也是「切页不中断」的前提。
  static UpdateSession? _instance;

  static UpdateSession get instance => _instance ??= UpdateSession(
    updater: Updater.forCurrentPlatform(),
    center: UpdateCenter.instance,
  );

  /// 仅供测试：替换全局单例。
  @visibleForTesting
  static set instance(UpdateSession? value) => _instance = value;

  final Updater updater;

  /// 启动检查的共享持有者。卡片要用它显示「有新版本」并支持「忽略」。
  final UpdateCenter center;

  /// 桌面端安装助手在等当前进程退出，成功启动安装后由这里退出应用。
  final void Function(int code) _exitProcess;

  bool _checking = false;
  bool _downloading = false;
  bool _installing = false;

  UpdateCheckResult? _checkResult;
  UpdateDownloadResult? _downloadResult;
  UpdateInstallResult? _installResult;

  /// 当前可下载/已下载的发布信息。下载开始后一直留着，以便「重试下载」等
  /// 入口无需再传参数。
  UpdateInfo? _info;

  File? _downloadedFile;
  UpdateCancellation? _cancellation;

  int _received = 0;
  int? _total;

  bool _disposed = false;

  bool get checking => _checking;
  bool get downloading => _downloading;
  bool get installing => _installing;

  /// 是否有异步操作正在进行。界面据此禁用按钮，保证重复点击安全。
  bool get busy => _checking || _downloading || _installing;

  UpdateCheckResult? get checkResult => _checkResult;
  UpdateDownloadResult? get downloadResult => _downloadResult;
  UpdateInstallResult? get installResult => _installResult;

  UpdateInfo? get info => _info;
  File? get downloadedFile => _downloadedFile;

  int get received => _received;
  int? get total => _total;

  /// 桌面端：安装助手启动后必须由应用主动退出。安卓不在其列。
  bool get isDesktop =>
      updater.platform == TargetPlatform.windows ||
      updater.platform == TargetPlatform.linux;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  // ------------------------------------------------------------ 动作

  Future<void> check() async {
    if (busy) return;
    _checking = true;
    _checkResult = null;
    _downloadResult = null;
    _installResult = null;
    _info = null;
    _downloadedFile = null;
    _cancellation = null;
    _received = 0;
    _total = null;
    _notify();

    final result = await updater.checkForUpdate();
    if (_disposed) return;
    _checking = false;
    _checkResult = result;
    if (result is UpdateAvailable) _info = result.info;
    _notify();
  }

  /// [target] 用于启动检查已经发现更新、卡片尚未走过 [check] 的场景：
  /// 此时 [info] 仍是 null，由入口把 notice 里的信息显式带进来。
  Future<void> download([UpdateInfo? target]) async {
    final info = target ?? _info;
    if (info == null || busy) return;
    final cancellation = UpdateCancellation();
    _downloading = true;
    _downloadResult = null;
    _installResult = null;
    _downloadedFile = null;
    _cancellation = cancellation;
    _received = 0;
    _total = info.assetSize;
    _info = info;
    _notify();

    final result = await updater.download(
      info,
      cancellation: cancellation,
      onProgress: (int received, int? total) {
        if (_disposed) return;
        _received = received;
        // 服务器不给长度时保留引擎从附件信息里拿到的预估大小，
        // 两者都没有则进度条退化为不确定态。
        _total = total ?? info.assetSize;
        _notify();
      },
    );
    if (_disposed) return;
    _downloading = false;
    _cancellation = null;
    _downloadResult = result;
    if (result is UpdateDownloaded) _downloadedFile = result.file;
    _notify();
  }

  void cancelDownload() => _cancellation?.cancel();

  /// 用户忽略启动检查发现的更新：本次运行内标题栏与卡片都不再提示。
  void dismissNotice() {
    if (busy) return;
    center.dismiss();
  }

  /// 用户在确认步骤里选择「稍后」：退回「有更新」状态，不安装。
  void dismissDownload() {
    if (busy) return;
    _downloadResult = null;
    _downloadedFile = null;
    _received = 0;
    _total = null;
    _notify();
  }

  /// 用户已经在确认步骤里点了「安装更新」——这是唯一的安装入口。
  ///
  /// [elevate] 为 true 表示用户已在上一步同意用管理员权限完成写入（Windows）。
  Future<void> install({bool elevate = false}) async {
    final info = _info;
    final file = _downloadedFile;
    if (info == null || file == null || busy) return;
    _installing = true;
    _installResult = null;
    _notify();

    final result = await updater.install(info, file, elevate: elevate);
    if (_disposed) return;
    _installing = false;
    _installResult = result;
    _notify();

    // 桌面端的重启助手在等当前进程退出。消息先渲染一帧再退出，
    // 让用户看到「正在更新」而不是应用凭空消失；安卓交给系统安装器，绝不退出。
    if (result is UpdateInstallStarted && isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _exitProcess(0));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
