import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/auto_route.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 「域名分流规则」管理卡片（原「自动纠正」卡片）。
///
/// 这一块存在的理由是**透明度**：程序会在背后把某些域名改成走隧道，
/// 如果不把这件事摆出来，用户遇到「有时候能连有时候不能」时无从下手，
/// 更没法撤销一个判断错的规则。
///
/// 它把三层规则摆在同一张列表里：
///   1. **默认规则**——未命中任何规则的目标怎么走（由分流模式决定），不可删；
///   2. **程序学到**——从失败证据里自动纠正出来的规则，可编辑（转为手工）与删除；
///   3. **手工指定**——用户明确指定的走向，永远优先于程序学到的。
///
/// 它原本长在设置页，与分流模式、规则库一起搬到了独立的「分流规则」页——
/// 三件事讲的都是「流量怎么走」。
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
            const XvCardTitle('域名分流规则'),
            Text('当前内核不支持域名分流规则（演示模式）', style: XvText.caption),
          ],
        ),
      );
    }

    final user = <AutoRouteEntry>[];
    final learned = <AutoRouteEntry>[];
    final preset = <AutoRouteEntry>[];
    for (final entry in table.entries) {
      switch (entry.source) {
        case RouteRuleSource.user:
          user.add(entry);
        case RouteRuleSource.learned:
          learned.add(entry);
        case RouteRuleSource.preset:
          preset.add(entry);
      }
    }
    // 学到的按失败次数降序——证据越充分越值得先看。
    learned.sort(
      (AutoRouteEntry a, AutoRouteEntry b) =>
          b.directFailures.compareTo(a.directFailures),
    );
    final total = user.length + learned.length + preset.length;

    return XvCard(
      color: widget.compact ? XV.panel2 : XV.panel,
      radius: widget.compact ? 12 : XV.rCard,
      padding: widget.compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('域名分流规则'),
          Text(
            table.isEmpty
                ? '程序会在两个方向上自动纠正分流：观察「判为直连却失败」的连接，'
                      '连续多次失败后改为走隧道；观察走隧道的域名，若它的直连解析'
                      '落在国内网段，则改为直连。目前还没有需要纠正的域名。'
                : '已对 $total 个域名调整了分流。这些规则优先于规则集——规则集把某些'
                      '域名判成直连时靠它们拉回隧道，把能直连的域名判进隧道时靠它们'
                      '拉出来。',
            style: XvText.caption,
          ),
          const SizedBox(height: 14),
          _buildDefaultRule(),
          Divider(height: 25, thickness: 1, color: XV.line2),
          _sectionLabel('程序学到', count: learned.length),
          if (learned.isEmpty)
            Text('还没有程序学到的规则。', style: XvText.rowDesc)
          else
            for (final entry in learned) _buildEntry(entry),
          Divider(height: 25, thickness: 1, color: XV.line2),
          _sectionLabel('手工指定', count: user.length),
          if (user.isEmpty)
            Text('还没有手工指定的域名。可在下面新增一条。', style: XvText.rowDesc)
          else
            for (final entry in user) _buildEntry(entry),
          // 内置白名单单列一组：它由「直连白名单」卡片的开关驱动，
          // 混进「程序学到」会让用户以为那也是程序自己判断出来的。
          if (preset.isNotEmpty) ...<Widget>[
            Divider(height: 25, thickness: 1, color: XV.line2),
            _sectionLabel('内置白名单', count: preset.length),
            Text(
              '由「直连白名单」的开关安装。开关关闭后这些条目会一并移除；'
              '要覆盖某一条，在下面手工新增同名域名即可。',
              style: XvText.caption,
            ),
            for (final entry in preset) _buildEntry(entry),
          ],
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
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: <Widget>[
                  TapAction(
                    label: '清理过期（$total 条中）',
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
                    danger: true,
                    onTap: _confirmClearAll,
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

  Widget _sectionLabel(String text, {int? count}) {
    // 计数单独成一个 Text 而不是拼进标签里：拼进去会让 `手工指定` 变成
    // `手工指定（3）`，任何按文案定位的地方（测试、无障碍）都会找不到它。
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Text(text, style: XvText.rowTitle),
          if (count != null) ...<Widget>[
            const SizedBox(width: 6),
            Text('（$count）', style: XvText.caption),
          ],
        ],
      ),
    );
  }

  /// 默认规则：未命中任何规则的目标怎么走。
  ///
  /// 它不是一个可编辑的条目——它就是内核配置里的 `route.final`，由分流模式
  /// 决定。把它摆出来是为了让「列表里的规则」与「列表外的流量」之间有交代。
  Widget _buildDefaultRule() {
    final mode = state.settings.splitMode;
    final direct = mode == SplitMode.globalDirect;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
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
                        '默认规则',
                        style: XvText.bodyMuted.copyWith(color: XV.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    RouteTag.warn('不可删除'),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  direct
                      ? '未命中以上规则的目标跟随「${mode.label}」直连'
                      : '未命中以上规则的目标跟随「${mode.label}」走隧道',
                  style: XvText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (direct)
            RouteTag.direct('直连')
          else
            RouteTag.kind(RouteKind.proxy, label: '走隧道'),
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
        _preference = i == 0
            ? RoutePreference.forceProxy
            : RoutePreference.forceDirect;
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
    // 内置白名单的条目不给编辑/删除：它是开关的下游产物，删掉也会在下次启动
    // 重新安装（安装时只跳过更高优先级的条目）。要覆盖它就在下面手工新增同名
    // 域名——那条会成为「手工指定」，优先级高于白名单。
    final isPreset = entry.source == RouteRuleSource.preset;
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
                    if (isUser)
                      RouteTag.green('手工')
                    else if (isPreset)
                      RouteTag.green('白名单')
                    else
                      RouteTag.kind(RouteKind.proxy),
                  ],
                ),
                const SizedBox(height: 3),
                Text(_evidence(entry), style: XvText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isPreset) ...<Widget>[
            TapAction(label: '编辑', onTap: () => _editEntry(entry)),
            TapAction(
              label: '删除',
              danger: true,
              onTap: () => _removeEntry(entry),
            ),
          ],
        ],
      ),
    );
  }

  /// 编辑一条规则的走向。
  ///
  /// 程序学到的规则一经编辑就转成「手工指定」——用户表达了明确意图之后，
  /// 继续让程序按证据改写它就是错的。这一步由 [AppState.setDomainPreference]
  /// 的 `setUserRule` 语义保证。
  Future<void> _editEntry(AutoRouteEntry entry) async {
    final preference = await showDialog<RoutePreference>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) => _RuleEditDialog(entry: entry),
    );
    if (preference == null || !mounted) return;
    state.setDomainPreference(entry.domain, preference);
  }

  Future<void> _removeEntry(AutoRouteEntry entry) async {
    final confirmed = await XvConfirmDialog.show(
      context,
      title: '删除域名规则',
      message: '确定删除「${entry.domain}」的分流规则？删除后它按规则集与默认规则'
          '重新判定。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    state.clearAutoRouteRule(entry.domain);
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await XvConfirmDialog.show(
      context,
      title: '清除全部域名规则',
      message: '确定清除全部域名分流规则？程序学到的与手工指定的规则都会被删除，'
          '之后按规则集与默认规则判定。',
      confirmLabel: '全部清除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    // 先取一份快照再删：clearAutoRouteRule 会改动底层表。
    final domains = state.autoRoute!.entries
        .map((AutoRouteEntry e) => e.domain)
        .toList(growable: false);
    for (final domain in domains) {
      state.clearAutoRouteRule(domain);
    }
  }

  /// 这条规则的证据。用户据此判断「撤销还是留着」。
  static String _evidence(AutoRouteEntry entry) {
    switch (entry.source) {
      case RouteRuleSource.user:
        return '手工指定为${entry.preference.label}';
      case RouteRuleSource.preset:
        return '来自「直连白名单」·${entry.preference.label}';
      case RouteRuleSource.learned:
        break;
    }
    // 反方向学到的直连规则：依据是「直连解析落在国内网段」，
    // 与下面那条「判为直连但失败」是完全不同的证据，必须分别说明——
    // 否则界面会显示「判为直连但失败 0 次」这种自相矛盾的理由。
    if (entry.preference == RoutePreference.forceDirect) {
      final parts = <String>[
        '直连解析落在国内网段 ${entry.domesticHits} 次',
        if (entry.lastFailureReason != null) entry.lastFailureReason!,
        if (entry.directSuccesses > 0) '直连已跑出流量 ${entry.directSuccesses} 次',
      ];
      return parts.join(' · ');
    }
    // 两种「没有交付」分开说：连接失败与「握手成功但没有数据」是不同的现象，
    // 而后者原先在归因里完全看不到。只按失败次数显示会得出
    // 「判为直连但失败 0 次」这种自相矛盾的理由。
    final parts = <String>[
      if (entry.directFailures > 0) '判为直连但失败 ${entry.directFailures} 次',
      if (entry.stalls > 0) '握手成功但没有数据 ${entry.stalls} 次',
      // 速率证据单独成句：它**不是失败**（连接成功交付了内容），
      // 只是慢。混进「失败」那句会让界面自相矛盾。
      if (entry.rateNote != null) entry.rateNote!,
      if (entry.lastFailureReason != null) entry.lastFailureReason!,
      if (entry.proxiedBytes > 0)
        '已走隧道 ${(entry.proxiedBytes / 1024).round()} KB',
    ];
    return parts.join(' · ');
  }
}

/// 编辑一条域名规则的走向。
///
/// 返回用户选择的 [RoutePreference]，取消时为 null。
class _RuleEditDialog extends StatefulWidget {
  const _RuleEditDialog({required this.entry});

  final AutoRouteEntry entry;

  @override
  State<_RuleEditDialog> createState() => _RuleEditDialogState();
}

class _RuleEditDialogState extends State<_RuleEditDialog> {
  late RoutePreference _preference = widget.entry.preference;

  @override
  Widget build(BuildContext context) {
    final isLearned = widget.entry.source == RouteRuleSource.learned;
    return Dialog(
      backgroundColor: XV.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XV.rCard),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '编辑域名规则',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: XV.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.entry.domain,
                style: XvText.monoSmall.copyWith(color: XV.text),
              ),
              const SizedBox(height: 4),
              Text(
                isLearned
                    ? '这是程序学到的规则。保存后会转为「手工指定」，'
                          '程序不再按证据改写它。'
                    : '手工指定的规则永远优先于程序学到的规则。',
                style: XvText.caption,
              ),
              const SizedBox(height: 12),
              XvSegmented(
                labels: const <String>['走代理', '直连'],
                index: _preference == RoutePreference.forceProxy ? 0 : 1,
                expand: true,
                onChanged: (int i) => setState(() {
                  _preference = i == 0
                      ? RoutePreference.forceProxy
                      : RoutePreference.forceDirect;
                }),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  XvButton(
                    label: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  XvButton(
                    label: '保存',
                    kind: XvButtonKind.primary,
                    onPressed: () => Navigator.of(context).pop(_preference),
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
