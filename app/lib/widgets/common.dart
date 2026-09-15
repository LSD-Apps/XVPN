import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// 品牌标识：应用图标 + 名称。
///
/// 桌面端出现在自绘标题栏左侧，移动端出现在每页头部左侧。两端共用同一个
/// widget，尺寸与回退逻辑才不会各写一套、慢慢跑偏。
class XvBrandMark extends StatelessWidget {
  const XvBrandMark({
    super.key,
    this.label = '幽门',
    this.size = 24,
    this.fontSize = 14,
  });

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
          errorBuilder: (_, _, _) =>
              Icon(Icons.vpn_lock_outlined, size: size - 2, color: XV.green),
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
    this.header,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final List<Widget> children;

  /// 固定在滚动区**之外**的内容，通常是卡片标题。
  ///
  /// 为什么需要它：此前标题被放在 [children] 的第一个，于是卡片内部一滚动，
  /// 标题就跟着滚出视野——用户滚下去看内容时，卡片顶部只剩半截文字，看不出
  /// 这一块在讲什么。标题属于「这块卡片的身份」，不该随内容移动。
  final Widget? header;

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
    final scrollable = Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _controller,
        child: Padding(
          // 右侧让出滚动条的宽度。
          //
          // Flutter 桌面端的滚动条是**浮在内容之上**的、不占布局宽度，因此内容
          // 会顶到卡片右边缘、被滚动条压住（看起来就是「滚动条与内容重叠」）。
          // 留出 10px 之后两者互不遮挡；而内容本身本来就有自己的右边距。
          padding: const EdgeInsets.only(right: 10),
          child: Column(
            crossAxisAlignment: widget.crossAxisAlignment,
            children: widget.children,
          ),
        ),
      ),
    );

    final header = widget.header;
    if (header == null) return scrollable;
    // Flexible 是必需的，不是可选优化：SingleChildScrollView 在 Column 里会按
    // 子内容的**自然高度**参与布局，加上表头之后总高超出卡片可用高度，直接抛
    // 「RenderFlex overflowed」。Flexible 让它收缩到剩余空间，滚动才真正生效。
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.crossAxisAlignment,
      children: <Widget>[
        header,
        Flexible(child: scrollable),
      ],
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
        children: <Widget>[
          Expanded(child: label),
          trailing!,
        ],
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
/// 分段选择器（原型中的 .seg）。
///
/// ## 为什么用「滑块」而不是「两段各自变色」
///
/// 原实现给每个分段自己画背景，选中时把该段的背景淡入、另一段淡出。这在
/// 两个分段相邻时会呈现出一个很难看的中间态：两个圆角矩形同时半透明地贴在
/// 一起，视觉上「两个状态串在一起」，而且因为没有任何位移，切换过程读不出
/// 「选中项从这边移到了那边」。
///
/// 更糟的是对比度：选中态用的 `panel3` 与轨道用的 `field` 色值极近——
/// 亮色下是 #ECECF2 对 #F1F1F6，几乎看不出差别；暗色下 #1B2231 对 #0E131D
/// 也只是勉强可辨。于是「选中」这件事本身就不明显，再叠加淡入淡出，
/// 给人的感觉就是切换不顺畅、状态糊在一起。
///
/// 现在改成**单一滑块**：轨道底色不变，一块高对比的圆角滑块在分段之间平移，
/// 文字颜色与字重同步过渡。一个指示器只有一个位置，「选中的是哪个」一眼可读，
/// 位移本身也把「切换」这件事表达出来了。
///
/// 滑块用 [Alignment] 定位，因此 `expand` 与非 `expand` 两种情况共用同一套
/// 几何：N 段时第 i 段的中心对应 `-1 + 2i/(N-1)`，而 [AnimatedAlign] 在两点
/// 之间是线性插值，恰好等于「按等宽分段平移」的结果——即便各段文字宽度不等，
/// 滑块也能停在视觉上合理的位置。
class XvSegmented extends StatefulWidget {
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

