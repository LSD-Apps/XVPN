import 'package:flutter/material.dart';

/// 调色板。暗色与亮色两套，字段名完全一致，界面代码只认字段名。
///
/// 设计稿（design/ui-mockup.html）里的 CSS 变量就是暗色这一套。
class XvPalette {
  const XvPalette({
    required this.bg,
    required this.sidebar,
    required this.panel,
    required this.panel2,
    required this.panel3,
    required this.field,
    required this.line,
    required this.line2,
    required this.cardBorder,
    required this.text,
    required this.muted,
    required this.muted2,
    required this.green,
    required this.greenDeep,
    required this.greenSoft,
    required this.violet,
    required this.violetSoft,
    required this.blue,
    required this.blueSoft,
    required this.amber,
    required this.amberSoft,
    required this.red,
    required this.redSoft,
    required this.switchOff,
    required this.knob,
    required this.hoverOverlay,
    required this.ringInner,
    required this.ringOffA,
    required this.ringOffB,
    required this.dotIdle,
    required this.dashIdle,
    required this.radioBorder,
    required this.onAccent,
  });

  // 背景层次
  final Color bg;

  /// 侧边栏与标题栏共用的颜色，两者因此连成一体。
  final Color sidebar;

  final Color panel;
  final Color panel2;
  final Color panel3;

  /// 输入类控件底色（搜索框、计时条、分段控件）
  final Color field;

  // 描边
  final Color line;
  final Color line2;

  /// 卡片描边。刻意比 line 更淡：卡片靠底色分层即可，
  /// 描边太重会让界面变成一堆"条条框框"。
  final Color cardBorder;

  // 文字
  final Color text;
  final Color muted;
  final Color muted2;

  // 语义色
  final Color green;
  final Color greenDeep;

  /// 绿色系文字（用在绿色浅底上）
  final Color greenSoft;

  final Color violet;
  final Color violetSoft;
  final Color blue;
  final Color blueSoft;
  final Color amber;
  final Color amberSoft;
  final Color red;
  final Color redSoft;

  // 组件专用
  final Color switchOff;
  final Color knob;
  final Color hoverOverlay;
  final Color ringInner;
  final Color ringOffA;
  final Color ringOffB;
  final Color dotIdle;
  final Color dashIdle;
  final Color radioBorder;
  final Color onAccent;

  /// 暗色：与 design/ui-mockup.html 的 :root 一一对应。
  static const dark = XvPalette(
    bg: Color(0xFF06080C),
    sidebar: Color(0xFF0E131D),
    panel: Color(0xFF121722),
    panel2: Color(0xFF161C29),
    panel3: Color(0xFF1B2231),
    field: Color(0xFF0E131D),
    line: Color(0xFF232B3A),
    line2: Color(0xFF1B2230),
    cardBorder: Color(0xFF191F2C),
    text: Color(0xFFE7EBF3),
    muted: Color(0xFF8A93A6),
    muted2: Color(0xFF5F6879),
    green: Color(0xFF2EE6A8),
    greenDeep: Color(0xFF17795A),
    greenSoft: Color(0xFF8EF0CD),
    violet: Color(0xFFA274FF),
    violetSoft: Color(0xFFC2A5FF),
    blue: Color(0xFF4C8DFF),
    blueSoft: Color(0xFF8FB6FF),
    amber: Color(0xFFFFB443),
    amberSoft: Color(0xFFFFCD80),
    red: Color(0xFFFF6B6B),
    redSoft: Color(0xFFFF9A9A),
    switchOff: Color(0xFF2A3242),
    knob: Color(0xFFFFFFFF),
    hoverOverlay: Color(0x0FFFFFFF),
    ringInner: Color(0xFF0F1520),
    ringOffA: Color(0xFF3A465E),
    ringOffB: Color(0xFF232B3A),
    dotIdle: Color(0xFF4A5468),
    dashIdle: Color(0xFF2F3A4D),
    radioBorder: Color(0xFF39435A),
    onAccent: Color(0xFF04231A),
  );

  /// 亮色：同一套语义，重新取值。主色仍是绿色，只是压暗以保证浅底对比度。
  static const light = XvPalette(
    bg: Color(0xFFF4F4F7),
    sidebar: Color(0xFFFFFFFF),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFFFFFFF),
    panel3: Color(0xFFECECF2),
    field: Color(0xFFF1F1F6),
    line: Color(0xFFE3E3EB),
    line2: Color(0xFFEFEFF4),
    cardBorder: Color(0xFFE9E9F0),
    text: Color(0xFF17161C),
    muted: Color(0xFF5E5C6A),
    muted2: Color(0xFF8F8C9B),
    green: Color(0xFF0FA97A),
    greenDeep: Color(0xFF0B7A57),
    greenSoft: Color(0xFF0A6B4C),
    violet: Color(0xFF7B4DE0),
    violetSoft: Color(0xFF5B30AE),
    blue: Color(0xFF2F6FDB),
    blueSoft: Color(0xFF1F55B0),
    amber: Color(0xFFB8790A),
    amberSoft: Color(0xFF8A5A00),
    red: Color(0xFFD63A3A),
    redSoft: Color(0xFFA82C2C),
    switchOff: Color(0xFFD3D3DE),
    knob: Color(0xFFFFFFFF),
    hoverOverlay: Color(0x0A000000),
    ringInner: Color(0xFFFFFFFF),
    ringOffA: Color(0xFFC7C7D4),
    ringOffB: Color(0xFFE2E2EA),
    dotIdle: Color(0xFFB9B6C4),
    dashIdle: Color(0xFFC9C6D4),
    radioBorder: Color(0xFFC3C0CE),
    onAccent: Color(0xFFFFFFFF),
  );
}

