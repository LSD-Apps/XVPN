import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 连接状态圆环。
///
/// 对应原型里的 `.ring`：`conic-gradient(from 200deg, green, #17795A 55%, green)`
/// 加 3px 内边距、外发光、以及 inset 9px 的一圈细描边。
/// Flutter 没有锥形渐变容器，因此用 [SweepGradient] 配合 CustomPainter 绘制。
///
/// [warmup] 为 true 时会叠一圈**流转弧**：内核已就绪、隧道还不能载流量，这期间
/// 界面既不该显示「已连接」（用户会以为能用），也不该只给一句静止的文案——
/// 那样看不出程序在动还是卡住了。流转弧回答的正是「它还在动吗」。
class ConnectRing extends StatefulWidget {
  const ConnectRing({
    super.key,
    required this.size,
    required this.active,
    required this.icon,
    required this.title,
    this.titleStyle,
    this.sublabel,
    this.iconSize,
    this.onTap,
    this.warmup = false,
  });

  final double size;

  /// true 时使用绿色渐变并发光（已连接 / 连接中），false 时为中性灰。
  final bool active;

  final IconData icon;
  final String title;
  final TextStyle? titleStyle;
  final String? sublabel;
  final double? iconSize;
  final VoidCallback? onTap;

  /// 是否处于「隧道正在建立」的预热态。
  final bool warmup;

  // 供卡片复用，避免各处硬编码圆环尺寸。
  static const double desktopSize = 158;
  static const double mobileSize = 176;

  @override
  State<ConnectRing> createState() => _ConnectRingState();
}