  /// 滑块平移时长。
  ///
  /// 140ms 配在「淡入淡出」上显得拖沓（视觉上像是在等它变完），
  /// 而滑块这种有明确位移的动效需要稍长一点才看得清轨迹，
  /// 因此取 180ms 配 easeOutCubic：起步快、收尾稳，读起来是「咔哒」一下。
  static const Duration slideDuration = Duration(milliseconds: 180);

  static const Curve slideCurve = Curves.easeOutCubic;

  /// 轨道内边距。
  static const double trackPadding = 3;

  /// 滑块的调试与测试标识。
  ///
  /// 滑块是自绘的装饰盒，从组件树里很难稳定地认出它（按类型找会撞上别的
  /// Container），因此挂一个具名 Key：测试据此断言它的位置与宽度。
  static const Key thumbKey = Key('xv-segmented-thumb');

  @override
  State<XvSegmented> createState() => _XvSegmentedState();
}

class _XvSegmentedState extends State<XvSegmented> {
  /// 是否已经完成过首帧。
  ///
  /// 首帧不做动画：组件刚从树上建出来时 [AnimatedAlign] 会从默认值滚到目标
  /// 位置，那会表现为「页面一打开滑块自己滑过去」。只有用户点选引起的
  /// 变化才该有位移。
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    // 首帧之后再打开动画开关。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _settled = true);
    });
  }

  int get _count => widget.labels.length;

  @override
  Widget build(BuildContext context) {
    final count = _count;
    if (count == 0) return const SizedBox.shrink();

    // 索引越界时收敛到合法范围：调用方传入的 index 可能与 labels 不同步
    // （例如列表变短了），越界不该让滑块跑到轨道外面去。
    final safeIndex = widget.index.clamp(0, count - 1);
    final enabled = widget.onChanged != null;

    final row = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < count; i++) _buildSegment(i, safeIndex, enabled),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(XvSegmented.trackPadding),
      decoration: BoxDecoration(
        color: XV.field,
        border: Border.all(color: XV.line),
        borderRadius: BorderRadius.circular(XV.rCtl),
      ),
      child: Stack(
        children: <Widget>[
          // 滑块在下层，文字在上层，因此标签始终清晰可读。
          //
          // 滑块的位置与宽度都用**像素**算，而不是用 Alignment 或
          // FractionallySizedBox 的比例：
          //   * 非 expand 时 Row 是 MainAxisSize.min，整条轨道在布局期处于
          //     无界约束下，FractionallySizedBox 会把宽度算成 Infinity 而报错，
          //     而且此时轨道宽度也拿不到（依赖内容）；
          //   * 各段文字宽度本来就不相等（「跟随系统」比「亮色」宽得多），
          //     按等分比例定位会让滑块与文字错位。
          // 这里用一次「先排文字、测量、再定位」的方式，两者都解决。
          if (enabled)
            Positioned.fill(
              child: _SlidingThumb(
                labels: widget.labels,
                expand: widget.expand,
                index: safeIndex,
                animate: _settled,
              ),
            ),
          row,
        ],
      ),
    );
  }

  Widget _buildSegment(int i, int safeIndex, bool enabled) {
    final selected = i == safeIndex;
    // 文字颜色与字重的过渡交给 AnimatedDefaultTextStyle，文字本身不再写 style，
    // 否则两处都设样式，实际生效的是内层、过渡也就白做了。
    final label = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => widget.onChanged!(i) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          // 等宽排布下每个分段宽度由外部决定，标签在选中时（w600）比未选中略宽，
          // 极端情况下可能超出分配到的槽位。宁可省略号，也不要抛 overflow。
          child: Text(
            widget.labels[i],
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

    // 文字过渡用 120ms：比滑块稍快一点收束，
    // 避免出现「滑块已经停稳、文字还在变」的拖尾感。
    final animated = AnimatedDefaultTextStyle(
      duration: _settled ? const Duration(milliseconds: 120) : Duration.zero,
      curve: XvSegmented.slideCurve,
      style: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        color: selected ? XV.text : XV.muted,
      ),
      child: label,
    );
    return widget.expand ? Expanded(child: animated) : animated;
  }
}

