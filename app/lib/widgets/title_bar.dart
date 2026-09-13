import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/links.dart';
import '../core/update_center.dart';
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
  const XvTitleBar({
    super.key,
    required this.theme,
    required this.state,
    this.openExternalUrl = launchInBrowser,
    this.updateCenter,
    this.onOpenUpdate,
  });

  final ThemeController theme;
  final AppState state;

  /// 打开外部链接的实现。
  ///
  /// 默认是真实的系统浏览器；测试注入替身来断言「点了哪个地址」——
  /// 测试环境里没有浏览器，真调用只会失败，无法验证行为。
  final ExternalUrlLauncher openExternalUrl;

  /// 更新提示的共享结果。为 null 时用全局 [UpdateCenter.instance]。
  ///
  /// 标题栏只读它来决定要不要显示指示器，自己不做任何检查。
  final UpdateCenter? updateCenter;

  /// 点击更新指示器时跳转到更新界面。
  ///
  /// 标题栏不拥有导航（桌面端由 [XvShell] 控制分页），因此这里只回调，
  /// 由外壳切到设置页。
  final VoidCallback? onOpenUpdate;

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
          // Wayland 下原生保留装饰且不保证可编程拖动，这里会自动只渲染品牌、
          // 不装拖动监听器（见 _DragRegion.enabled）。
          Expanded(
            child: _DragRegion(
              enabled: WindowControls.supported,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: _Brand(),
              ),
            ),
          ),
          _ConnectionTimer(state: state),
          const SizedBox(width: 10),
          // 更新指示器排在计时与主题按钮之间：它属于应用自身功能，
          // 且与右侧的窗口控制区隔了一道分割线，不会被误当成系统按钮。
          _UpdateIndicator(
            center: updateCenter ?? UpdateCenter.instance,
            onOpenUpdate: onOpenUpdate,
          ),
          _ThemeButton(theme: theme),
          const SizedBox(width: 4),
          // GitHub 入口排在主题按钮之后、分割线之前：分割线右侧是窗口按钮，
          // 左侧是应用自身的功能。放在这里既贴近主题按钮，又不会被当成窗口控制。
          _GitHubButton(open: openExternalUrl),
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

/// 拖动区：按下即把拖动交回系统（Windows：ReleaseCapture + WM_NCLBUTTONDOWN；
/// Linux X11：gtk_window_begin_move_drag）。
class _DragRegion extends StatelessWidget {
  const _DragRegion({required this.child, this.enabled = true});

  final Widget child;

  /// 是否把按下事件交回原生去拖动窗口。
  ///
  /// Wayland 下原生保留装饰、且不保证可编程拖动，[WindowControls.supported]
  /// 为 false，此时只渲染内容、不装监听器——否则用户会按到一片没有任何反应
  /// 的区域，看起来像界面卡死。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final content = Align(alignment: Alignment.centerLeft, child: child);
    if (!enabled) return content;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => WindowControls.startDragging(),
      child: MouseRegion(cursor: SystemMouseCursors.basic, child: content),
    );
  }
}

/// 品牌区：图标 + 名称，只在标题栏出现。
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => const XvBrandMark();
}

/// 有可用更新时出现在标题栏的提示入口。
///
/// 只在启动检查真的发现了新版本、且用户尚未忽略时渲染；其余时刻返回
/// [SizedBox.shrink]，标题栏与没有这个功能时完全一致。点击由外壳切到设置页的
/// 「版本更新」卡片（标题栏不拥有导航）。
///
/// 样式与 [_ThemeButton] / [_GitHubButton] 一致（悬停底色、同一个圆角、同一套
/// [Tooltip]），并且位于 [_DragRegion] 之外——否则点击会被当成拖动标题栏。
class _UpdateIndicator extends StatefulWidget {
  const _UpdateIndicator({required this.center, this.onOpenUpdate});

  final UpdateCenter center;
  final VoidCallback? onOpenUpdate;

  @override
  State<_UpdateIndicator> createState() => _UpdateIndicatorState();
}

