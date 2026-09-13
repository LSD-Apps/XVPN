import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/auto_route.dart';
import '../core/domain_check.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'failures_dialog.dart';

/// 分流记录页。这一页是「傻瓜式」的兜底：
/// 出问题时用户能自己看出是判定错了，还是节点本身不通。
class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key, required this.state, required this.compact});

  final AppState state;
  final bool compact;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  RouteFilter _filter = RouteFilter.all;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    return widget.compact ? _buildMobile() : _buildDesktop();
  }

  // ---------------------------------------------------------------- 桌面端

  Widget _buildDesktop() {
    final rows = widget.state.filteredRecords(_filter, _query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('分流记录', style: XvText.screenTitle),
                  SizedBox(height: 4),
                  Text('每一条连接走了哪条路、为什么走这条路，都在这里', style: XvText.screenSubtitle),
                ],
              ),
            ),
            XvSegmented(
              labels: RouteFilter.values
                  .map((RouteFilter f) => f.label)
                  .toList(growable: false),
              index: _filter.index,
              onChanged: (int i) =>
                  setState(() => _filter = RouteFilter.values[i]),
            ),
            const SizedBox(width: 10),
            XvButton(label: '查证域名', onPressed: () => _showDomainCheck(context)),
            const SizedBox(width: 10),
            XvButton(label: '清空', onPressed: widget.state.clearRecords),
          ],
        ),
        const SizedBox(height: 13),
        _summaryCard(context, compact: false),
        const SizedBox(height: 13),
        XvSearchField(
          hint: '搜索域名或 IP…',
          controller: _searchController,
          onChanged: (String v) => setState(() => _query = v),
          onClear: _query.isEmpty ? null : _clearSearch,
        ),
        const SizedBox(height: 13),
        Expanded(
          child: XvCard(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _buildTable(rows),
          ),
        ),
      ],
    );
  }

  /// 按域名查证。
  ///
  /// 回答的是一个此前没有入口的问题：「**我打不开的这个网站**到底怎么了」。
  /// 已有的几处观测各自回答的是全局问题（有没有直连失败、DNS 健不健康），
  /// 而用户是拿着一个域名来问的。
  Future<void> _showDomainCheck(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      // 弹窗内容做成独立 StatefulWidget 而不是就地用 StatefulBuilder：
      // showDialog 的 Future 在退场动画播完**之前**就已返回，控制器若在那时
      // 被释放，动画里的输入框就会用到已释放对象并抛异常。
      builder: (BuildContext dialogContext) => _DomainCheckDialog(
        state: widget.state,
        // 输入框预填当前搜索词：用户多半是先搜了域名、没得到想要的答案才来查证。
        initialDomain: _query.trim(),
      ),
    );
  }

  // ---------------------------------------------------------------- 汇总

  /// 本次连接的全局汇总。
  ///
  /// 为什么放在分流记录页：这一页是「分析问题」的地方——用户在这里看每条连接
  /// 走了哪条路。判定出问题时，他下一个问题必然是「那是规则判错了还是节点不通」，
  /// 而回答它需要的是延迟与失败记录，不是再翻一遍连接列表。把这三样放在同一屏，
  /// 才能一眼看出关联：**同一个目标反复失败、且延迟同时变差，多半是节点的问题；
  /// 只有直连失败、延迟正常，才是规则的事**。
  ///
  /// [compact] 是移动端用的单行版：手机横屏时可用高度只有三百来点，三行汇总会
  /// 把列表挤到溢出（这一条有测试守着）。单行仍然给全三个数字。
  Widget _summaryCard(BuildContext context, {required bool compact}) {
    final state = widget.state;
    final digest = state.failureDigest;
    final suspected = digest.suspectedMissingRules;
    final latency = state.latencyMs;
    final health = state.tunnelHealth;
    final hasProblem = digest.hasProblems || (health?.isProblem ?? false);
    final detail = TapAction(
      label: '失败详情',
      onTap: () => showFailuresDialog(context, state),
    );

    if (compact) {
      final failures = digest.total == 0 ? '连接失败：暂无' : '连接失败 ${digest.total} 条';
      return XvCard(
        color: XV.panel2,
        radius: 12,
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: CheckRow(
          title: latency == null ? '延迟 测量中' : '延迟 $latency ms',
          detail:
              '$failures · 活连接 ${state.connectionCount} 条 · '
              '本次累计 ${_totalLabel(state.totalBytes)}',
          warn: latency == null || hasProblem,
          mono: true,
          action: digest.hasProblems ? detail : null,
        ),
      );
    }

    return XvCard(
      color: XV.panel2,
      radius: 12,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const XvCardTitle('本次汇总'),
          CheckRow(
            title: latency == null ? '延迟：测量中' : '延迟：$latency ms',
            detail: health != null && health.isProblem
                ? health.summary
                : '经隧道实测的端到端耗时，每 15 秒一次',
            warn: latency == null || (health?.isProblem ?? false),
          ),
          const SizedBox(height: 10),
          CheckRow(
            title: digest.total == 0
                ? '连接失败：暂无'
                : '连接失败：${digest.total} 条'
                      '（直连 ${digest.directFailures} / 隧道 ${digest.proxiedFailures}）',
            detail: suspected.isEmpty
                ? digest.advice
                : '疑似规则未覆盖：${suspected.take(3).join('、')}'
                      '${suspected.length > 3 ? ' 等 ${suspected.length} 个' : ''}',
            warn: digest.hasProblems,
            mono: suspected.isNotEmpty,
            action: digest.hasProblems ? detail : null,
          ),
          const SizedBox(height: 10),
          CheckRow(
            title: '观测范围：本次累计 ${_totalLabel(state.totalBytes)}',
            detail:
                '当前活连接 ${state.connectionCount} 条 · '
                '比例取自活连接快照，连接关闭后不再计入',
            mono: true,
          ),
        ],
      ),
    );
  }

  static String _totalLabel(int bytes) {
    final text = fmtBytes(bytes);
    return '${text.value}${text.unit}';
  }

  /// 表格里各列的最小可用宽度（逻辑像素）。
  ///
  /// 低于它就把次要列收起来。桌面布局的判定阈值是 900，但用户可以把窗口拖窄，
  /// 而且系统缩放会让「看上去够宽」的窗口实际只有几百逻辑像素——那时固定列
  /// 加起来超过可用宽度，排在后面的列会被直接裁掉，看起来就是「列不见了」。
  /// 与其让用户对着半张表猜，不如让它按可用宽度自己收敛。
  static const double _minWidthForFailures = 620;
  static const double _minWidthForTraffic = 520;

  Widget _buildTable(List<SplitRecord> rows) {
    final truncated = widget.state.isFilterTruncated(_filter, _query);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth;
        final showTraffic = width >= _minWidthForTraffic;
        final showFailures = width >= _minWidthForFailures;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 62, child: _TableHead('最近')),
                  const Expanded(flex: 5, child: _TableHead('目标')),
                  const SizedBox(width: 58, child: _TableHead('判定')),
                  if (showTraffic)
                    // 弹性宽度：空间不足时它变窄，而不是把后面的列挤出去。
                    const Expanded(flex: 3, child: _TableHead('流量 ↓/↑')),
                  if (showFailures)
                    const SizedBox(width: 46, child: _TableHead('失败')),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: XV.line),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        _query.isEmpty ? '还没有分流记录' : '没有匹配「$_query」的记录',
                        style: TextStyle(fontSize: 12.5, color: XV.muted2),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: rows.length + 1,
                      itemBuilder: (BuildContext context, int index) {
                        if (index == rows.length) {
                          return _tableFooter(truncated);
                        }
                        return _buildTableRow(
                          rows[index],
                          showTraffic: showTraffic,
                          showFailures: showFailures,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _tableFooter(bool truncated) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      child: Text(
        truncated
            ? '结果较多，只显示前 ${AppState.searchResultLimit} 条；'
                  '输入关键字可以缩小范围。\n'
                  '同一目标只列一条，访问次数与流量累加。'
            : '同一目标只列一条，访问次数与流量累加。'
                  '默认保留最近 ${AppState.recordLimit} 条，可在设置中关闭。',
        style: TextStyle(fontSize: 11.5, color: XV.muted2, height: 1.7),
      ),
    );
  }

  Widget _buildTableRow(
    SplitRecord r, {
    required bool showTraffic,
    required bool showFailures,
  }) {
    return Container(
      // 按目标取 Key：同目标只有一行，因此这个 Key 在整个列表里唯一，
      // 而且行不会因为新增记录而整体错位（旧实现按时间取 Key，每秒都变）。
      key: ValueKey<String>('rec:${r.target}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: XV.line2)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 62,
            child: Text(
              r.lastSeenDisplay,
              style: TextStyle(fontSize: 11.5, color: XV.muted2),
            ),
          ),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        r.target,
                        style: XvText.bodyMuted.copyWith(color: XV.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (r.connections > 1) ...<Widget>[
                      const SizedBox(width: 6),
                      Text('×${r.connections}', style: XvText.caption),
                    ],
                  ],
                ),
                // 规则与出站移到第二行小字：它们是「为什么走这条路」的解释，
                // 保留但不占主视线。
                if (r.rule.isNotEmpty)
                  Text(
                    r.rule,
                    style: XvText.caption,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 58,
            child: Align(
              alignment: Alignment.centerLeft,
              child: RouteTag.kind(r.kind),
            ),
          ),
          if (showTraffic)
            Expanded(
              flex: 3,
              child: Text(
                fmtTrafficPair(down: r.downloadBytes, up: r.uploadBytes),
                style: XvText.monoSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (showFailures)
            SizedBox(
              width: 46,
              child: Text(
                r.failures == 0 ? '—' : '${r.failures}',
                style: r.failures == 0
                    ? XvText.monoSmall
                    : XvText.monoSmall.copyWith(color: XV.amber),
              ),
            ),
        ],
      ),
    );
  }

  // 曾经有一个 `_latencyText` 在这里，为「延迟」列生成文字。该列已移除
  // （它对每一行都是同一个数——整条隧道的往返值），方法也一并删掉，
  // 不留无人调用的死代码。

  // ---------------------------------------------------------------- 移动端

  /// 移动端的一条记录：**两行**，不放表格。
  ///
  /// 手机上宽度只有 360–400dp，桌面那种六列表格在手机上是不可读的。这里改成：
  ///
  /// ```
  /// youtube.com  ×3                        [走代理]
  /// ↓2.4M ↑180K · 失败 2 · 默认规则 · 14:03
  /// ```
  ///
  /// 第一行是身份（目标、访问次数、判定），第二行是**全部量化信息**，用 `·` 分隔
  /// 放在一行里：流量、失败、命中规则、最近时间。这样信息全都在，但只占两行、
  /// 不需要横向滚动，也不需要为每项加一列。
  ///
  /// 这里**不含延迟**：延迟是整条隧道的往返值，对每个目标都一样，放进每一行
  /// 只会让人以为在比较站点快慢。隧道延迟在「本次汇总」里统一给出。
  Widget _buildMobileRow(SplitRecord r) {
    final traffic = fmtTrafficPair(down: r.downloadBytes, up: r.uploadBytes);
    final metrics = <String>[
      if (traffic != '—') traffic,
      if (r.failures > 0) '失败 ${r.failures}',
      if (r.rule.isNotEmpty) r.rule,
      r.lastSeenDisplay,
    ];

    return Padding(
      key: ValueKey<String>('rec:${r.target}'),
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  r.target,
                  style: XvText.bodyMuted.copyWith(color: XV.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 访问次数只在真的重复访问时出现，避免每行都挂一个「×1」噪声。
              if (r.connections > 1) ...<Widget>[
                const SizedBox(width: 5),
                Text('×${r.connections}', style: XvText.caption),
              ],
              const Spacer(),
              RouteTag.kind(r.kind),
            ],
          ),
          if (metrics.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              metrics.join(' · '),
              style: XvText.caption.copyWith(
                // 有失败时整行转成警示色：一行里最需要被看见的就是它。
                color: r.failures > 0 ? XV.amber : XV.muted2,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMobile() {
    final rows = widget.state.filteredRecords(_filter, _query);
    final truncated = widget.state.isFilterTruncated(_filter, _query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MobileHeader(
          title: '分流',
          statusLabel: widget.state.status.label,
          statusActive: widget.state.isConnected,
        ),
        const SizedBox(height: 12),
        _summaryCard(context, compact: true),
        const SizedBox(height: 12),
        XvSearchField(
          hint: '搜索域名或 IP…',
          controller: _searchController,
          onChanged: (String v) => setState(() => _query = v),
          onClear: _query.isEmpty ? null : _clearSearch,
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: XvSegmented(
                // 与桌面端共用同一份文案：桌面写「走代理」，移动端此前硬编码
                // 「代理」，同一个筛选器在两端叫法不同。
                labels: RouteFilter.values
                    .map((RouteFilter f) => f.label)
                    .toList(growable: false),
                index: _filter.index,
                expand: true,
                onChanged: (int i) =>
                    setState(() => _filter = RouteFilter.values[i]),
              ),
            ),
            const SizedBox(width: 8),
            // 桌面端的「清空」长在表头行里，移动端此前完全没有入口，
            // 手机上记录只能靠关日志或重连来清。
            TapAction(label: '查证', onTap: () => _showDomainCheck(context)),
            const SizedBox(width: 8),
            TapAction(label: '清空', onTap: widget.state.clearRecords),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: XvCard(
            color: XV.panel2,
            radius: 12,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty ? '还没有分流记录' : '没有匹配的记录',
                      style: TextStyle(fontSize: 12.5, color: XV.muted2),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, thickness: 1, color: XV.line2),
                    itemBuilder: (BuildContext context, int i) =>
                        _buildMobileRow(rows[i]),
                  ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: 12, bottom: 14),
          child: Text(
            truncated
                ? '结果较多，只显示前 ${AppState.searchResultLimit} 条\n'
                      '只记录域名与判定结果，不记录请求内容'
                : '只记录域名与判定结果，不记录请求内容\n'
                      '最多保留最近 ${AppState.recordLimit} 条',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: XV.muted2, height: 1.75),
          ),
        ),
      ],
    );
  }
}