/// 滑动块：按各段的**实测宽度**把自己摆到被选中那一段下面。
///
/// 为什么需要这么一层：滑块要贴合每一段文字，而各段宽度并不相等
/// （「跟随系统」明显比「亮色」宽），按等分比例定位会错位；而轨道在非 expand
/// 时是 `MainAxisSize.min`，布局期处于无界约束下，拿不到轨道宽度，
/// 用 `FractionallySizedBox` 之类的比例控件会直接把宽度算成 Infinity。
///
/// 做法是：先按真实约束把「等宽分段」的占位排一遍并测量（这一步只测量、不上屏），
/// 得到每段的左右边界；再用 [AnimatedPositioned] 把滑块放到目标段的位置。
/// 测量结果存进 State，只在宽度或段数变化时重算，不进入布局热路径。
class _SlidingThumb extends StatefulWidget {
  const _SlidingThumb({
    required this.labels,
    required this.expand,
    required this.index,
    required this.animate,
  });

  final List<String> labels;

  /// 是否等宽铺满。等宽时各段几何只取决于轨道宽度，与文字宽度无关。
  final bool expand;

  final int index;

  /// 是否播放位移动画。首帧为 false，避免组件刚建出来时滑块自己滑过去。
  final bool animate;

  @override
  State<_SlidingThumb> createState() => _SlidingThumbState();
}

class _SlidingThumbState extends State<_SlidingThumb> {
  /// 每段的左边界与宽度。
  List<({double left, double width})> _segments =
      const <({double left, double width})>[];

  /// 上一次测量时的可用尺寸。尺寸没变就不重复测量。
  Size? _measuredFor;

  /// 单段的水平内边距，与 [_buildSegment] 保持一致。
  static const double _horizontalPadding = 14;

  /// 某个标签在「未选中」与「选中」两种字重下所需的宽度，取较大者。
  ///
  /// 必须取较大者：选中段是 w600、未选中是 w400，两者宽度不同。若按当前字重
  /// 测量，切换时滑块宽度会跟着变，看起来像在「抖」。
  static double _segmentWidth(String label) {
    var widest = 0.0;
    for (final weight in <FontWeight>[FontWeight.w400, FontWeight.w600]) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: 12, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return widest + _horizontalPadding * 2;
  }

  /// 按当前约束测量各段的几何。
  ///
  /// 用 [TextPainter] 真实排版文字来拿宽度，而不是按字符数估算：
  /// 中英混排、全角标点、字重都会影响宽度，估算必然对不齐。
  List<({double left, double width})> _measure(BoxConstraints constraints) {
    final count = widget.labels.length;
    final available = constraints.maxWidth;
    if (count == 0 || !available.isFinite || available <= 0) {
      return const <({double left, double width})>[];
    }

    final segments = <({double left, double width})>[];
    if (widget.expand) {
      // 等宽：各段均分，最后一段吃掉舍入误差。
      final slot = available / count;
      for (var i = 0; i < count; i++) {
        final left = slot * i;
        segments.add((
          left: left,
          width: i == count - 1 ? available - left : slot,
        ));
      }
      return segments;
    }

    // 非等宽：按自然宽度紧排。Row 在 MainAxisSize.min 下从起点排，
    // 因此这里也从 0 开始，不能自作主张居中——那会让滑块与文字错位。
    var cursor = 0.0;
    for (final label in widget.labels) {
      final width = _segmentWidth(label);
      segments.add((left: cursor, width: width));
      cursor += width;
    }
    return segments;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_measuredFor != size) {
          _measuredFor = size;
          _segments = _measure(constraints);
        }
        if (_segments.isEmpty) return const SizedBox.shrink();