class _UpdateIndicatorState extends State<_UpdateIndicator> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateNotice?>(
      valueListenable: widget.center.notice,
      builder: (BuildContext context, UpdateNotice? notice, Widget? _) {
        if (notice == null || notice.dismissed) {
          return const SizedBox.shrink();
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Tooltip(
              message: '发现新版本 v${notice.version}，点击查看',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onOpenUpdate,
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
                        Icon(
                          Icons.system_update_alt,
                          size: 15,
                          color: XV.green,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '发现新版本',
                          style: TextStyle(fontSize: 12, color: XV.green),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        );
      },
    );
  }
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

/// 开源仓库入口：在系统默认浏览器里打开 GitHub 仓库。
///
/// Material Icons 没有官方 GitHub 标识，这里用通用的 [Icons.code] 表达
/// 「开放源码」；具体地址由 tooltip 说明。样式与 [_ThemeButton] 保持一致：
/// 纯图标、悬停底色、同一个圆角，看起来像标题栏原生的一部分。
class _GitHubButton extends StatefulWidget {
  const _GitHubButton({required this.open});

  /// 打开链接的实现，由 [XvTitleBar] 注入。
  final ExternalUrlLauncher open;

  @override
  State<_GitHubButton> createState() => _GitHubButtonState();
}

class _GitHubButtonState extends State<_GitHubButton> {
  bool _hover = false;

  /// 打开仓库页面。
  ///
  /// 这个按钮只是便利入口，失败绝不能把异常甩到界面上：捕获后提示一句，
  /// 用户仍能自己复制 tooltip 里的地址访问。异步返回前先取 messenger，
  /// 避免跨 await 使用 context。
  Future<void> _open() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool opened;
    try {
      opened = await widget.open(Uri.parse(kRepoUrl));
    } on Object catch (error) {
      // 平台通道缺失、系统没有默认浏览器……都归为「没打开」。
      debugPrint('打开仓库链接失败：$error');
      opened = false;
    }
    if (opened || !mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '无法打开浏览器，请手动访问 $kRepoUrl',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XV.rCtl),
          side: BorderSide(color: XV.red.withValues(alpha: 0.35)),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '在 GitHub 上查看源码',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: _hover ? XV.panel3 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SizedBox(
              width: 15,
              height: 15,
              child: CustomPaint(painter: _GitHubMarkPainter(XV.muted)),
            ),
          ),
        ),
      ),
    );
  }
}

/// GitHub 标记（官方 octicon 的 `mark-github`，MIT 许可）。
///
/// 为什么不直接用 `Icons.code`：那是通用的代码符号，和 GitHub 没有关系；
/// 用户看到的是一个「代码」图标，认不出这是仓库入口。
///
/// 为什么不引入图标字体包（如 font_awesome_flutter）：那会为一个图标新增一个
/// 依赖，而本项目对「非必要依赖」一向是拒绝的（例如为了不加 `crypto`，SHA-256
/// 是自己实现的）。这里沿用与窗口按钮同一套做法——自绘。
///
/// 路径由脚本从 SVG path 数据换算生成（含椭圆弧 → 三次贝塞尔的标准转换），
/// 不是手抄的：那段路径是压缩过的，含相对命令与隐式重复，手工转写极易出错。
/// 坐标系是 16×16 的视口。
/// 构建 GitHub 标记的路径（16×16 视口）。
///
/// 数据取自官方的 octicon `mark-github-16`：
/// `https://raw.githubusercontent.com/primer/octicons/main/icons/mark-github-16.svg`
/// （MIT）。由脚本从该 SVG 的 `d` 属性直接换算成 Flutter 的 Path 调用，**没有手抄**：
/// 这段路径是压缩过的，含相对命令与隐式重复，凭记忆或手写都会出错——实际上第一版
/// 就是照记忆写的，结果画出来是个空心的环（已用光栅化对照发现并纠正）。
///
/// 单独作为顶层函数暴露，是为了让测试能直接断言**形状**：椭圆弧换算或任何一段
/// 控制点写错，图标都会歪掉，而那从代码上完全看不出来。
@visibleForTesting
Path buildGitHubMarkPath() {
  final path = Path();
  path.moveTo(6.766, 11.328);
  path.cubicTo(4.703, 11.078, 3.25, 9.594, 3.25, 7.672);
  path.cubicTo(3.25, 6.891, 3.531, 6.047, 4, 5.484);
  path.cubicTo(3.797, 4.969, 3.828, 3.875, 4.063, 3.422);
  path.cubicTo(4.688, 3.344, 5.531, 3.672, 6.031, 4.125);
  path.cubicTo(6.625, 3.938, 7.25, 3.844, 8.016, 3.844);
  path.cubicTo(8.781, 3.844, 9.406, 3.938, 9.969, 4.109);
  path.cubicTo(10.453, 3.672, 11.313, 3.344, 11.938, 3.422);
  path.cubicTo(12.156, 3.844, 12.188, 4.937, 11.984, 5.469);
  path.cubicTo(12.484, 6.062, 12.75, 6.859, 12.75, 7.672);
  path.cubicTo(12.75, 9.594, 11.297, 11.047, 9.203, 11.312);
  path.cubicTo(9.734, 11.656, 10.093, 12.406, 10.093, 13.266);
  path.lineTo(10.093, 14.891);
  path.cubicTo(10.093, 15.359, 10.484, 15.625, 10.953, 15.438);
  path.cubicTo(13.781, 14.359, 16, 11.53, 16, 8.03);
  path.cubicTo(16, 3.61, 12.406, 0, 7.984, 0);
  path.cubicTo(3.563, 0, 0, 3.61, 0, 8.031);
  path.cubicTo(-0.009, 11.347, 2.058, 14.314, 5.172, 15.453);
  path.cubicTo(5.594, 15.609, 6, 15.328, 6, 14.906);
  path.lineTo(6, 13.656);
  path.cubicTo(5.781, 13.75, 5.5, 13.812, 5.25, 13.812);
  path.cubicTo(4.219, 13.812, 3.61, 13.25, 3.172, 12.203);
  path.cubicTo(3, 11.781, 2.812, 11.531, 2.453, 11.484);
  path.cubicTo(2.266, 11.469, 2.203, 11.391, 2.203, 11.297);
  path.cubicTo(2.203, 11.109, 2.516, 10.969, 2.828, 10.969);
  path.cubicTo(3.281, 10.969, 3.672, 11.25, 4.078, 11.829);
  path.cubicTo(4.391, 12.281, 4.718, 12.484, 5.109, 12.484);
  path.cubicTo(5.5, 12.484, 5.75, 12.344, 6.109, 11.984);
  path.cubicTo(6.375, 11.719, 6.579, 11.484, 6.766, 11.328);
  path.close();
  return path;
}

