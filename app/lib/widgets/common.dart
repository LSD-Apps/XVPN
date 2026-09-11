import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// 品牌标识：应用图标 + 名称。
///
/// 桌面端出现在自绘标题栏左侧，移动端出现在每页头部左侧。两端共用同一个
/// widget，尺寸与回退逻辑才不会各写一套、慢慢跑偏。
class XvBrandMark extends StatelessWidget {
  const XvBrandMark({super.key, this.label = 'XVPN', this.size = 24, this.fontSize = 14});

  /// 为 null 时只画图标（移动端头部已有页面标题，不必重复品牌名）。
  final String? label;
  final double size;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Image.asset(
          'assets/vpn.png',
          width: size,
          height: size,
          filterQuality: FilterQuality.high,
          // 资源缺失时退回图标，界面不至于出现空洞。
          errorBuilder: (_, _, _) => Icon(Icons.vpn_lock_outlined, size: size - 2, color: XV.green),
        ),
        if (label != null) ...<Widget>[
          const SizedBox(width: 10),
          Text(
            label!,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: XV.text,
            ),
          ),
        ],
      ],
    );
  }
}

/// 文字型快捷操作（切换 / 删除 / 清空 …）。
///
/// 存在的理由有两个，都是触摸端才暴露出来的问题：
///   1. 裸 [GestureDetector] + 12.5px 文字只有约 25×18 的命中区，远低于
///      可用的 40px 下限，手机上经常点不中；
///   2. 主题里关掉了水波纹（`NoSplash` + 透明高亮），点下去毫无反馈。
/// 这里统一补上最小热区与按压态，避免每个调用点各写一遍。
class TapAction extends StatefulWidget {
  const TapAction({
    super.key,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.fontSize = 12.5,
  });

  final String label;
  final VoidCallback onTap;

  /// 危险操作用红色，和桌面端的「删除」按钮保持同一套语义。
  final bool danger;
  final double fontSize;

  @override
  State<TapAction> createState() => _TapActionState();
}

class _TapActionState extends State<TapAction> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _pressed ? XV.hoverOverlay : Colors.transparent,
          borderRadius: BorderRadius.circular(XV.rCtl),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: widget.fontSize,
            color: widget.danger ? XV.red : XV.muted,
          ),
        ),
      ),
    );
  }
}

/// 卡片：原型中的 .card
///
/// 颜色默认值取自当前调色板，因此只能声明为可空、在 build 里兜底——
/// 默认参数必须是编译期常量，而调色板会随主题变化。
class XvCard extends StatelessWidget {
  const XvCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.borderColor,
    this.radius = XV.rCard,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? XV.panel,
        border: Border.all(color: borderColor ?? XV.cardBorder),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}

/// 卡片内的纵向内容：空间够时就是普通 [Column]，不够时可滚动并给出滚动条。
///
/// 为什么需要它：卡片的高度由布局决定，不一定等于内容的自然高度——
/// 桌面端连接页底部两张卡按剩余高度拉伸，手机横屏时整页可用高度只剩 200 上下。
/// 直接把 [Column] 塞进去，内容一多就抛 RenderFlex overflow（实测在
/// 1280×720 窗口下溢出 79px）。
///
/// [SingleChildScrollView] 在高度约束充足时会让子节点保持自然高度、自身缩到
/// 同样高，因此「够就正常显示、不够就滚动」用同一个组件就够，不需要先量高度。
/// 滚动条始终可见，否则用户不知道这里还能往下滚。
///
/// 注意 `Scrollbar.thumbVisibility` 要求显式提供 [ScrollController]，
/// 因此这里必须是有状态组件，由它自己持有并释放控制器。
class XvScrollableColumn extends StatefulWidget {
  const XvScrollableColumn({
    super.key,
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<XvScrollableColumn> createState() => _XvScrollableColumnState();
}

class _XvScrollableColumnState extends State<XvScrollableColumn> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _controller,
        child: Column(
          crossAxisAlignment: widget.crossAxisAlignment,
          children: widget.children,
        ),
      ),
    );
  }
}

/// 卡片标题：原型中的 .card h4
class XvCardTitle extends StatelessWidget {
  const XvCardTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: XvText.sectionLabel);
    if (trailing == null) {
      return Padding(padding: const EdgeInsets.only(bottom: 12), child: label);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[Expanded(child: label), trailing!],
      ),
    );
  }
}

