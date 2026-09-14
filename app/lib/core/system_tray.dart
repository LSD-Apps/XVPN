import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../format.dart';
import '../models.dart';
import '../version.dart';
import 'update_center.dart';

/// 把托盘要显示的事推给原生：版本号、连接状态、速率、有没有新版本。
///
/// 托盘在**原生侧**：Windows 见 windows/runner/flutter_window.cpp，Linux 见
/// linux/runner/my_application.cc（libayatana-appindicator3，运行时 dlopen）。
/// 两端走的是与窗口控制同一个平台通道 `com.xvpn.xvpn/platform`，载荷也完全
/// 相同。这里只负责「推送」，不做任何检查——[UpdateCenter] 已经在启动时查过
/// 一次，托盘只是把那件事**显示**出来；它自己绝不联网，否则同一件事会出现两份
/// 可能互相矛盾的结果，也违背「一个进程只查一次」这条纪律。
///
/// 关窗收进托盘时的气泡 / 桌面通知也在原生侧发出（Windows `NIF_INFO`，Linux
/// `GNotification`），正文会参考这里推过去的 `connected`，因此本类推送的时效
/// 仍然重要——否则用户刚连上立刻关窗，气泡可能还写着「未连接」。
///
/// 安卓用前台服务通知而不是托盘，因此 [supported] 为 false。
///
/// 推送是**去重**的：界面每秒都会重建，不去重会让平台通道被同一份状态反复
/// 淹没。比较的是整份载荷，因此「状态没变」不会有任何通道调用，「更新提示从
/// 无到有」或「已连接时速率刻度变化」则会被推一次。已连接时约每秒一次是预期
/// （与 Clash 采样同频）；未连接时流量刷新不会进载荷，因此不会刷通道。
class SystemTray {
  SystemTray({
    required this.state,
    UpdateCenter? updateCenter,
    MethodChannel? channel,
  }) : _updateCenter = updateCenter ?? UpdateCenter.instance,
       _channel = channel ?? const MethodChannel('com.xvpn.xvpn/platform');

  final AppState state;
  final UpdateCenter _updateCenter;
  final MethodChannel _channel;

  /// 是否支持托盘。Windows 与 Linux 的 runner 都装了托盘。
  static bool get supported =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// 上一次成功发给原生（或至少发出过）的载荷。null 表示还没推过。
  Map<String, Object?>? _lastSent;

  bool _attached = false;

  /// 订阅连接状态与更新提示，并立刻同步一次。
  ///
  /// 由外壳在 `initState` 调用。外壳本来就会监听 [state]，但更新提示是另一条
  /// 通知源，因此这里两个都订阅——否则「启动检查查到新版本」这件事永远到不了
  /// 托盘。
  void attach() {
    if (_attached) return;
    _attached = true;
    state.addListener(_onChanged);
    _updateCenter.notice.addListener(_onChanged);
    _onChanged();
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;
    state.removeListener(_onChanged);
    _updateCenter.notice.removeListener(_onChanged);
  }

  void _onChanged() => unawaited(sync());

  /// 当前要推送的载荷。
  ///
  /// 抽成独立方法是为了让「托盘到底收到什么」能被直接断言，而不必对着通道参数
  /// 逐个 key 去猜。
  ///
  /// 状态文案取自 [VpnStatusX.label]——托盘**不另造一套说法**：界面上写
  /// 「未连接」，托盘就是「未连接」。图标灰不灰则由独立的 [connected] 布尔量
  /// 决定，而不是让原生去比对中文文案——那样文案一改，图标就会悄悄跟丢。
  ///
  /// 速率只在已连接时附上，且在 Dart 侧先格式化成短串：原生只负责拼 tooltip，
  /// 不要紧挨 Windows 128 宽字符上限。
  @visibleForTesting
  Map<String, Object?> payload() {
    final notice = _updateCenter.notice.value;
    final connected = state.isConnected;
    return <String, Object?>{
      'version': appVersion,
      'status': state.status.label,
      'connected': connected,
      if (connected) 'downRate': fmtRateLabel(state.downBps),
      if (connected) 'upRate': fmtRateLabel(state.upBps),
      // 已忽略的提示不再是「有更新」：载荷里连这个 key 都不出现。
      if (notice != null && !notice.dismissed) 'updateVersion': notice.version,
    };
  }

  /// 把当前状态推给原生托盘。与上次相同则什么都不做。
  Future<void> sync() async {
    if (!supported) return;
    final next = payload();
    if (mapEquals(next, _lastSent)) return;
    // 先记再发：发是异步的，期间可能又有几次 sync 进来。不先记的话它们都会
    // 读到旧值并各发一次，去重就失效了。
    _lastSent = next;
    try {
      await _channel.invokeMethod<void>('setTrayState', next);
    } on Object {
      // 通道不可用（原生未注册、测试环境没有替身）时静默：托盘状态是显示，
      // 推不过去不该影响连接主流程，也不该把一个异步异常甩到界面上。
    }
  }
}
