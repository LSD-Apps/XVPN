import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/auto_route.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 「自动纠正」管理卡片。
///
/// 这一块存在的理由是**透明度**：程序会在背后把某些域名改成走隧道，
/// 如果不把这件事摆出来，用户遇到「有时候能连有时候不能」时无从下手，
/// 更没法撤销一个判断错的规则。
///
/// 因此它做三件事：
///   1. 说明白程序学到了什么、为什么（证据来自哪里）；
///   2. 给出撤销入口——用户永远有最终否决权；
///   3. 允许手工指定某个域名走代理或直连，作为自动判断的兜底。
class AutoRouteCard extends StatefulWidget {
  const AutoRouteCard({super.key, required this.state, required this.compact});

  final AppState state;
  final bool compact;

  /// 输入框应保证的最小宽度。
  ///
  /// 200 是按最长的常见输入估的：`Blocked.Example.COM:443` 这类内容在 12.5px
  /// 字号下约 170px，再留一点余量，用户至少能看到自己漏没漏字符。
  ///
  /// 注意这里量的是**输入框容器**（[XvSearchField]）的宽度，而不是它内部
  /// [TextField] 的宽度：后者还要减去容器左右各 12px 的内边距与 14px 的搜索
  /// 图标，比容器窄约 48px。断言时别量错对象。
  ///
  /// 放在 widget 上而不是 State 里：它是这个组件的**布局契约**，
  /// 测试要据此断言「输入框没被三栏挤压」，因此必须对外可见。
  static const double minInputWidth = 200;

  /// 「走代理 / 直连」选择器的自然宽度。
  ///
  /// 125.25 是在测试里实测出来的（两个标签各 60.5px 文字 + 28px 内边距，
  /// 加上外层 3px 内边距与 1px 描边）。写实测值而不是估一个，是因为这个数
  /// 直接决定换行阈值：估大了会在本可以并排的宽度上提前换行。
  static const double segmentedWidth = 126;

  /// 「添加」按钮的宽度（[XvButton] 的 minWidth 默认值）。
  static const double buttonWidth = 88;

  /// 三栏排布所需的最小内容宽度。
  static const double rowLayoutBreakpoint =
      minInputWidth + segmentedWidth + buttonWidth + 16;

  @override
  State<AutoRouteCard> createState() => _AutoRouteCardState();
}

class _AutoRouteCardState extends State<AutoRouteCard> {
  final TextEditingController _domainController = TextEditingController();
  RoutePreference _preference = RoutePreference.forceProxy;
  String? _inputError;

  AppState get state => widget.state;

  @override
  void dispose() {
    _domainController.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _domainController.text.trim();
    final domain = AutoRouteTable.normalizeDomain(raw);
    if (domain.isEmpty) {
      setState(() {
        _inputError = raw.isEmpty
            ? '请输入域名'
            : '需要填写域名（例如 example.com）；IP 不参与按域名的分流规则';
      });
      return;
    }
    state.setDomainPreference(domain, _preference);
    _domainController.clear();
    setState(() => _inputError = null);
  }