/// 开关：原型中的 .sw —— 40×22，圆角 11，控件 16
class XvSwitch extends StatelessWidget {
  const XvSwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  static const _duration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: AnimatedContainer(
          duration: _duration,
          curve: Curves.easeOut,
          width: 40,
          height: 22,
          decoration: BoxDecoration(
            color: value ? XV.green : XV.switchOff,
            borderRadius: BorderRadius.circular(11),
          ),
          child: AnimatedAlign(
            duration: _duration,
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: XV.knob.withValues(alpha: value ? 1 : 0.85),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分段控件：原型中的 .seg
class XvSegmented extends StatelessWidget {
  const XvSegmented({
    super.key,
    required this.labels,
    required this.index,
    this.onChanged,
    this.expand = false,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int>? onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < labels.length; i++) {
      final selected = i == index;
      final item = MouseRegion(
        cursor: onChanged == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onChanged == null ? null : () => onChanged!(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? XV.panel3 : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              labels[i],
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? XV.text : XV.muted,
              ),
            ),
          ),
        ),
      );
      children.add(expand ? Expanded(child: item) : item);
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: XV.field,
        border: Border.all(color: XV.line),
        borderRadius: BorderRadius.circular(XV.rCtl),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// 单选圆点：原型中的 .radio
class XvRadio extends StatelessWidget {
  const XvRadio({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.only(top: 1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? XV.green : XV.radioBorder,
          width: selected ? 4.5 : 1.5,
        ),
        color: XV.panel,
      ),
    );
  }
}

/// 判定标签：原型中的 .tag（代理 / 直连 / 警示）
class RouteTag extends StatelessWidget {
  const RouteTag({
    super.key,
    required this.label,
    required this.foreground,
    required this.background,
    required this.border,
  });

  RouteTag.kind(RouteKind kind, {super.key, String? label})
      : label = label ?? kind.label,
        foreground = kind == RouteKind.proxy ? XV.violetSoft : XV.blueSoft,
        background = (kind == RouteKind.proxy ? XV.violet : XV.blue).withValues(alpha: 0.13),
        border = (kind == RouteKind.proxy ? XV.violet : XV.blue).withValues(alpha: 0.28);

  RouteTag.warn(this.label, {super.key})
      : foreground = XV.amberSoft,
        background = XV.amber.withValues(alpha: 0.12),
        border = XV.amber.withValues(alpha: 0.28);

  /// 直连标签，对应原型中的 .tag.direct。
  RouteTag.direct(this.label, {super.key})
      : foreground = XV.blueSoft,
        background = XV.blue.withValues(alpha: 0.12),
        border = XV.blue.withValues(alpha: 0.28);

  RouteTag.green(this.label, {super.key})
      : foreground = XV.greenSoft,
        background = XV.green.withValues(alpha: 0.1),
        border = XV.green.withValues(alpha: 0.25);

  final String label;
  final Color foreground;
  final Color background;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: XvText.tag.copyWith(color: foreground),
      ),
    );
  }
}

/// 迷你柱状图：原型中的 .spark
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, this.color, this.height = 22});

  final List<double> values;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final lineColor = color ?? XV.green;
    final peak = values.isEmpty ? 0.0 : values.reduce(math.max);
    final bars = <Widget>[];
    for (var i = 0; i < AppSparkPoints.count; i++) {
      // 采样点不足 12 个时，最左端补最矮的柱子，保证骨架宽度不跳动。
      final sourceIndex = values.length - (AppSparkPoints.count - i);
      final v = (sourceIndex >= 0 && sourceIndex < values.length) ? values[sourceIndex] : 0.0;
      final factor = peak <= 0 ? 0.08 : (v / peak).clamp(0.08, 1.0);
      bars.add(
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: factor,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[lineColor, lineColor.withValues(alpha: 0.25)],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (var i = 0; i < bars.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 2),
            bars[i],
          ],
        ],
      ),
    );
  }
}

/// Sparkline 使用的采样点数量，与 AppState.sparkPoints 保持一致。
class AppSparkPoints {
  AppSparkPoints._();
  static const count = 12;
}

/// 校验项：原型中的 .check
class CheckRow extends StatelessWidget {
  const CheckRow({
    super.key,
    required this.title,
    required this.detail,
    this.mono = false,
    this.warn = false,
  });

  final String title;
  final String detail;

  /// 详情用等宽字体（例如 127.0.0.1:2080）。
  final bool mono;