        final target = _segments[widget.index.clamp(0, _segments.length - 1)];
        return Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: widget.animate
                  ? XvSegmented.slideDuration
                  : Duration.zero,
              curve: XvSegmented.slideCurve,
              left: target.left,
              top: 0,
              bottom: 0,
              width: target.width,
              child: DecoratedBox(
                key: XvSegmented.thumbKey,
                decoration: BoxDecoration(
                  color: XV.segThumb,
                  borderRadius: BorderRadius.circular(XV.rCtl - 3),
                  // 阴影是暗色下把滑块从轨道里「抬起来」的辅助手段：
                  // 色差为主，投影为辅。
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: XV.shadow,
                      blurRadius: 6,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
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
      background = (kind == RouteKind.proxy ? XV.violet : XV.blue).withValues(
        alpha: 0.13,
      ),
      border = (kind == RouteKind.proxy ? XV.violet : XV.blue).withValues(
        alpha: 0.28,
      );

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

  /// 危险标签：问题在外部、用户改不了（例如走了隧道仍然失败）。
  ///
  /// 与 [RouteTag.warn] 的区别是「能不能自己解决」：琥珀色用于「我们能改」的
  /// 情况（疑似规则未覆盖），红色用于「只能换节点」的情况。两者混用会让用户
  /// 对着一个自己无能为力的问题反复折腾规则。
  RouteTag.danger(this.label, {super.key})
    : foreground = XV.redSoft,
      background = XV.red.withValues(alpha: 0.12),
      border = XV.red.withValues(alpha: 0.28);

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
      child: Text(label, style: XvText.tag.copyWith(color: foreground)),
    );
  }
}

/// 迷你柱状图：原型中的 .spark
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color,
    this.height = 22,
  });

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
      final v = (sourceIndex >= 0 && sourceIndex < values.length)
          ? values[sourceIndex]
          : 0.0;
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
                    colors: <Color>[
                      lineColor,
                      lineColor.withValues(alpha: 0.25),
                    ],
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
    this.action,
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

  /// 行尾的操作入口。
  ///
  /// 有些检查是**采样**出来的结论（DNS 健康、启动自检），结论会随时间变化。
  /// 只展示不给重测入口，用户遇到「刚才还好好的」就只能干等下一个采样周期。
  final Widget? action;

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
              Text(
                title,
                style: XvText.bodyMuted.copyWith(
                  color: XV.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(detail, style: mono ? XvText.monoSmall : XvText.caption),
            ],
          ),
        ),
        if (action != null) ...<Widget>[
          const SizedBox(width: 8),
          // 与标题对齐而不是与整块居中对齐：说明可能换行，居中会让它浮在两行之间。
          Padding(padding: const EdgeInsets.only(top: 1), child: action!),
        ],
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
          color: highlighted
              ? XV.green.withValues(alpha: 0.04)
              : XV.panel.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.radius,
    this.strokeWidth = 1.5,
  });

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
          Rect.fromLTWH(
            strokeWidth / 2,
            strokeWidth / 2,
            size.width - strokeWidth,
            size.height - strokeWidth,
          ),
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
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth;
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
///   * 高度固定（默认 [XvControlMetrics.height]，与输入框、分段控件同高），
///     不随内容变化——同一行的控件基线必然对齐；
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
    this.height = XvControlMetrics.height,
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
    if (enabled && _hover) {
      effectiveBg = Color.alphaBlend(XV.hoverOverlay, effectiveBg);
    }
    if (enabled && _pressed) {
      effectiveBg = Color.alphaBlend(XV.hoverOverlay, effectiveBg);
    }
    final effectiveBorder =
        (enabled && _hover && widget.kind == XvButtonKind.secondary)
        ? Color.alphaBlend(XV.hoverOverlay, border)
        : border;

    final Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: enabled ? effectiveBg : effectiveBg.withValues(alpha: 0.5),
        border: Border.all(
          color: enabled ? effectiveBorder : border.withValues(alpha: 0.6),
        ),
        borderRadius: BorderRadius.circular(XV.rCtl),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(
              widget.icon,
              size: 15,
              color: enabled ? fg : fg.withValues(alpha: 0.4),
            ),
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
      constraints: BoxConstraints(
        minWidth: widget.expand ? 0 : widget.minWidth,
      ),
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
          child: widget.expand
              ? SizedBox(width: double.infinity, child: sized)
              : sized,
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
                : (_hover
                      ? XV.panel3.withValues(alpha: 0.45)
                      : Colors.transparent),
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
                  Icon(
                    widget.icon,
                    size: 16,
                    color: active ? XV.green : XV.muted,
                  ),
                  const SizedBox(width: 11),
                  Text(
                    widget.label,
                    style: active ? XvText.navLabelActive : XvText.navLabel,
                  ),
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
        color: active
            ? XV.green.withValues(alpha: 0.09)
            : XV.muted.withValues(alpha: 0.08),
        border: Border.all(
          color: active ? XV.green.withValues(alpha: 0.22) : XV.line,
        ),
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
                  ? <BoxShadow>[
                      BoxShadow(color: dot, blurRadius: 8, spreadRadius: 0),
                    ]
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
  const MobileHeader({
    super.key,
    required this.title,
    this.statusLabel,
    this.statusActive = false,
  });

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
        style: TextStyle(
          fontSize: 13,
          color: XV.muted,
          fontFamilyFallback: XV.monoFallback,
        ),
      ),
    );
  }
}

