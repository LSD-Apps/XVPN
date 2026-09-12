import 'package:flutter/foundation.dart';

/// 应用里可被跨页跳转到的**区域**。
///
/// 只表达「去哪一块」，不表达「第几页」：同一个区域在两个布局里的位置不同
/// （桌面端的「配置」是侧栏里的一页，移动端并入设置标签），由外壳负责把它
/// 翻译成当前布局下正确的索引。
enum AppSection { connect, split, profiles, settings }

/// 跨页跳转的请求通道。
///
/// 页面切换由外壳（`XvShell`）持有的索引驱动，页面自己够不到它。项目里已有的
/// 跨页动作（标题栏「发现新版本」）是外壳把回调逐层透传下去的，但连接页的
/// 「切换配置」弹窗要触发的跳转隔着一整页 widget，为它逐层加参数会污染一串
/// 构造函数。这里改用与 `WindowControls.maximized` / `UpdateCenter.notice`
/// 同一种做法：进程级 [ValueNotifier] 承载**意图**，外壳监听它、翻译成本布局
/// 下的索引，处理完调用 [consume] 清空。
///
/// 为什么用全局单例而不是构造注入：弹窗这一层拿不到外壳，为一个跳转把控制器
/// 穿过整棵子树传递，收益不抵复杂度；而共享请求/结果用全局 notifier 在本项目
/// 已有先例（`UpdateCenter`、`WindowControls`）。
class ScreenNavigation extends ValueNotifier<AppSection?> {
  ScreenNavigation() : super(null);

  /// 进程级单例。页面与外壳默认都读它。
  static final ScreenNavigation instance = ScreenNavigation();

  /// 请求切到 [section]。
  void request(AppSection section) => value = section;

  /// 外壳处理完一次请求后清空，避免下一次重建重复跳转。
  void consume() => value = null;
}
