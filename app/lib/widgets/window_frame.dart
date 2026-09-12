import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/window_controls.dart';

/// 无边框窗口的边缘缩放热区。
///
/// 客户区覆盖整个窗口之后，系统不再提供可拖拽的缩放边框，而且鼠标命中测试
/// 会落在 Flutter 视图上，所以必须在界面层自己铺一圈热区：按下的一瞬间就把
/// 缩放操作交回系统（ReleaseCapture + WM_NCLBUTTONDOWN）。
///
/// 只在桌面端生效；移动端原样返回子树。
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child, this.thickness = 5});

  final Widget child;

  /// 热区厚度（逻辑像素）。
  final double thickness;

  @override
  Widget build(BuildContext context) {
    if (!WindowControls.supported) return child;

    const edges =
        <({WindowEdge edge, Alignment align, SystemMouseCursor cursor})>[
          (
            edge: WindowEdge.top,
            align: Alignment.topCenter,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
          (
            edge: WindowEdge.bottom,
            align: Alignment.bottomCenter,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
          (
            edge: WindowEdge.left,
            align: Alignment.centerLeft,
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
          (
            edge: WindowEdge.right,
            align: Alignment.centerRight,
            cursor: SystemMouseCursors.resizeLeftRight,
          ),
          (
            edge: WindowEdge.topLeft,
            align: Alignment.topLeft,
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
          (
            edge: WindowEdge.topRight,
            align: Alignment.topRight,
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
          (
            edge: WindowEdge.bottomLeft,
            align: Alignment.bottomLeft,
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
          (
            edge: WindowEdge.bottomRight,
            align: Alignment.bottomRight,
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ];

    return Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        for (final e in edges)
          Align(
            alignment: e.align,
            child: _ResizeHandle(
              edge: e.edge,
              cursor: e.cursor,
              thickness: thickness,
            ),
          ),
      ],
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.edge,
    required this.cursor,
    required this.thickness,
  });

  final WindowEdge edge;
  final SystemMouseCursor cursor;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final double t = thickness;
    final double c = thickness * 2; // 角上的热区放大，便于同时命中两个方向
    final (double w, double h) = switch (edge) {
      WindowEdge.top => (double.infinity, t),
      WindowEdge.bottom => (double.infinity, t),
      WindowEdge.left => (t, double.infinity),
      WindowEdge.right => (t, double.infinity),
      WindowEdge.topLeft => (c, c),
      WindowEdge.topRight => (c, c),
      WindowEdge.bottomLeft => (c, c),
      WindowEdge.bottomRight => (c, c),
    };

    return MouseRegion(
      cursor: cursor,
      child: Listener(
        // 用 Listener 而不是 GestureDetector：缩放必须在按下的一瞬间接管，
        // 不能等手势识别完成。opaque 保证事件不会穿透到下层的内容区。
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => WindowControls.startResize(edge),
        child: SizedBox(width: w, height: h),
      ),
    );
  }
}