  /// 这条不是「一切正常」，而是「需要注意」。
  ///
  /// 原先这里恒为绿色对勾，于是 DNS 异常、自检发现某条腿不通时，
  /// 界面上仍然是一片绿色——用户看到的全是「✓」，自然以为没问题。
  /// 检查行的颜色必须反映它自己报告的结论。
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final accent = warn ? XV.amber : XV.green;
    final foreground = warn ? XV.amberSoft : XV.green;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 17,
          height: 17,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withValues(alpha: 0.12),
            border: Border.all(color: accent.withValues(alpha: 0.3)),
          ),
          child: Center(
            child: Text(
              warn ? '!' : '✓',
              style: TextStyle(fontSize: 10, height: 1, color: foreground),
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: XvText.bodyMuted.copyWith(color: XV.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(
                detail,
                style: mono ? XvText.monoSmall : XvText.caption,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 虚线拖拽区：原型中的 .drop（Flutter 无内置虚线边框，用 PathMetrics 绘制）
class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.child,
    this.highlighted = false,
    this.radius = 14,
  });

  final Widget child;
  final bool highlighted;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: highlighted ? XV.green : XV.dashIdle,
        radius: radius,
        strokeWidth: 1.5,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: highlighted ? XV.green.withValues(alpha: 0.04) : XV.panel.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius, this.strokeWidth = 1.5});

  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2, size.width - strokeWidth, size.height - strokeWidth),
          Radius.circular(radius),
        ),
      );
    const dash = 6.0;
    const gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius || old.strokeWidth != strokeWidth;
}

/// 按钮变体。全应用只有这三种，避免样式发散。
enum XvButtonKind {
  /// 次要操作（默认）：浅底 + 描边
  secondary,

  /// 主操作：品牌绿实底。一屏之内只应出现一个。
  primary,

  /// 危险操作：红色浅底
  danger,
}

/// 统一按钮。
///
/// 三条硬性约束，保证全应用观感一致：
///   * 高度固定（默认 36），不随内容变化——按钮排在同一行时基线必然对齐；
///   * 圆角、字号、字重、内边距全部取自这里，调用点不覆盖；
///   * 具备 hover / 按下 / 禁用三态，且过渡时长与其它交互元素一致。
class XvButton extends StatefulWidget {
  const XvButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = XvButtonKind.secondary,
    this.icon,
    this.expand = false,
    this.height = 36,
    this.minWidth = 88,
  });

  final String label;
  final VoidCallback? onPressed;
  final XvButtonKind kind;

  /// 可选的左侧图标，统一 15px。
  final IconData? icon;

  final bool expand;
  final double height;
  final double minWidth;

  @override
  State<XvButton> createState() => _XvButtonState();
}

class _XvButtonState extends State<XvButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final (Color bg, Color fg, Color border) = switch (widget.kind) {
      XvButtonKind.primary => (XV.green, XV.onAccent, Colors.transparent),
      XvButtonKind.secondary => (XV.panel3, XV.text, XV.line),
      XvButtonKind.danger => (
          XV.red.withValues(alpha: 0.10),
          XV.redSoft,
          XV.red.withValues(alpha: 0.28),
        ),
    };

    // 三态：hover 叠一层极淡的前景，按下再叠一层；次要按钮的描边同时提亮。
    var effectiveBg = bg;
    if (enabled && _hover) effectiveBg = Color.alphaBlend(XV.hoverOverlay, effectiveBg);
    if (enabled && _pressed) effectiveBg = Color.alphaBlend(XV.hoverOverlay, effectiveBg);
    final effectiveBorder = (enabled && _hover && widget.kind == XvButtonKind.secondary)
        ? Color.alphaBlend(XV.hoverOverlay, border)
        : border;

    final Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: enabled ? effectiveBg : effectiveBg.withValues(alpha: 0.5),
        border: Border.all(color: enabled ? effectiveBorder : border.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(XV.rCtl),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(widget.icon, size: 15, color: enabled ? fg : fg.withValues(alpha: 0.4)),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
                color: enabled ? fg : fg.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );

    final sized = ConstrainedBox(
      constraints: BoxConstraints(minWidth: widget.expand ? 0 : widget.minWidth),
      child: content,
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          scale: _pressed ? 0.975 : 1,
          child: widget.expand ? SizedBox(width: double.infinity, child: sized) : sized,
        ),
      ),
    );
  }
}

/// 侧栏导航项：原型中的 .nav
class NavItem extends StatefulWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(14, 9, 11, 9),
          decoration: BoxDecoration(
            color: active
                ? XV.panel3
                : (_hover ? XV.panel3.withValues(alpha: 0.45) : Colors.transparent),
            borderRadius: BorderRadius.circular(XV.rCtl),
          ),
          child: Stack(
            children: <Widget>[
              // 选中指示条：比整块底色更克制，也更容易一眼看出当前位置。
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                left: -14,
                top: 8,
                bottom: 8,
                width: 3,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: active ? 1 : 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: XV.green,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  Icon(widget.icon, size: 16, color: active ? XV.green : XV.muted),
                  const SizedBox(width: 11),
                  Text(widget.label, style: active ? XvText.navLabelActive : XvText.navLabel),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 连接状态胶囊：原型中的 .pill-on
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final dot = active ? XV.green : XV.dotIdle;
    final fg = active ? XV.greenSoft : XV.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: active ? XV.green.withValues(alpha: 0.09) : XV.muted.withValues(alpha: 0.08),
        border: Border.all(color: active ? XV.green.withValues(alpha: 0.22) : XV.line),
        borderRadius: BorderRadius.circular(XV.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: dot,
              shape: BoxShape.circle,
              boxShadow: active
                  ? <BoxShadow>[BoxShadow(color: dot, blurRadius: 8, spreadRadius: 0)]
                  : null,
            ),
          ),
          const SizedBox(width: 7),
          Text(label, style: TextStyle(fontSize: 11.5, color: fg)),
        ],
      ),
    );
  }
}

