import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 窗口可缩放的边与角。
enum WindowEdge { left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }

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
/// 桌面端窗口是无边框的（原生标题栏已被 WM_NCCALCSIZE 去掉），标题栏由
/// Flutter 自绘，见 widgets/title_bar.dart。
///
/// 拖动与缩放必须由界面主动触发：Flutter 视图是覆盖整个窗口的子窗口，
/// 系统把鼠标命中测试交给它，顶层窗口的 WM_NCHITTEST 收不到消息，
/// 因此「返回 HTCAPTION 就能拖」在 Flutter 里并不成立（已实测确认）。
class WindowControls {
  WindowControls._();

  /// 与原生窗口对接的通道。
  ///
  /// 窗口控制与系统代理共用同一个平台通道（原生侧在 flutter_window.cpp 中
  /// 统一注册），因此这里的方法名必须与那边保持一致。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/platform');

  /// 是否需要自绘标题栏。Android 由系统状态栏接管，界面里不画标题栏。
  static bool get supported => defaultTargetPlatform == TargetPlatform.windows;

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

  static Future<void> _invoke(String method, [Object? arguments]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object {
      // 通道不可用时忽略：窗口操作只是便利功能，不影响主流程。
    }
  }
}