/// 搜索框：原型中的 .search
/// 控件的统一尺寸基准。
///
/// 分量式控件（输入框、按钮、分段选择器、下拉等）必须共用同一套高度，
/// 否则一行里摆在一起就会参差不齐。这不是审美问题：实测「手工指定」那一行
/// 曾经是**输入框 41px、按钮 36px、分段选择器 32px**三种高度，看起来像三套
/// 互不相干的控件被硬凑在一行。
///
/// 那个 41px 也不是谁定的，而是 `TextField` 在当前字号下的自然高度——
/// 也就是说「高度」此前根本没有被决定过，只是各处内容恰好撑出多少算多少。
/// 这里把它显式定成一个常量，所有分量式控件都必须落在同一个高度上。
class XvControlMetrics {
  XvControlMetrics._();

  /// 分量式控件的标准高度。
  ///
  /// 36 是原按钮高度：它本就是这套界面里出现最多、也最像「规范」的值
  /// （`XvButton` 的默认 height 与 minWidth 都围绕它），因此以它为准，
  /// 让输入框向它看齐，而不是反过来把按钮撑到 41。
  static const double height = 36;
}

/// 输入类控件底色（搜索框、计时条、分段控件）的统一容器。
///
/// 存在的意义是把「高度」这件事收口：[TextField] 的自然高度随字号与行高变化，
/// 各个调用点各写各的内边距，最终高度就取决于内容碰巧撑出多少。
/// 这里统一用 [XvControlMetrics.height] 约束，保证同类控件永远等高。
class XvControlBox extends StatelessWidget {
  const XvControlBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.highlighted = false,
  });

  /// 通常是一个横向排列的 Row（图标 + 输入框 / 按钮内容）。
  final Widget child;

  final EdgeInsetsGeometry padding;

  /// 聚焦态描边（输入框用）。
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: XvControlMetrics.height,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: XV.field,
          border: Border.all(
            color: highlighted ? XV.green.withValues(alpha: 0.45) : XV.line,
          ),
          borderRadius: BorderRadius.circular(XV.rCtl),
        ),
        // 纵向居中：高度被定死之后，不同的内容高度不会让它们在框内上下偏移。
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );
  }
}

/// 搜索框 / 文本输入框。
class XvSearchField extends StatelessWidget {
  const XvSearchField({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.onClear,
    this.focused = false,
  });

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;

  /// 非空时在右侧显示一个清除按钮。
  ///
  /// 搜索框默认没有回退入口：用户打完字想恢复完整列表，只能一个个删。
  /// 记录多达几百条时，这个缺口会让人以为「记录丢了」。
  final VoidCallback? onClear;

  /// 聚焦态：描边提亮。
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return XvControlBox(
      highlighted: focused,
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
                // 高度已由 XvControlBox 定死，这里不再用纵向内边距去撑。
                contentPadding: EdgeInsets.zero,
                hintText: hint,
                hintStyle: TextStyle(fontSize: 12.5, color: XV.muted2),
              ),
            ),
          ),
          if (onClear != null) TapAction(label: '清除', onTap: onClear!),
        ],
      ),
    );
  }
}

