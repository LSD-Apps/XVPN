#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>

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

  /// 托盘图标的回调消息号。
  static constexpr UINT kTrayCallbackMessage = WM_APP + 1;
  static constexpr int kTrayMenuShow = 40001;
  static constexpr int kTrayMenuQuit = 40002;

  NOTIFYICONDATAW tray_icon_ = {};
  bool tray_installed_ = false;

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