class _ConnectRingState extends State<ConnectRing>
    with SingleTickerProviderStateMixin {
  /// 流转弧转一圈的时长。
  ///
  /// 刻意取一个约 1.6 秒的匀速周期，而不是与门控超时等长：匀速循环只表达
  /// 「在动」，不会因为「转完一圈还没连上」而暗示失败——门控最多等 20 秒，
  /// 转十几圈都是正常的。
  static const Duration sweepPeriod = Duration(milliseconds: 1600);

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 必须在 initState 里就建好，**不能**用 `late final` 惰性初始化。
    //
    // 惰性写法有个很隐蔽的坑：非预热态下 controller 一直没被读过，于是
    // 直到 `dispose()` 里才第一次求值——那一刻 Ticker 已经无处可挂，
    // 直接抛「_updateTickerModeNotifier was called after dispose」。
    // widget 建好就被立刻移走（列表刷新、测试里 pump 一次再替换）时必崩。
    _controller = AnimationController(vsync: this, duration: sweepPeriod);
    if (widget.warmup) _controller.repeat();
  }

  @override
  void didUpdateWidget(ConnectRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在预热态转动。连上之后还转会让「已连接」看起来仍不稳定；停掉动画
    // 同时也停掉了每帧重绘，不白耗电。
    if (widget.warmup && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.warmup && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ringColor = widget.active ? XV.green : XV.muted2;
    final size = widget.size;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          widget.icon,
          size: widget.iconSize ?? (size <= 170 ? 32 : 36),
          color: ringColor,
        ),
        SizedBox(height: size <= 170 ? 5 : 7),
        Text(
          widget.title,
          style:
              widget.titleStyle ??
              TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: widget.active ? XV.greenSoft : XV.muted,
              ),
        ),
        if (widget.sublabel != null) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            widget.sublabel!,
            style: TextStyle(
              fontSize: 11,
              color: XV.muted2,
              fontFamilyFallback: XV.monoFallback,
            ),
          ),
        ],
      ],
    );

    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: size,
          height: size,
          // 只有预热态才把动画值接进绘制：其余状态仍然是一次性绘制，
          // 「已连接」下不会因为一个恒为 0 的动画每帧重绘。
          child: widget.warmup
              ? AnimatedBuilder(
                  animation: _controller,
                  builder: (BuildContext context, Widget? child) => CustomPaint(
                    painter: _RingPainter(
                      active: widget.active,
                      sweep: _controller.value,
                    ),
                    child: child,
                  ),
                  child: Center(child: content),
                )
              : CustomPaint(
                  painter: _RingPainter(active: widget.active),
                  child: Center(child: content),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.active, this.sweep});

  final bool active;

  /// 流转弧的进度（0–1）。为 null 表示不绘制流转弧。
  final double? sweep;

  /// 流转弧占圆周的比例。短到能看出在走，长到不至于像进度条。
  static const double _sweepExtentFraction = 0.22;

  /// CSS 的 from 200deg 以 12 点方向为 0、顺时针递增；
  /// Flutter 的 SweepGradient 以 3 点方向为 0。两者相差 90°。
  static const double _cssStartDeg = 200;
  static const double _degToRad = math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2;
    final ringRadius = outerRadius - 1.5;
    final start = -math.pi / 2 + _cssStartDeg * _degToRad;
    final bounds = Rect.fromCircle(center: center, radius: outerRadius);

    final stops = <double>[0.0, 0.55, 1.0];
    final baseColors = active
        ? <Color>[XV.green, XV.greenDeep, XV.green]
        : <Color>[XV.ringOffA, XV.ringOffB, XV.ringOffA];

    SweepGradient gradientWith(double alpha) => SweepGradient(
      startAngle: start,
      endAngle: start + math.pi * 2,
      colors: baseColors
          .map((c) => c.withValues(alpha: alpha))
          .toList(growable: false),
      stops: stops,
    );

    // 1. 外发光：对应 box-shadow: 0 0 46px -8px rgba(46,230,168,.35)
    if (active) {
      canvas.drawCircle(
        center,
        ringRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..shader = gradientWith(0.35).createShader(bounds)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
      );
    }

    // 2. 环体：3px 渐变描边
    canvas.drawCircle(
      center,
      ringRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..shader = gradientWith(1).createShader(bounds),
    );

    // 2b. 流转弧：叠在环体上，沿圆周匀速前进。
    final sweepValue = sweep;
    if (sweepValue != null) {
      _paintSweepArc(canvas, center, ringRadius, sweepValue);
    }

    // 3. 内圆底色
    final innerRadius = outerRadius - 3;
    canvas.drawCircle(center, innerRadius, Paint()..color = XV.ringInner);

    // 4. 内圆径向高光：radial-gradient(circle at 50% 42%, rgba(46,230,168,.16), transparent 62%)
    final glowColor = active ? XV.green : XV.blue;
    canvas.drawCircle(
      center,
      innerRadius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.16),
          radius: 0.62,
          colors: <Color>[
            glowColor.withValues(alpha: active ? 0.16 : 0.06),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: innerRadius)),
    );

    // 5. inset 9px 的细描边
    canvas.drawCircle(
      center,
      outerRadius - 9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = (active ? XV.green : XV.line).withValues(
          alpha: active ? 0.16 : 0.9,
        ),
    );
  }

  /// 画一段沿圆周前进的流转弧：尾巴透明、头部明亮，并带一层柔光。
  ///
  /// 用多段短弧拼出渐变，而不是拿 [SweepGradient] 画整圈：渐变只能铺满整圆，
  /// 而这里需要的是**一段**在圆周上移动的高亮，且两端要淡出。
  void _paintSweepArc(
    Canvas canvas,
    Offset center,
    double radius,
    double progress,
  ) {
    final fullCircle = math.pi * 2;
    final extent = fullCircle * _sweepExtentFraction;
    // 从 12 点方向起转，与环体自身的视觉起始方向保持一致。
    final headAngle = -math.pi / 2 + fullCircle * progress;

    const segments = 18;
    final step = extent / segments;
    for (var i = 0; i < segments; i++) {
      // t: 0 是尾巴末端（最淡），1 是头部（最亮）。
      final t = (i + 1) / segments;
      final alpha = math.pow(t, 2.2).toDouble() * 0.9;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        headAngle - extent + step * i,
        // 每段多画一点，避免段与段之间出现发丝般的缝。
        step * 1.35,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.6 + 1.6 * t
          ..color = XV.green.withValues(alpha: alpha),
      );
    }

    // 头部柔光：让「现在走到哪」一眼可见，而不是一段静止的亮弧。
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      headAngle - step * 1.6,
      step * 2.4,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 6
        ..color = XV.green.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.active != active || old.sweep != sweep;
}