/// 导入动作入口。
///
/// 「配置」模块有两条导入路径（选文件、手动填写），它们此前散落在三处、
/// 权重也各不相同：页面右上角一个按钮、空状态里一个按钮加一行弱化文字、
/// 已有配置时又变成卡片底部两行不对齐的文字链。同一个「把配置弄进来」的
/// 动作，位置和分量都在变，读起来就是「布局割裂」。
///
/// 这个组件把一条路径固定成一个**同规格的入口**：图标 + 主标题 + 说明，
/// 整块可点，三种状态（空列表 / 已有列表 / 移动端）复用同一套观感，
/// 因此路径之间的关系一眼可读，而不是靠猜哪一行能点。
class ImportActionTile extends StatefulWidget {
  const ImportActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  /// 主路径用品牌绿描边强调（一行里只应有一个）。
  final bool primary;

  @override
  State<ImportActionTile> createState() => _ImportActionTileState();
}

class _ImportActionTileState extends State<ImportActionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.primary ? XV.green : XV.muted;
    final border = widget.primary
        ? XV.green.withValues(alpha: _hover ? 0.45 : 0.28)
        : (_hover ? XV.line : XV.line2);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          decoration: BoxDecoration(
            color: _hover
                ? Color.alphaBlend(XV.hoverOverlay, XV.field)
                : XV.field,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          // 图标与文字顶部对齐：说明可能换行，居中会让图标「浮」在两行文字中间。
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(widget.icon, size: 17, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      style: XvText.body.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(widget.description, style: XvText.rowDesc),
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

/// 统一的确认弹窗。
///
/// 删除配置、删除规则集、删除域名规则、恢复内置规则都是不可逆或影响较大的动作，
/// 每处各写一遍 `showDialog` + `Dialog` 会让圆角、间距、按钮顺序慢慢分叉。
/// 这里把它们收成一份：调用方只给标题、正文与确认按钮文案。
class XvConfirmDialog extends StatelessWidget {
  const XvConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.danger = false,
  });

  final String title;
  final String message;
  final String confirmLabel;

  /// 危险动作用红色确认按钮（删除类）。
  final bool danger;

  /// 弹窗并等待用户选择。返回 true 表示确认。
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) => XvConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        danger: danger,
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: XV.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XV.rCard),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: XV.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(message, style: XvText.caption),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  XvButton(
                    label: '取消',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 10),
                  XvButton(
                    label: confirmLabel,
                    kind: danger
                        ? XvButtonKind.danger
                        : XvButtonKind.primary,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    this.badge,
  });

  final String title;
  final String description;
  final Widget control;
  final bool isLast;

  /// 控制区固定宽度，用于让多行的分段控件左边缘对齐。
  final double? controlWidth;

  /// 标题上方的标记（如「有新版本」「下载失败」）。为 null 时不占位。
  ///
  /// 存在的理由：有些设置项的**状态**比标题更重要，而把它写进 [title] 会让标题
  /// 随状态变化（今天是「当前版本」，明天是「下载失败」），一列设置项读起来就
  /// 不再是同一件事。标记单独一行，标题保持稳定。
  final Widget? badge;

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
                if (badge != null) ...<Widget>[
                  badge!,
                  const SizedBox(height: 7),
                ],
                Text(title, style: XvText.rowTitle),
                const SizedBox(height: 4),
                Text(description, style: XvText.rowDesc),
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (controlWidth != null)
            SizedBox(
              width: controlWidth,
              child: Align(alignment: Alignment.centerRight, child: control),
            )
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
            color: _hover
                ? XV.panel3.withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.radius),
            border: widget.showDivider
                ? Border(
                    bottom: BorderSide(
                      color: _hover ? Colors.transparent : XV.line2,
                    ),
                  )
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
                    Text(
                      title,
                      style: XvText.body.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
