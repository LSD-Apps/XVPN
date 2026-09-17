import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/auto_route.dart';
import '../models.dart';
import '../protocols/parsed_profile.dart';
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
    // 三个数各自有用，不要合并：
    //   * [total] 是「这张表一共管着多少条」，写在卡片说明里；
    //   * [learnedCount] 是**可以被「清理过期」删掉的条数**——清理只动程序学到的，
    //     此前标签写的是 total，于是「清理过期（8 条中）」在一个只有 1 条学习规则、
    //     7 条手工规则的机器上会让用户以为要删掉 8 条。计数口径必须与动作的作用域
    //     一致，否则它就在误导。
    final total = user.length + learned.length + preset.length;
    final learnedCount = learned.length;

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
                ? '程序会自动纠正分流：直连失败多次后改走隧道；走隧道的域名若直连'
                      '解析落在规则库网段内则改直连。目前还没有需要纠正的域名。'
                : '已对 $total 个域名调整了分流。这些规则优先于规则集——规则集把某些'
                      '域名判成直连时靠它们拉回隧道，把能直连的域名判进隧道时靠它们'
                      '拉出来。',
            style: XvText.caption,
          ),
          const SizedBox(height: 14),
          _buildDefaultRule(),
          Divider(height: 18, thickness: 1, color: XV.line2),
          _sectionLabel('程序学到', count: learned.length),
          if (learned.isEmpty)
            Text('还没有程序学到的规则。', style: XvText.rowDesc)
          else
            for (final entry in learned) _buildEntry(entry),
          // 最近一次自动纠正的原因紧跟在「程序学到」这一节之后，而不是丢在卡片
          // 最底部：它解释的正是**上面这些规则是怎么来的**。放在页脚结尾会让它
          // 离被解释的对象隔了整张卡片，读起来像一句无主的脚注。
          if (state.learnedDecisions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '最近一次自动纠正：${state.learnedDecisions.first.domain} — '
              '${state.learnedDecisions.first.reason}',
              style: XvText.caption,
            ),
          ],
          // 内置白名单单列一组：它由「直连白名单」卡片的开关驱动，
          // 混进「程序学到」会让用户以为那也是程序自己判断出来的。
          // 放在「手工指定」之上：底部输入区逻辑上对应手工规则，顺序要对齐。
          if (preset.isNotEmpty) ...<Widget>[
            Divider(height: 18, thickness: 1, color: XV.line2),
            _sectionLabel('内置白名单', count: preset.length),
            for (final entry in preset) _buildEntry(entry),
          ],
          Divider(height: 18, thickness: 1, color: XV.line2),
          _sectionLabel('手工指定', count: user.length),
          if (user.isEmpty)
            Text('还没有手工指定的域名。在下面输入一个，选好走向后点「添加」。',
                style: XvText.rowDesc)
          else
            for (final entry in user) _buildEntry(entry),
          // 输入行与上方内容多留一点距离：它既是「手工指定」这一组的落点，
          // 又是整张卡片最后一段内容区的开头，紧贴列表会让它看起来像另一条记录。
          const SizedBox(height: 14),
          _buildManualInput(),
          _buildActions(learnedCount: learnedCount),
        ],
      ),
    );
  }

  /// 输入行下方的动作区。
  ///
  /// 这里此前是**四行同款灰色文字链接**平铺在卡片底部：导出、导入、清理过期、
  /// 全部清除。它违反的正是这个项目自己写在 `rules_screen.dart` 里的规范——那里
  /// 的卡片级动作（新增 / 检查更新 / 恢复内置规则）一律是 [XvButton]，而
  /// [TapAction] 只用于列表项内部的逐条操作。实测那段页脚在 1180px 下每个链接的
  /// 命中盒是 1110×40（几乎整张卡片宽），在 390px 下则各自独占一行 324×40：
  /// 四个等权的裸文字既没有主次、也看不出「哪几个是一组」，而且**不可逆的
  /// 「全部清除」和「导出规则包」长得一模一样**。
  ///
  /// 改成分成两段、各带标题：
  ///   * **规则包**——导出/导入是同一件事的两个方向，成对出现；
  ///   * **批量清理**——风险不同，用真实按钮承载，破坏性的那个用 danger 变体，
  ///     并明确写出「不会动手工指定的规则」，让用户在按下去之前就知道边界。
  Widget _buildActions({required int learnedCount}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 14),
        Divider(height: 1, thickness: 1, color: XV.line2),
        const SizedBox(height: 14),
        Text('规则包', style: XvText.rowTitle),
        // 4px：与页面上其它「小标题 + 说明」的间距一致（见 rules_screen.dart 的
        // 「推荐规则集」一节）。此前这里写 3px，是一处没有理由的独值。
        const SizedBox(height: 4),
        Text(
          '把手工指定的规则导出成文件，或从文件导入别人的规则。'
          '导入的规则会变成「手工指定」，不会被程序改写。',
          style: XvText.caption,
        ),
        const SizedBox(height: 10),
        // 桌面并排、窄屏两列等宽：两者是同一件事的两个方向，权重相同，因此不给
        // 谁更大的位置。窄屏下 expand 会让它们各占一半宽，而不是各占一整行——
        // 两个次要动作不该在手机上吃掉 80px 的垂直空间。
        Row(
          children: <Widget>[
            Expanded(
              child: XvButton(
                label: '导出规则包',
                icon: Icons.file_upload_outlined,
                expand: true,
                onPressed: _exportPack,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: XvButton(
                label: '导入规则包',
                icon: Icons.file_download_outlined,
                expand: true,
                onPressed: _importPack,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('批量清理', style: XvText.rowTitle),
        const SizedBox(height: 4),
        Text(
          // 刻意**不写 Markdown 的星号**：这是 Text，没有 Markdown 渲染，
          // 写进去的 `**手工指定**` 会连星号一起原样显示出来。
          '只清理程序自己学到的规则。手工指定的规则与内置白名单都不会被改动。',
          style: XvText.caption,
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: XvButton(
                // 计数只说**可被清理的条数**。写全部条数会让用户以为手工规则也会
                // 被删——实测过：1 条学习规则 + 4 条手工规则时，旧标签写「8 条中」。
                //
                // 文案不带「可清理」三个字：实测（390px 两列各 158px、Noto Sans SC）
                // 「清理过期（0 条可清理）」的文字宽 124px，而按钮内可用净宽也是
                // 124px——余量 0，任何字体差异或数字变宽都会立刻变成省略号。
                // 这三个字由上面那句说明承担。
                label: '清理过期（$learnedCount 条）',
                expand: true,
                // 一条学习规则都没有时**禁用**而不是隐藏：隐藏会让两行的排布在
                // 「有没有学习规则」之间跳变，禁用则明确表示「这个动作现在没事可做」。
                onPressed: learnedCount > 0 ? _pruneExpired : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: XvButton(
                label: '全部清除',
                kind: XvButtonKind.danger,
                expand: true,
                onPressed: _confirmClearAll,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 清理长期未命中的**学习**规则。
  ///
  /// 原先这段逻辑内联在 build 里的 onTap 闭包里，顺带把「标签里的 total」和
  /// 「实际能删的东西」这两个不同的量混在了一起。抽出来是为了让计数口径与动作
  /// 作用域在同一个地方就能对照着看。
  void _pruneExpired() {
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
      // 回车即提交：输入框与「添加」是同一件事的两个入口，只认鼠标会让
      // 键盘用户每次都要把手移开。两处走同一个 _submit，校验与提示完全一致。
      onSubmitted: (_) => _submit(),
    );

    final layout = LayoutBuilder(
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

    final error = _inputError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        layout,
        // 校验提示必须**紧贴**触发它的输入行。
        //
        // 它此前挂在卡片最底部，紧跟导出/导入两个动作之后：实测（390px）输入框
        // 底边到提示文字相距 **108px**，中间还隔着两个可点的动作。用户点了
        // 「添加」之后，视线落点与提示之间隔着一整组别的东西——这恰好是错误呈现
        // 最不该出现的形态，也会让人误以为那是导出/导入的结果。
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 一个警告图标：纯色小字在暗色面板上很容易被当成普通说明文字，
                // 而这条是**刚刚的操作失败了**。
                Padding(
                  padding: const EdgeInsets.only(top: 1.5),
                  child: Icon(
                    Icons.error_outline,
                    size: 14,
                    color: XV.amberSoft,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    error,
                    style: XvText.caption.copyWith(color: XV.amberSoft),
                  ),
                ),
              ],
            ),
          ),
      ],
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
    // 重新安装（安装时只跳过更高优先级的条目）。要覆盖它就在「手工指定」区
    // 新增同名域名——那条优先级高于白名单。
    final isPreset = entry.source == RouteRuleSource.preset;
    final title = Row(
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
    );
    final evidence = Text(_evidence(entry), style: XvText.caption);
    final actions = isPreset
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TapAction(label: '编辑', onTap: () => _editEntry(entry)),
              TapAction(
                label: '删除',
                danger: true,
                onTap: () => _removeEntry(entry),
              ),
            ],
          );

    // 窄屏把操作放到证据下方右对齐，避免长域名与「编辑/删除」互相挤压。
    if (widget.compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            title,
            const SizedBox(height: 3),
            evidence,
            if (actions != null) ...<Widget>[
              const SizedBox(height: 2),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                title,
                const SizedBox(height: 3),
                evidence,
              ],
            ),
          ),
          if (actions != null) ...<Widget>[
            const SizedBox(width: 8),
            actions,
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

  Future<void> _exportPack() async {
    final text = state.exportRoutePackText();
    if (text.isEmpty) {
      _packSnack('当前内核不支持导出域名分流规则');
      return;
    }
    try {
      final location = await getSaveLocation(
        suggestedName: 'xvpn-route-pack.json',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'JSON', extensions: <String>['json']),
        ],
      );
      if (location != null) {
        await XFile.fromData(
          Uint8List.fromList(utf8.encode(text)),
          mimeType: 'application/json',
          name: 'xvpn-route-pack.json',
        ).saveTo(location.path);
        _packSnack('已写出规则包');
        return;
      }
    } on Object {
      // 没有保存对话框时退到剪贴板，仍然能完成「共享」这件事。
    }
    await Clipboard.setData(ClipboardData(text: text));
    _packSnack('已复制规则包到剪贴板');
  }

  Future<void> _importPack() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: '规则包', extensions: <String>['json', 'txt']),
        ],
      );
      if (file == null) return;
      final added = state.importRoutePackText(await file.readAsString());
      _packSnack(added == 0 ? '没有新增规则（可能都已存在）' : '已导入 $added 条手工规则');
    } on FormatException catch (e) {
      state.reportError('规则包无法解析：${e.message}');
    } on VpnConfigException catch (e) {
      state.reportError(e.message);
    } on Object catch (e) {
      state.reportError('导入规则包失败：$e');
    }
  }

  void _packSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
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
    // 反方向学到的直连规则：依据是「直连解析落在规则库网段」，
    // 与下面那条「判为直连但失败」是完全不同的证据，必须分别说明——
    // 否则界面会显示「判为直连但失败 0 次」这种自相矛盾的理由。
    if (entry.preference == RoutePreference.forceDirect) {
      final parts = <String>[
        '直连解析落在规则库网段 ${entry.domesticHits} 次',
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
      // 翻转次数只在真的翻过时出现。它是「这个域名稳不稳定」的**可见证据**：
      // 持续增长的条目值得用户手工指定走向，而那是界面已经提供的能力。
      if (entry.flips > 0) '走向已被程序改过 ${entry.flips} 次',
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