/// 查证域名的弹窗。
///
/// 做成 StatefulWidget 而不是在调用处就地建控制器：`showDialog` 的 Future 在
/// 退场动画播完**之前**就已经返回，那一刻释放控制器会让动画里的输入框用到
/// 已释放对象（这类错误在测试里表现为
/// 「A TextEditingController was used after being disposed」）。
class _DomainCheckDialog extends StatefulWidget {
  const _DomainCheckDialog({required this.state, required this.initialDomain});

  final AppState state;
  final String initialDomain;

  @override
  State<_DomainCheckDialog> createState() => _DomainCheckDialogState();
}

class _DomainCheckDialogState extends State<_DomainCheckDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialDomain,
  );
  DomainCheck? _result;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final domain = _controller.text.trim();
    if (domain.isEmpty) {
      setState(() => _error = '请先填写域名');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await widget.state.checkDomain(domain);
      // 查询期间用户可能已经把弹窗关掉了。
      if (!mounted) return;
      setState(() => _result = check);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '查证失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _prefer(RoutePreference preference) {
    final result = _result;
    if (result == null) return;
    widget.state.setDomainPreference(result.domain, preference);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Dialog(
      backgroundColor: XV.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XV.rCard),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 560),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '查证域名',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: XV.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '汇总关于这个域名已经掌握的证据：内核实际把它判到了哪条路、'
                  '有没有规则覆盖它、两路 DNS 的解析是否一致。',
                  style: XvText.caption,
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: XvControlBox(
                        child: TextField(
                          controller: _controller,
                          onSubmitted: (_) => _run(),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: XV.text,
                            fontFamilyFallback: XV.monoFallback,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            hintText: '例如 www.example.com',
                            hintStyle: TextStyle(
                              fontSize: 12.5,
                              color: XV.muted2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    XvButton(
                      label: _busy ? '查询中…' : '查证',
                      kind: XvButtonKind.primary,
                      onPressed: _busy ? null : _run,
                    ),
                  ],
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: TextStyle(fontSize: 11.5, color: XV.redSoft),
                  ),
                ],
                if (result != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: XV.field,
                      border: Border.all(color: XV.line),
                      borderRadius: BorderRadius.circular(XV.rCtl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          result.conclusion,
                          style: XvText.bodyMuted.copyWith(color: XV.text),
                        ),
                        const SizedBox(height: 8),
                        for (final fact in result.facts)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                SizedBox(
                                  width: 62,
                                  child: Text(
                                    fact.label,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: XV.muted2,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    fact.value,
                                    style: XvText.monoSmall.copyWith(
                                      color: XV.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '改判立即生效（内核 10 秒内刷新分流）',
                          style: TextStyle(fontSize: 11, color: XV.muted2),
                        ),
                      ),
                      TapAction(
                        label: '改为走代理',
                        onTap: () => _prefer(RoutePreference.forceProxy),
                      ),
                      const SizedBox(width: 10),
                      TapAction(
                        label: '改为直连',
                        onTap: () => _prefer(RoutePreference.forceDirect),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    XvButton(
                      label: '复制结论',
                      onPressed: result == null
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(
                                text:
                                    '${result.domain}\n${result.conclusion}\n'
                                    '${result.facts.map((f) => '${f.label}：${f.value}').join('\n')}',
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    XvButton(
                      label: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TableHead extends StatelessWidget {
  const _TableHead(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: XV.muted2,
        ),
      ),
    );
  }
}
