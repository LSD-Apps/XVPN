import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/window_controls.dart';
import '../models.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../version.dart';
import '../widgets/common.dart';
import '../widgets/title_bar.dart';
import '../widgets/window_frame.dart';
import 'connect_screen.dart';
import 'profiles_screen.dart';
import 'settings_screen.dart';
import 'split_screen.dart';

/// 自适应外壳：宽度 >= 900 用侧边导航（桌面端），否则用底部标签栏（移动端）。
/// 两种布局共用同一批屏幕，保证体验一致。
class XvShell extends StatefulWidget {
  const XvShell({super.key, required this.state, required this.theme});

  final AppState state;
  final ThemeController theme;

  @override
  State<XvShell> createState() => _XvShellState();
}

class _XvShellState extends State<XvShell> {
  /// 桌面端：0 连接 / 1 分流记录 / 2 配置文件 / 3 设置
  int _desktopTab = 0;

  /// 移动端：0 连接 / 1 分流 / 2 设置（配置文件并入设置页，与原型一致）
  int _mobileTab = 0;

  String? _shownError;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  /// 用 SnackBar 呈现导入失败等错误，错误文本直接来自解析器，面向用户可读。
  void _onStateChanged() {
    final error = widget.state.lastError;
    if (error == null || error == _shownError) return;
    _shownError = error;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(error, style: TextStyle(fontSize: 12.5, color: XV.text)),
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
    widget.state.dismissError();
    _shownError = null;
  }

  @override
  Widget build(BuildContext context) {
    // 同时监听业务状态与主题：设置页改了主题后，标题栏上的标签必须立刻跟着变，
    // 不能依赖外层恰好重建了本 widget。
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.state, widget.theme]),
      builder: (BuildContext context, _) {
        return Scaffold(
          backgroundColor: XV.bg,
          // 桌面端无边框窗口：外圈一圈极细的描边让窗口边界清晰可辨，
          // 四周的缩放热区由 WindowFrame 提供。
          body: WindowFrame(
            child: DecoratedBox(
              decoration: WindowControls.supported
                  ? BoxDecoration(border: Border.all(color: XV.line))
                  : const BoxDecoration(),
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final desktop =
                        constraints.maxWidth >= XV.desktopBreakpoint;
                    return desktop ? _buildDesktop() : _buildMobile();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------- 桌面端布局

  Widget _buildDesktop() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 自绘标题栏：与侧边栏同色且没有底部分割线，两者因此连成一体。
        // 品牌与运行计时只在这里出现，侧边栏不再重复。
        XvTitleBar(theme: widget.theme, state: widget.state),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildSidebar(),
              Expanded(
                // 分割线只画在内容区顶部：侧边栏上方保持贯通，
                // 视觉上标题栏就是侧边栏向上延伸出来的一条。
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: XV.line)),
                  ),
                  child: Padding(
                    // 内容自适应可用宽度：此前这里有一个 1180 的宽度上限并居中，
                    // 在宽屏上两侧留下大片空白，而卡片里的表格、日志、失败列表
                    // 恰恰需要宽度。去掉上限后由 Padding 只保留必要的边距。
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
                    child: _screenFor(_desktopTab, compact: false),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    const items = <({IconData icon, String label})>[
      (icon: Icons.power_settings_new, label: '连接'),
      (icon: Icons.segment, label: '分流记录'),
      (icon: Icons.description_outlined, label: '配置文件'),
      (icon: Icons.settings_outlined, label: '设置'),
    ];
    final status = widget.state.status;

    return Container(
      width: 196,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: BoxDecoration(
        color: XV.sidebar,
        border: Border(right: BorderSide(color: XV.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: NavItem(
                icon: items[i].icon,
                label: items[i].label,
                active: _desktopTab == i,
                onTap: () => setState(() => _desktopTab = i),
              ),
            ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: XV.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 这里原本是一个「已连接」胶囊。连接状态与时长的信息标题栏
                // 已经给全了，重复一遍纯属噪音；换成用户真正感知不到的
                // 连接质量指标：延迟与失败次数。
                if (status == VpnStatus.connected) ...<Widget>[
                  _QualityRow(
                    icon: Icons.speed_outlined,
                    label: '延迟',
                    value: widget.state.latencyMs == null
                        ? '测量中'
                        : '${widget.state.latencyMs} ms',
                    warn: widget.state.latencyMs == null,
                  ),
                  const SizedBox(height: 7),
                  _QualityRow(
                    icon: Icons.report_gmailerrorred_outlined,
                    label: '连接失败',
                    value: '${widget.state.failures.length} 次',
                    warn: widget.state.failures.isNotEmpty,
                  ),
                  const SizedBox(height: 11),
                ],
                Text(
                  // 版本号来自 version.dart（构建期注入，回落到与 pubspec 同步的
                  // 常量）。这里此前硬编码 'v0.1.0'，与 pubspec 的 1.0.0 不一致。
                  'v$appVersion · ${switch (defaultTargetPlatform) {
                    TargetPlatform.windows => 'Windows',
                    TargetPlatform.android => 'Android',
                    TargetPlatform.iOS => 'iOS',
                    TargetPlatform.macOS => 'macOS',
                    TargetPlatform.linux => 'Linux',
                    TargetPlatform.fuchsia => 'Fuchsia',
                  }}',
                  style: TextStyle(fontSize: 10.5, color: XV.muted2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 移动端布局

  static const _mobileTabs = <({IconData icon, String label, int desktopTab})>[
    (icon: Icons.power_settings_new, label: '连接', desktopTab: 0),
    (icon: Icons.segment, label: '分流', desktopTab: 1),
    (icon: Icons.settings_outlined, label: '设置', desktopTab: 3),
  ];

  Widget _buildMobile() {
    final currentDesktopTab = _mobileTabs[_mobileTab].desktopTab;
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
            child: _screenFor(currentDesktopTab, compact: true),
          ),
        ),
        Container(
          height: 62,
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: XV.sidebar,
            border: Border(top: BorderSide(color: XV.line)),
          ),
          child: Row(
            children: <Widget>[
              for (var i = 0; i < _mobileTabs.length; i++)
                Expanded(child: _buildMobileTab(i)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobileTab(int index) {
    final tab = _mobileTabs[index];
    final active = _mobileTab == index;
    final color = active ? XV.green : XV.muted2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _mobileTab = index),
        child: Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(tab.icon, size: 16, color: color),
              const SizedBox(height: 5),
              Text(tab.label, style: TextStyle(fontSize: 10.5, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 屏幕分发

  Widget _screenFor(int tab, {required bool compact}) {
    return switch (tab) {
      0 => ConnectScreen(state: widget.state, compact: compact),
      1 => SplitScreen(state: widget.state, compact: compact),
      2 => ProfilesScreen(state: widget.state, embedded: compact),
      _ => SettingsScreen(
        state: widget.state,
        compact: compact,
        theme: widget.theme,
      ),
    };
  }
}

/// 侧栏底部的一行质量指标。
///
/// 用户判断「这节点还能不能用」靠的就是延迟与失败次数这两个数字，
/// 而它们恰恰是界面上原来完全没有的信息。异常时用琥珀色标出，
/// 正常时保持低调，不抢主界面的注意力。
class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.icon,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final accent = warn ? XV.amber : XV.muted;
    return Row(
      children: <Widget>[
        Icon(icon, size: 13, color: accent),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 11, color: XV.muted2)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: warn ? FontWeight.w600 : FontWeight.w500,
            color: warn ? XV.amberSoft : XV.muted,
            fontFamilyFallback: XV.monoFallback,
          ),
        ),
      ],
    );
  }
}