/// 移动端页头：原型中的 .m-head（标题 + 状态）
class MobileHeader extends StatelessWidget {
  const MobileHeader({super.key, required this.title, this.statusLabel, this.statusActive = false});

  final String title;

  /// 为空时不显示右侧状态；设置页对应原型中无状态的写法。
  final String? statusLabel;
  final bool statusActive;

  @override
  Widget build(BuildContext context) {
    final dot = statusActive ? XV.green : XV.dotIdle;
    final fg = statusActive ? XV.greenSoft : XV.muted2;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        children: <Widget>[
          // 左侧固定展示应用图标，标题紧随其后：头部是移动端唯一的品牌露出位置。
          const XvBrandMark(label: null, size: 22),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: XV.text,
            ),
          ),
          const Spacer(),
          if (statusLabel != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: dot,
                    shape: BoxShape.circle,
                    boxShadow: statusActive
                        ? <BoxShadow>[BoxShadow(color: dot, blurRadius: 8)]
                        : null,
                  ),
                ),
                const SizedBox(width: 6),
                Text(statusLabel!, style: TextStyle(fontSize: 11.5, color: fg)),
              ],
            ),
        ],
      ),
    );
  }
}

/// 计时条：原型中的 .timer
class TimerChip extends StatelessWidget {
  const TimerChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: XV.field,
        border: Border.all(color: XV.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: XV.muted, fontFamilyFallback: XV.monoFallback),
      ),
    );
  }
}

/// 搜索框：原型中的 .search
class XvSearchField extends StatelessWidget {
  const XvSearchField({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.onClear,
  });

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;

  /// 非空时在右侧显示一个清除按钮。
  ///
  /// 搜索框默认没有回退入口：用户打完字想恢复完整列表，只能一个个删。
  /// 记录多达几百条时，这个缺口会让人以为「记录丢了」。
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: XV.field,
        border: Border.all(color: XV.line),
        borderRadius: BorderRadius.circular(XV.rCtl),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 14, color: XV.muted2),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorWidth: 1.5,
              style: TextStyle(fontSize: 12.5, color: XV.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                hintText: hint,
                hintStyle: TextStyle(fontSize: 12.5, color: XV.muted2),
              ),
            ),
          ),
          if (onClear != null)
            TapAction(label: '清除', onTap: onClear!),
        ],
      ),
    );
  }
}

/// 设置行：原型中的 .set-row。
/// 行间用 1px 分隔线，最后一行不画（对应 :last-child 的样式覆盖）。
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    required this.description,
    required this.control,
    this.isLast = false,
    this.controlWidth,
  });

  final String title;
  final String description;
  final Widget control;
  final bool isLast;

  /// 控制区固定宽度，用于让多行的分段控件左边缘对齐。
  final double? controlWidth;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: EdgeInsets.only(top: 13, bottom: isLast ? 2 : 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: XvText.rowTitle),
                const SizedBox(height: 4),
                Text(description, style: XvText.rowDesc),
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (controlWidth != null)
            SizedBox(width: controlWidth, child: Align(alignment: Alignment.centerRight, child: control))
          else
            control,
        ],
      ),
    );

    if (isLast) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        row,
        Divider(height: 1, thickness: 1, color: XV.line2),
      ],
    );
  }
}

/// 列表行 / 表格行：统一 hover 反馈。
///
/// 表格类界面最容易显得"死板"，给行加一层极淡的悬停底色，鼠标扫过时
/// 能立刻确认自己在读哪一行——这是现代桌面应用的基本手感。
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    this.onTap,
    this.showDivider = true,
    this.radius = 8,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool showDivider;
  final double radius;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final clickable = widget.onTap != null;
    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hover ? XV.panel3.withValues(alpha: 0.55) : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.radius),
            border: widget.showDivider
                ? Border(bottom: BorderSide(color: _hover ? Colors.transparent : XV.line2))
                : null,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: widget.padding,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 选项卡（接管方式）：原型中的 .opt
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.selected,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: selected ? XV.green.withValues(alpha: 0.05) : XV.field,
            border: Border.all(
              color: selected ? XV.green.withValues(alpha: 0.35) : XV.line,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              XvRadio(selected: selected),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: XvText.body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(description, style: XvText.rowDesc),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
