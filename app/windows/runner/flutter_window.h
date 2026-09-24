#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 托盘图标相关。
  //
  // 关闭主窗口时不退出程序，而是收进托盘；只有托盘菜单里的「退出」
  // 才真正结束进程。这样做的前提是退出路径必须完成清理——否则用户会
  // 留下一个指向已退出内核的系统代理，表现为「所有网站都打不开」。
  void InstallTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void ShowMainWindow();

  /// 关闭窗口收进托盘时弹出一次气泡，让用户知道进程（与隧道）仍在后台。
  ///
  /// 只在「可见 → 隐藏」时调用；已经在托盘里再触发 WM_CLOSE 不重复弹，
  /// 避免连点关闭或脚本反复 PostMessage 刷屏。
  void NotifyRunningInBackground();

  /// 应用 Dart 推来的托盘状态（版本 / 状态文案 / 是否已连接 / 更新版本）。
  void ApplyTrayState(const flutter::EncodableMap& state);

  /// 「开机自动启动」这一项由**原生**写进系统（注册表 Run 键），状态也由原生
  /// 回读后推给 Dart——Dart 那边只存一份供界面显示的镜像。见 auto_start.h。
  ///
  /// 托盘菜单的勾选状态来自 Dart 推送的托盘载荷（见 [ApplyTrayState]）：
  /// 原生不自己去查，否则托盘与设置页会各有一份可能过期的结果。

  /// 把当前的开机自启状态推给 Dart（方法 `autoStartChanged`）。
  ///
  /// 托盘菜单里勾选后调用：切换动作已经由原生落地，Dart 需要据此更新设置页
  /// 的开关，否则同一个事实会在一端显示为开、另一端显示为关。
  void NotifyAutoStartChanged();

  /// 按当前状态刷新图标的 tooltip 与图标本身，并通知通知区（NIM_MODIFY）。
  void UpdateTrayIcon();

  /// 当前 DPI 下托盘小图标的边长（16 @100%，24 @150%……）。
  int TrayIconSize();

  /// 彩色 / 灰度图标的句柄，按需创建并缓存。
  ///
  /// 缓存是因为托盘状态每次变化（连接、断线、发现更新）都要 NIM_MODIFY，
  /// 每次重新解码 + 去饱和是纯浪费。
  HICON NormalTrayIcon();
  HICON GreyTrayIcon();

  /// 释放上面两个句柄。灰度图标一定归我们所有，彩色图标不一定（资源加载
  /// 失败时会退回共享的系统默认图标）。
  void DestroyTrayIcons();

  /// 托盘图标的回调消息号。
  static constexpr UINT kTrayCallbackMessage = WM_APP + 1;
  static constexpr int kTrayMenuShow = 40001;
  static constexpr int kTrayMenuQuit = 40002;
  /// 「发现新版本」——**可点**，点它显示主界面并让 Dart 切到设置页的
  /// 「版本更新」卡片。此前它被做成灰色纯信息项，理由是「没有一条现成的
  /// native → Dart 通道」，但那条通道本就在用（同文件的 maximizedChanged、
  /// Linux 的 quitRequested），于是托盘告诉用户有新版本却无处可去。
  static constexpr int kTrayMenuUpdate = 40003;
  /// 「开机自动启动」——复选菜单项。用户能在托盘上直接开关，不必先进设置页。
  static constexpr int kTrayMenuAutoStart = 40004;

  NOTIFYICONDATAW tray_icon_ = {};
  bool tray_installed_ = false;

  /// Dart 推来的展示用状态。空串表示还没收到过对应字段。
  std::wstring tray_version_;
  std::wstring tray_status_;
  std::wstring tray_update_;
  std::wstring tray_down_rate_;
  std::wstring tray_up_rate_;
  bool tray_connected_ = false;

  /// 最近一次推送的开机自启状态。
  ///
  /// 「随系统启动」两端共用一个事实：托盘菜单的勾在原生侧画，设置页的开关在
  /// Dart 侧画。原生这边的来源是 Dart 推来的托盘载荷（见 [ApplyTrayState]），
  /// **不自己去查**——否则托盘与设置页会各有一份可能过期的结果。
  ///
  /// 用户在托盘上切换时由本类就地更新，落地（回读）后再推给 Dart。
  bool tray_auto_start_ = false;

  /// 开机自启后端是否可用。不可用时菜单项灰掉——勾一个不会有任何效果的开关，
  /// 比没有这个开关更糟。
  bool tray_auto_start_supported_ = false;

  HICON tray_icon_normal_ = nullptr;
  HICON tray_icon_grey_ = nullptr;

  /// [tray_icon_normal_] 是否归本类所有（需要 DestroyIcon）。
  bool tray_normal_owned_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 承接 Dart 侧自绘标题栏发来的窗口控制请求
  // （最小化 / 最大化 / 关闭 / 查询最大化状态）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // 上一次已通知给 Dart 的最大化状态。
  //
  // WM_SIZE 在拖动窗口时**每一帧都会来**，而最大化状态通常不变；不去重的话
  // 会按帧向 Dart 推送消息。只在状态真的翻转时才通知。
  //
  // 用 -1 表示「还不知道」：这样首次 WM_SIZE 一定会通知一次，Dart 侧不必自己
  // 猜初始状态。
  int last_maximized_ = -1;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
