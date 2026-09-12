import 'dart:async';

import 'package:flutter/foundation.dart';

import 'updater.dart';

/// 一次启动检查的结果。
///
/// 只承载界面需要的东西：[info] 供「下载更新 / 查看发布页」使用，[version] 是
/// 标题栏与设置卡片要显示的版本号，[dismissed] 记录用户是否已在本次运行里忽略过。
///
/// 做成不可变类型，是为了让「忽略」这条唯一的状态变更走 [copyWith] 显式产生新值，
/// 而不是让任意持有者就地改字段——否则标题栏与设置卡片可能读到不一致的状态。
@immutable
class UpdateNotice {
  const UpdateNotice({required this.info, this.dismissed = false});

  final UpdateInfo info;

  /// 用户已在本次运行里忽略这条提示。
  final bool dismissed;

  String get version => info.version;

  UpdateNotice copyWith({bool? dismissed}) =>
      UpdateNotice(info: info, dismissed: dismissed ?? this.dismissed);
}

/// 检查函数的形状。抽出来是为了让测试不必联网也能驱动
/// [UpdateCenter.checkOnStartup] 的每条分支（成功 / 无更新 / 失败 / 抛异常）。
typedef UpdateCheckRunner = Future<UpdateCheckResult> Function();

/// 应用级更新提示的持有者：**每次进程只查一次**。
///
/// 与 [UpdateCard] 的分工很明确：卡片负责「用户点了检查之后」的完整流程（下载、
/// 校验、确认安装），本类只负责启动时那一次静默检查，并把「有新版本」这件事
/// 共享给设置页卡片与桌面标题栏——两处读到的是同一份结果，不会各自联网，也不会
/// 出现两处提示互相矛盾。
///
/// 三条纪律：
///   * 启动检查**失败必须与「没有更新」完全一致**——用户不该在启动时看到与
///     自己操作无关的错误；
///   * **只成功一次**：重复调用返回同一个 Future，绝不发第二次请求；
///   * 手动「检查更新」不走这里：那条路径的错误必须照旧展示给用户，不能被
///     这里的静默策略吞掉。
class UpdateCenter {
  /// 构造入口。可注入检查函数（测试）或 [Updater] 工厂。
  factory UpdateCenter({
    Updater Function()? createUpdater,
    UpdateCheckRunner? check,
    Duration timeout = const Duration(seconds: 10),
  }) => UpdateCenter._(createUpdater, check, timeout);

  UpdateCenter._(this._createUpdater, this._injectedCheck, this.timeout);

  /// 进程级单例。桌面标题栏与设置页卡片默认都读它。
  static UpdateCenter? _instance;

  static UpdateCenter get instance => _instance ??= UpdateCenter();

  /// 仅供测试：替换全局单例，让直接构造的组件也能读到预置结果。
  @visibleForTesting
  static set instance(UpdateCenter? value) => _instance = value;

  /// 单次启动检查的等待上限。
  ///
  /// 更新器自身的请求超时是 30 秒；启动检查只是「顺便看一眼」，让用户为它等
  /// 那么久没有意义，因此这里单独收窄。超时按失败处理（静默）。
  final Duration timeout;

  final Updater Function()? _createUpdater;
  final UpdateCheckRunner? _injectedCheck;

  Updater? _updater;

  /// 是否为**本类自己创建**的 [Updater]。只有它归本类释放。
  bool _ownsUpdater = false;

  final ValueNotifier<UpdateNotice?> _notice =
      ValueNotifier<UpdateNotice?>(null);

  /// 当前可提示的新版本；没有（或已忽略）时为 null。界面用它订阅刷新。
  ValueListenable<UpdateNotice?> get notice => _notice;

  Future<void>? _startupCheck;

  /// 发起启动检查。**最多执行一次**，重复调用返回同一个 Future。
  ///
  /// 永不抛异常、也永不因失败写入 [notice]：任何异常都按「没有更新」处理。
  Future<void> checkOnStartup() => _startupCheck ??= _run();

  Future<void> _run() async {
    try {
      final result = await _runCheck().timeout(timeout);
      // 只有真的有新版本才记录。失败、已是最新都不在界面上留下任何痕迹。
      if (result is UpdateAvailable) {
        _notice.value = UpdateNotice(info: result.info);
      }
    } on Object {
      // 静默：启动检查失败与「已经是最新版」在用户那里必须不可区分。
      // 这里刻意不写日志、不重试——它就是一次顺带的检查。
    }
  }

  Future<UpdateCheckResult> _runCheck() {
    final injected = _injectedCheck;
    if (injected != null) return injected();
    final updater = _updater ??= _createUpdaterOrPlatform();
    return updater.checkForUpdate();
  }

  Updater _createUpdaterOrPlatform() {
    final factory = _createUpdater;
    if (factory != null) return factory();
    // 只有默认工厂造出来的引擎才握有本类需要自行关闭的 HTTP 客户端；
    // 注入的实现由调用方负责（与 UpdateCard 的注入约定一致）。
    _ownsUpdater = true;
    return Updater.forCurrentPlatform();
  }

  /// 用户忽略提示。本次运行内不再出现；下次启动会重新检查。
  ///
  /// 刻意不做持久化：这个决策的成本很低（下次启动再看一眼），而落盘要引入
  /// 设置存储与迁移，收益不抵复杂度。
  void dismiss() {
    final current = _notice.value;
    if (current == null || current.dismissed) return;
    _notice.value = current.copyWith(dismissed: true);
  }

  /// 释放自己创建的 HTTP 客户端与通知器。
  void dispose() {
    if (_ownsUpdater) _updater?.dispose();
    _notice.dispose();
  }
}