/// 当前生效的调色板。
///
/// 界面代码统一通过 [XV] 的静态 getter 读取，因此切换主题只需要替换这里的
/// 引用并让界面重建一次，227 处使用点无需改动。
XvPalette _current = XvPalette.dark;

XvPalette get xvPalette => _current;

void applyPalette(XvPalette palette) => _current = palette;

/// 设计变量入口。字段名与 design/ui-mockup.html 的 CSS 变量保持一致。
class XV {
  XV._();

  static Color get bg => _current.bg;
  static Color get sidebar => _current.sidebar;
  static Color get panel => _current.panel;
  static Color get panel2 => _current.panel2;
  static Color get panel3 => _current.panel3;
  static Color get field => _current.field;

  static Color get line => _current.line;
  static Color get line2 => _current.line2;
  static Color get cardBorder => _current.cardBorder;

  static Color get text => _current.text;
  static Color get muted => _current.muted;
  static Color get muted2 => _current.muted2;

  static Color get green => _current.green;
  static Color get greenDeep => _current.greenDeep;
  static Color get greenSoft => _current.greenSoft;
  static Color get violet => _current.violet;
  static Color get violetSoft => _current.violetSoft;
  static Color get blue => _current.blue;
  static Color get blueSoft => _current.blueSoft;
  static Color get amber => _current.amber;
  static Color get amberSoft => _current.amberSoft;
  static Color get red => _current.red;
  static Color get redSoft => _current.redSoft;

  static Color get switchOff => _current.switchOff;
  static Color get knob => _current.knob;
  static Color get hoverOverlay => _current.hoverOverlay;
  static Color get ringInner => _current.ringInner;
  static Color get ringOffA => _current.ringOffA;
  static Color get ringOffB => _current.ringOffB;
  static Color get dotIdle => _current.dotIdle;
  static Color get dashIdle => _current.dashIdle;
  static Color get radioBorder => _current.radioBorder;
  static Color get onAccent => _current.onAccent;

  // 与主题无关的结构常量
  static const rCard = 13.0;
  static const rCtl = 9.0;
  static const rPill = 20.0;

  /// 自绘标题栏高度（桌面端）。原生窗口不再绘制标题栏，由 Flutter 绘制这一条，
  /// 背景与侧边栏同色，因此视觉上连成一体。
  static const titleBarHeight = 46.0;

  /// 桌面端断点：>= 该宽度使用侧边导航，否则使用底部标签栏。
  static const desktopBreakpoint = 900.0;

  static const cjkFallback = <String>[
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'Segoe UI',
  ];

  static const monoFallback = <String>[
    'Cascadia Mono',
    'Consolas',
    'Roboto Mono',
    'monospace',
  ];
}

/// 原型中反复出现的文字样式。因为颜色随主题变化，这里都是 getter。
class XvText {
  XvText._();

  static TextStyle get screenTitle => TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: XV.text,
      );

  static TextStyle get screenSubtitle => TextStyle(fontSize: 12, color: XV.muted2, height: 1.5);

  static TextStyle get heroTitle => TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: XV.text,
      );

  static TextStyle get sectionLabel => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: XV.muted,
      );

  static TextStyle get body => TextStyle(fontSize: 13, color: XV.text, height: 1.5);

  static TextStyle get bodyMuted => TextStyle(fontSize: 12.5, color: XV.muted, height: 1.6);

  static TextStyle get caption => TextStyle(fontSize: 11.5, color: XV.muted2, height: 1.7);

  static TextStyle get mono =>
      TextStyle(fontSize: 12, color: XV.muted, fontFamilyFallback: XV.monoFallback);

  static TextStyle get monoSmall =>
      TextStyle(fontSize: 11.5, color: XV.muted, fontFamilyFallback: XV.monoFallback);

  static TextStyle get statLabel => TextStyle(fontSize: 11.5, color: XV.muted2);

  static TextStyle get statValue => TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.5,
        color: XV.text,
      );

  static TextStyle get statUnit =>
      TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: XV.muted);

  static TextStyle get navLabel => TextStyle(fontSize: 13, color: XV.muted);

  static TextStyle get navLabelActive =>
      TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: XV.text);

  static TextStyle get tag => TextStyle(fontSize: 11, fontWeight: FontWeight.w600);

  static TextStyle get rowTitle => TextStyle(fontSize: 13, color: XV.text);

  static TextStyle get rowDesc => TextStyle(fontSize: 11.5, color: XV.muted2, height: 1.55);
}

/// 组装全局 ThemeData。全部使用调色板取值，不依赖 Material 默认配色。
ThemeData buildXvTheme(XvPalette p) {
  final scheme = ColorScheme(
    brightness: p == XvPalette.dark ? Brightness.dark : Brightness.light,
    primary: p.green,
    onPrimary: p.onAccent,
    secondary: p.violet,
    onSecondary: p.onAccent,
    error: p.red,
    onError: p.onAccent,
    surface: p.bg,
    onSurface: p.text,
    outline: p.line,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    fontFamilyFallback: XV.cjkFallback,
  );

  return base.copyWith(
    dividerColor: p.line,
    iconTheme: IconThemeData(color: p.muted, size: 16),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.green,
      selectionColor: p.green.withValues(alpha: 0.22),
      selectionHandleColor: p.green,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.panel3,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: p.line),
      ),
      textStyle: TextStyle(fontSize: 11.5, color: p.text),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.line),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
  );
}
