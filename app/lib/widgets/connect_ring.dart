import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 连接状态圆环。
///
/// 对应原型里的 `.ring`：`conic-gradient(from 200deg, green, #17795A 55%, green)`
/// 加 3px 内边距、外发光、以及 inset 9px 的一圈细描边。
/// Flutter 没有锥形渐变容器，因此用 [SweepGradient] 配合 CustomPainter 绘制。
class ConnectRing extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final ringColor = active ? XV.green : XV.muted2;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: iconSize ?? (size <= 170 ? 32 : 36), color: ringColor),
        SizedBox(height: size <= 170 ? 5 : 7),
        Text(
          title,
          style: titleStyle ??
              TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? XV.greenSoft : XV.muted,
              ),
        ),
        if (sublabel != null) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            sublabel!,
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
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(active: active),
            child: Center(child: content),
          ),
        ),
      ),
    );
  }

  // 供卡片复用，避免各处硬编码圆环尺寸。
  static const double desktopSize = 158;
  static const double mobileSize = 176;
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.active});

  final bool active;

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
          colors: baseColors.map((c) => c.withValues(alpha: alpha)).toList(growable: false),
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
          colors: <Color>[glowColor.withValues(alpha: active ? 0.16 : 0.06), Colors.transparent],
        ).createShader(Rect.fromCircle(center: center, radius: innerRadius)),
    );

    // 5. inset 9px 的细描边
    canvas.drawCircle(
      center,
      outerRadius - 9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = (active ? XV.green : XV.line).withValues(alpha: active ? 0.16 : 0.9),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.active != active;
}
