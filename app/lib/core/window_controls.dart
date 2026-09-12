import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 窗口可缩放的边与角。
enum WindowEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

extension WindowEdgeX on WindowEdge {
  String get wireName => switch (this) {
    WindowEdge.left => 'left',
    WindowEdge.right => 'right',
    WindowEdge.top => 'top',
    WindowEdge.bottom => 'bottom',
    WindowEdge.topLeft => 'topLeft',
    WindowEdge.topRight => 'topRight',
    WindowEdge.bottomLeft => 'bottomLeft',
    WindowEdge.bottomRight => 'bottomRight',
  };
}

/// 与原生窗口对接的通道。
///
/// 桌面端窗口是无边框的（Windows 上去掉了原生标题栏；Linux X11 下用
/// `gtk_window_set_decorated(FALSE)`），标题栏由 Flutter 自绘，见
/// widgets/title_bar.dart。Wayland 下无法可靠自绘/驱动，交回原生装饰并让
/// Dart 收起自绘按钮。
///
/// 拖动与缩放必须由界面主动触发：Flutter 视图是覆盖整个窗口的子窗口，
/// 系统把鼠标命中测试交给它，顶层窗口的 WM_NCHITTEST / GTK 事件收不到，
/// 因此「返回 HTCAPTION 就能拖」在 Flutter 里并不成立（已实测确认）。
class WindowControls {
  WindowControls._();

  /// 与原生窗口对接的通道。
  ///
  /// 窗口控制与系统代理共用同一个平台通道（Windows 在 flutter_window.cpp、
  /// Linux 在 runner/my_application.cc 中注册），因此这里的方法名必须与
  /// 两边都保持一致。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/platform');

  /// 是否需要自绘标题栏（客户端装饰）。
  ///
  /// Windows 上原生标题栏已被 WM_NCCALCSIZE 去掉，恒为自绘；Android 由系统
  /// 状态栏接管，界面里不画标题栏。Linux 要看会话类型：X11 下可以自绘，
  /// Wayland 下窗口移动/缩放/最大化都不可靠（合成器不保证支持），此时交回
  /// 原生装饰，`supported` 为 false——否则会得到一个拖不动、点不动的死标题栏。
  ///
  /// Linux 的能力在启动时由 [listen] 问原生侧（见 linux/runner/
  /// my_application.cc），因此这里默认 true 只是「查询完成前的乐观初值」；
  /// 实际值在 `runApp` 之前就已经确定。
  static bool _linuxClientDecorations = true;

  static bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.windows => true,
    TargetPlatform.linux => _linuxClientDecorations,
    _ => false,
  };

  /// 供测试注入 Wayland 回退（开发机是 Windows，跑不到真实 Wayland 会话）。
  @visibleForTesting
  static set linuxClientDecorations(bool value) =>
      _linuxClientDecorations = value;

  static Future<void> minimize() => _invoke('minimize');

  static Future<void> toggleMaximize() => _invoke('toggleMaximize');

  static Future<void> close() => _invoke('close');

  /// 开始拖动窗口。应在标题栏按下时调用。
  static Future<void> startDragging() => _invoke('startDragging');

  /// 开始缩放窗口。应在边缘/角落按下时调用。
  static Future<void> startResize(WindowEdge edge) =>
      _invoke('startResize', edge.wireName);

  /// 查询当前是否最大化，用于切换按钮图标。
  static Future<bool> isMaximized() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isMaximized') ?? false;
    } on Object {
      return false;
    }
  }

  /// 当前是否最大化，**由原生推送**。
  ///
  /// 为什么需要它：最大化并不只发生在点按钮的时候。双击标题栏、Win+↑、贴边、
  /// 从任务栏还原……这些都绕过了 Dart，窗口状态变了而界面不知道——标题栏会停在
  /// 旧图标上（已经最大化了却还画着「最大化」），用户按下去实际是还原，图形与
  /// 行为对不上。原生在状态翻转后推一次（Windows 是 WM_SIZE，Linux 是
  /// window-state-event），这里接住并广播。
  static final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  /// 接住原生推来的窗口状态。应在应用启动时调用一次。
  ///
  /// Linux 上还要先问一句「这个会话能不能自绘窗口边框」：Wayland 下原生
  /// 保留装饰，界面必须把自绘按钮与拖动区收起来（见 [supported]）。
  static Future<void> listen() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      try {
        final value = await _channel.invokeMethod<bool>('clientDecorations');
        if (value != null) _linuxClientDecorations = value;
      } on Object {
        // 通道不可用（测试环境、原生忘记注册）：保持 Linux 的乐观初值。
        // 这里不静默当成 Wayland——那会让 X11 用户白丢自绘标题栏。
      }
    }
    if (!supported) return;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'maximizedChanged') {
        final value = call.arguments;
        if (value is bool) maximized.value = value;
      }
      return null;
    });
    // 启动时先同步一次，避免「以最大化状态启动」时要等第一次 WM_SIZE 才纠正。
    maximized.value = await isMaximized();
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object {
      // 通道不可用时忽略：窗口操作只是便利功能，不影响主流程。
    }
  }
}
