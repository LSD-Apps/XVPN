import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/window_controls.dart';
import '../format.dart';
import '../theme.dart';
import '../theme_controller.dart';
import 'common.dart';

/// 桌面端自绘标题栏。
///
/// 原生标题栏已由 WM_NCCALCSIZE 去掉，这一条由 Flutter 绘制，因此可以做得
/// 比系统标题栏更高，并采用与左侧边栏完全相同的底色——两者视觉上连成一体。
/// 品牌标识只在这里出现一次，侧边栏不再重复显示 logo 与名称。
///
/// 拖动与窗口按钮都通过 [WindowControls] 交回原生实现：客户区覆盖整个窗口后，
/// 系统不会再自动处理标题栏拖动。
class XvTitleBar extends StatelessWidget {
  const XvTitleBar({super.key, required this.theme, required this.state});

  final ThemeController theme;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    // 背景色必须与侧边栏完全一致：这是「融合」的全部前提。
    // 上一版把底色连同分割线一起删掉了，标题栏因此露出 Scaffold 的
    // 页面底色，与侧栏形成明显色差。
    return Container(
      height: XV.titleBarHeight,
      color: XV.sidebar,
      child: Row(
        children: <Widget>[
          // 左侧整片空白都是拖动区，双击可最大化 / 还原。
          Expanded(
            child: _DragRegion(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: _Brand(),
              ),
            ),
          ),
          _ConnectionTimer(state: state),
          const SizedBox(width: 10),
          _ThemeButton(theme: theme),
          const SizedBox(width: 4),
          Container(width: 1, height: 20, color: XV.line),
          const SizedBox(width: 4),
          const _WindowButtons(),
        ],
      ),
    );
  }
}

/// 运行计时。放在标题栏里随时可见，且刻意不加边框与底色——
/// 它是一条信息，不是一个控件，画成盒子只会让标题栏变乱。
class _ConnectionTimer extends StatelessWidget {
  const _ConnectionTimer({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final connected = state.isConnected;
    final connecting = state.isConnecting;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          connected ? Icons.timer_outlined : Icons.timer_off_outlined,
          size: 14,
          color: connected ? XV.green : XV.muted2,
        ),
        const SizedBox(width: 7),
        Text(
          connected || connecting ? fmtDuration(state.elapsed) : '--:--:--',
          style: TextStyle(
            fontSize: 12.5,
            letterSpacing: 0.4,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            fontFamilyFallback: XV.monoFallback,
            color: connected ? XV.muted : XV.muted2,
          ),
        ),
      ],
    );
  }
}

/// 拖动区：按下即把拖动交回系统（ReleaseCapture + WM_NCLBUTTONDOWN）。
class _DragRegion extends StatelessWidget {
  const _DragRegion({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => WindowControls.startDragging(),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );
  }
}

/// 品牌区：图标 + 名称，只在标题栏出现。
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => const XvBrandMark();
}

/// 主题切换：跟随系统 → 亮色 → 深色 → 跟随系统。
class _ThemeButton extends StatefulWidget {
  const _ThemeButton({required this.theme});

  final ThemeController theme;

  @override
  State<_ThemeButton> createState() => _ThemeButtonState();
}

class _ThemeButtonState extends State<_ThemeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '主题：${widget.theme.label}（点击切换）',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.theme.cycle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: _hover ? XV.panel3 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(widget.theme.icon, size: 15, color: XV.muted),
                const SizedBox(width: 8),
                Text(
                  widget.theme.label,
                  style: TextStyle(fontSize: 12, color: XV.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 最小化 / 最大化 / 关闭。图标为自绘，比默认图标更粗更大，便于点击辨认。
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _refreshMaximized();
  }

  Future<void> _refreshMaximized() async {
    final value = await WindowControls.isMaximized();
    if (!mounted) return;
    setState(() => _maximized = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!WindowControls.supported) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _WindowButton(
          glyph: WindowGlyph.minimize,
          onTap: WindowControls.minimize,
          tooltip: '最小化',
        ),
        _WindowButton(
          glyph: _maximized ? WindowGlyph.restore : WindowGlyph.maximize,
          onTap: () async {
            await WindowControls.toggleMaximize();
            await _refreshMaximized();
          },
          tooltip: _maximized ? '还原' : '最大化',
        ),
        _WindowButton(
          glyph: WindowGlyph.close,
          onTap: WindowControls.close,
          tooltip: '关闭',
          danger: true,
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.glyph,
    required this.onTap,
    required this.tooltip,
    this.danger = false,
  });

  final WindowGlyph glyph;
  final Future<void> Function() onTap;
  final String tooltip;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color hoverBg = widget.danger ? XV.red : XV.panel3;
    final Color fg = _hover && widget.danger ? XV.onAccent : XV.muted;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onTap(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: XV.titleBarHeight,
            color: _hover ? hoverBg : Colors.transparent,
            child: Center(
              child: CustomPaint(
                size: const Size(15, 15),
                painter: _WindowGlyphPainter(glyph: widget.glyph, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum WindowGlyph { minimize, maximize, restore, close }

/// 自绘窗口按钮图形。笔画比字体内置图标更粗，视觉上更清晰也更现代。
class _WindowGlyphPainter extends CustomPainter {
  const _WindowGlyphPainter({required this.glyph, required this.color});

  final WindowGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;
    final center = Offset(size.width / 2, size.height / 2);

    switch (glyph) {
      case WindowGlyph.minimize:
        // 一条 13 宽的横线，位于视觉中线略偏下
        canvas.drawLine(
          Offset(center.dx - 6.5, center.dy + 1),
          Offset(center.dx + 6.5, center.dy + 1),
          paint,
        );
      case WindowGlyph.maximize:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: center, width: 12, height: 12),
            const Radius.circular(1.5),
          ),
          paint,
        );
      case WindowGlyph.restore:
        // 两个错位的方框，表示「还原」
        final back = Rect.fromLTWH(center.dx - 5, center.dy - 6, 10, 10);
        final front = Rect.fromLTWH(center.dx - 6, center.dy - 3, 10, 10);
        canvas.drawRRect(
          RRect.fromRectAndRadius(back, const Radius.circular(1.5)),
          paint..color = color.withValues(alpha: 0.55),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(front, const Radius.circular(1.5)),
          paint..color = color,
        );
      case WindowGlyph.close:
        final s = 6.0;
        canvas.drawLine(
          Offset(center.dx - s, center.dy - s),
          Offset(center.dx + s, center.dy + s),
          paint,
        );
        canvas.drawLine(
          Offset(center.dx + s, center.dy - s),
          Offset(center.dx - s, center.dy + s),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(_WindowGlyphPainter old) => old.glyph != glyph || old.color != color;
}