/// 只构建一次；顶层 final 由 Dart 惰性初始化。
final Path _githubMarkPath = buildGitHubMarkPath();

/// 把 16×16 视口里的 GitHub 标记缩放到给定尺寸后填充。
class _GitHubMarkPainter extends CustomPainter {
  const _GitHubMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true
      ..style = PaintingStyle.fill;
    canvas.save();
    // 等比缩放并居中：调用方给的是正方形，这里仍按短边算，避免非正方形时被拉扁。
    final scale = size.shortestSide / 16.0;
    canvas.translate(
      (size.width - 16 * scale) / 2,
      (size.height - 16 * scale) / 2,
    );
    canvas.scale(scale);
    canvas.drawPath(_githubMarkPath, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GitHubMarkPainter old) => old.color != color;
}

/// 最小化 / 最大化 / 关闭。图标为自绘，比默认图标更粗更大，便于点击辨认。
class _WindowButtons extends StatelessWidget {
  const _WindowButtons();

  @override
  Widget build(BuildContext context) {
    if (!WindowControls.supported) return const SizedBox.shrink();
    // 状态取自原生推送的 notifier，而不是本组件自己查一次记住。
    //
    // 自己记住的话，只有「点这个按钮」这条路径能刷新；双击标题栏、Win+↑、
    // 贴边这些由系统直接处理的最大化，界面收不到通知，图标就会停在旧状态上
    // ——窗口都最大化了，按钮还画着「最大化」的方框。
    return ValueListenableBuilder<bool>(
      valueListenable: WindowControls.maximized,
      builder: (BuildContext context, bool maximized, Widget? _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _WindowButton(
            glyph: WindowGlyph.minimize,
            onTap: WindowControls.minimize,
            tooltip: '最小化',
          ),
          _WindowButton(
            glyph: maximized ? WindowGlyph.restore : WindowGlyph.maximize,
            onTap: WindowControls.toggleMaximize,
            tooltip: maximized ? '还原' : '最大化',
          ),
          _WindowButton(
            glyph: WindowGlyph.close,
            onTap: WindowControls.close,
            tooltip: '关闭',
            danger: true,
          ),
        ],
      ),
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
        // Windows 的「还原」是**两个错位交叠的方框**：后面那个只露出未被前面
        // 遮住的部分（上边与右边），前面那个完整描边。
        //
        // 上一版画的是两个**完整**的方框、只把后面那个调淡到 55%，看起来像
        // 「两张纸叠在一起」，与系统按钮不是同一个图形——那是把透明度当成了
        // 层次，而正确做法是**把后面那个方框裁掉被前面遮住的部分**。
        const double offset = 3;
        const double side = 9;
        const double radius = 1.5;

        // 前面那个（左下）
        final front = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            center.dx - side / 2 - offset / 2,
            center.dy - side / 2 + offset / 2,
            side,
            side,
          ),
          const Radius.circular(radius),
        );
        // 后面那个（右上）
        final back = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            center.dx - side / 2 + offset / 2,
            center.dy - side / 2 - offset / 2,
            side,
            side,
          ),
          const Radius.circular(radius),
        );

        canvas.save();
        canvas.clipPath(
          Path.combine(
            PathOperation.difference,
            Path()..addRect(back.outerRect.inflate(2)),
            Path()..addRRect(front),
          ),
          doAntiAlias: true,
        );
        canvas.drawRRect(back, paint);
        canvas.restore();

        // 前面那个压在后面之上，两条边因此交汇干净。
        canvas.drawRRect(front, paint);
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
  bool shouldRepaint(_WindowGlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