  @override
  Widget build(BuildContext context) {
    final table = state.autoRoute;

    if (table == null) {
      return XvCard(
        color: widget.compact ? XV.panel2 : XV.panel,
        radius: widget.compact ? 12 : XV.rCard,
        padding: widget.compact
            ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
            : const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const XvCardTitle('自动纠正'),
            Text('当前内核不支持自动纠正（演示模式）', style: XvText.caption),
          ],
        ),
      );
    }

    final entries = table.entries.toList(growable: false)
      ..sort((AutoRouteEntry a, AutoRouteEntry b) {
        // 用户规则在最前，其余按失败次数降序——证据越充分越值得看。
        if (a.source != b.source) {
          return a.source == RouteRuleSource.user ? -1 : 1;
        }
        return b.directFailures.compareTo(a.directFailures);
      });

    return XvCard(
      color: widget.compact ? XV.panel2 : XV.panel,
      radius: widget.compact ? 12 : XV.rCard,
      padding: widget.compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('自动纠正'),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              table.isEmpty
                  ? '程序会观察「判为直连却失败」的连接，连续多次失败后自动把该域名改为走隧道。'
                      '目前还没有需要纠正的域名。'
                  : '已对 ${table.length} 个域名调整了分流。'
                      '这些规则优先于内置规则库——规则库把被墙站点判成直连时，靠它们拉回隧道。',
              style: XvText.caption,
            ),
          ),
          for (final entry in entries) _buildEntry(entry),
          Divider(height: 25, thickness: 1, color: XV.line2),
          Text('手工指定', style: XvText.rowTitle),
          const SizedBox(height: 4),
          Text(
            '对某个域名固定走代理或直连。手工规则永远优先于程序学到的规则。',
            style: XvText.rowDesc,
          ),
          const SizedBox(height: 10),
          _buildManualInput(),
          if (_inputError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _inputError!,
                style: XvText.caption.copyWith(color: XV.amberSoft),
              ),
            ),
          if (entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: <Widget>[
                  TapAction(
                    label: '清理过期（${entries.length} 条中）',
                    onTap: () {
                      final removed = state.pruneAutoRoute();
                      if (!mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          content: Text(
                            removed.isEmpty
                                ? '没有可清理的规则：长期未命中的学习规则会自动淘汰'
                                : '已清理 ${removed.length} 条长期未命中的规则',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 14),
                  TapAction(
                    label: '全部清除',
                    onTap: () {
                      for (final entry in entries) {
                        state.clearAutoRouteRule(entry.domain);
                      }
                    },
                  ),
                ],
              ),
            ),
          // 最近一次自动纠正的原因。把「为什么改」写清楚，
          // 否则用户只看到域名列表，不知道程序依据什么做的判断。
          if (state.learnedDecisions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '最近一次自动纠正：${state.learnedDecisions.first.domain} — '
                '${state.learnedDecisions.first.reason}',
                style: XvText.caption,
              ),
            ),
        ],
      ),
    );
  }

  /// 手工指定域名的输入区。
  ///
  /// 这里有个必须处理的宽度问题：「走代理 / 直连」选择器（约 126px）与
  /// 「添加」按钮（最小 88px）都是定宽的，加上两处 8px 间距一共吃掉约 238px。
  /// 而手机设置页卡片的内容宽度只有 326px 上下（390 屏 − 两侧 18px −
  /// 卡片内边距 28px），三栏并排后留给输入框的只剩 180 上下——
  /// 域名动辄 20 多个字符（`Blocked.Example.COM:443`），窄到看不见内容。
  ///
  /// 因此按可用宽度分成两种排布，**输入框始终占据自己那一行的剩余宽度**：
  ///   * 宽（三栏放得下，见 [rowLayoutBreakpoint]）：三栏一行，与原设计一致；
  ///   * 窄：选择器独占一行并铺满，输入框与「添加」一行。
  ///
  /// 无论哪种排布，输入框容器拿到的宽度都不少于 [minInputWidth]。
  Widget _buildManualInput() {
    final field = XvSearchField(
      hint: '例如 example.com',
      controller: _domainController,
      onChanged: (_) {
        if (_inputError != null) setState(() => _inputError = null);
      },
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 阈值 = 最小输入宽度 + 选择器 + 按钮 + 两处间距。
        const breakpoint = AutoRouteCard.rowLayoutBreakpoint;
        final roomy =
            !constraints.hasBoundedWidth || constraints.maxWidth >= breakpoint;

        if (roomy) {
          // IntrinsicHeight + stretch：让三者在同行内被拉伸到同一高度。
          // 只靠各自的高度常量还不够——输入框、按钮、分段控件的边框与基线
          // 处理略有差异，拉伸一行到齐是最稳的做法，也是「同高」的最终保证。
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 输入框占据全部剩余宽度，定宽控件不参与分配。
                Expanded(child: field),
                const SizedBox(width: 8),
                _buildPreferencePicker(expand: false),
                const SizedBox(width: 8),
                _buildAddButton(),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 选择器铺满整行：它自己的点击热区也变大，比挤在角落更好点。
            _buildPreferencePicker(expand: true),
            const SizedBox(height: 8),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: field),
                  const SizedBox(width: 8),
                  _buildAddButton(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 走向选择器。窄排布下铺满整行。
  ///
  /// 高度统一用 [XvControlMetrics.height]：与输入框、按钮同高。
  /// 分段控件的自然高度是 32（内容 26 + 上下各 3 的内边距），
  /// 不约束的话它比同行的按钮还矮 4px。
  Widget _buildPreferencePicker({required bool expand}) => SizedBox(
        height: XvControlMetrics.height,
        child: XvSegmented(
          labels: const <String>['走代理', '直连'],
          index: _preference == RoutePreference.forceProxy ? 0 : 1,
          expand: expand,
          onChanged: (int i) => setState(() {
            _preference =
                i == 0 ? RoutePreference.forceProxy : RoutePreference.forceDirect;
          }),
        ),
      );

  /// 「添加」按钮。
  ///
  /// 高度不在这里指定：它取自 [XvControlMetrics.height]，与输入框同高。
  /// 原先这里写死 `SizedBox(height: 36)`，而输入框的自然高度是 41（见量测注释），
  /// 于是同一行里按钮比输入框矮 5px——参差就是从这里来的。
  Widget _buildAddButton() => XvButton(label: '添加', onPressed: _submit);

  Widget _buildEntry(AutoRouteEntry entry) {
    final isUser = entry.source == RouteRuleSource.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        entry.domain,
                        style: XvText.bodyMuted.copyWith(color: XV.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (isUser) RouteTag.green('手工') else RouteTag.kind(RouteKind.proxy),
                  ],
                ),
                const SizedBox(height: 3),
                Text(_evidence(entry), style: XvText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TapAction(
            label: '撤销',
            onTap: () => state.clearAutoRouteRule(entry.domain),
          ),
        ],
      ),
    );
  }

  /// 这条规则的证据。用户据此判断「撤销还是留着」。
  static String _evidence(AutoRouteEntry entry) {
    if (entry.source == RouteRuleSource.user) {
      return '手工指定为${entry.preference.label}';
    }
    final parts = <String>[
      '判为直连但失败 ${entry.directFailures} 次',
      if (entry.lastFailureReason != null) entry.lastFailureReason!,
      if (entry.proxiedBytes > 0) '已走隧道 ${(entry.proxiedBytes / 1024).round()} KB',
    ];
    return parts.join(' · ');
  }
}
