import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

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
              labels: RouteFilter.values.map((RouteFilter f) => f.label).toList(growable: false),
              index: _filter.index,
              onChanged: (int i) => setState(() => _filter = RouteFilter.values[i]),
            ),
            const SizedBox(width: 10),
            XvButton(label: '清空', onPressed: widget.state.clearRecords),
          ],
        ),
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

  Widget _buildTable(List<SplitRecord> rows) {
    final truncated = widget.state.isFilterTruncated(_filter, _query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: <Widget>[
              SizedBox(width: 82, child: _TableHead('时间')),
              Expanded(flex: 3, child: _TableHead('目标')),
              SizedBox(width: 84, child: _TableHead('判定')),
              Expanded(flex: 2, child: _TableHead('命中规则')),
              SizedBox(width: 88, child: _TableHead('出站')),
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
                  // 列表按「最新的在最前」插入，因此缓存范围要以第 0 项为锚点，
                  // 否则每秒插入新记录都会让可见区域的缓存整体失效，
                  // 表现为滚动时不停重建。
                  itemCount: rows.length + 1,
                  itemBuilder: (BuildContext context, int index) {
                    if (index == rows.length) {
                      return Padding(
                        padding: EdgeInsets.fromLTRB(10, 12, 10, 8),
                        child: Text(
                          truncated
                              ? '结果较多，只显示前 ${AppState.searchResultLimit} 条；'
                                  '输入关键字可以缩小范围。\n'
                                  '只记录域名与判定结果，不记录任何请求内容。'
                              : '只记录域名与判定结果，不记录任何请求内容。'
                                  '默认保留最近 ${AppState.recordLimit} 条，可在设置中关闭。',
                          style: TextStyle(fontSize: 11.5, color: XV.muted2, height: 1.7),
                        ),
                      );
                    }
                    return _buildTableRow(rows[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTableRow(SplitRecord r) {
    return Container(
      // 稳定 Key 而不是按位置复用：记录是插在最前面的，按位置复用会让
      // 每一行的内容整体下移一格，Flutter 无法复用任何已有元素。
      key: ValueKey<String>('${r.time.microsecondsSinceEpoch}|${r.target}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: XV.line2)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 82,
            child: Text(r.timeDisplay, style: TextStyle(fontSize: 11.5, color: XV.muted2)),
          ),
          Expanded(
            flex: 3,
            child: Text(r.target, style: XvText.bodyMuted.copyWith(color: XV.text)),
          ),
          SizedBox(width: 84, child: Align(alignment: Alignment.centerLeft, child: RouteTag.kind(r.kind))),
          Expanded(
            flex: 2,
            child: Text(r.rule, style: XvText.caption, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 88,
            child: Text(r.outbound, style: XvText.monoSmall),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 移动端

  Widget _buildMobile() {
    final rows = widget.state.filteredRecords(_filter, _query);
    final truncated = widget.state.isFilterTruncated(_filter, _query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MobileHeader(
          title: '分流',
          statusLabel: switch (widget.state.status) {
            VpnStatus.connected => '已连接',
            VpnStatus.connecting => '连接中',
            VpnStatus.disconnected => '未连接',
          },
          statusActive: widget.state.isConnected,
        ),
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
                labels: RouteFilter.values.map((RouteFilter f) => f.label).toList(growable: false),
                index: _filter.index,
                expand: true,
                onChanged: (int i) => setState(() => _filter = RouteFilter.values[i]),
              ),
            ),
            const SizedBox(width: 8),
            // 桌面端的「清空」长在表头行里，移动端此前完全没有入口，
            // 手机上记录只能靠关日志或重连来清。
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
                    separatorBuilder: (_, _) => Divider(height: 1, thickness: 1, color: XV.line2),
                    itemBuilder: (BuildContext context, int i) {
                      final r = rows[i];
                      return Padding(
                        key: ValueKey<String>('${r.time.microsecondsSinceEpoch}|${r.target}'),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    r.target,
                                    style: XvText.bodyMuted.copyWith(color: XV.text),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                RouteTag.kind(r.kind),
                              ],
                            ),
                            // 「为什么走这条路」在手机上原本看不到（只有目标与判定）。
                            // 出问题时这是用户唯一能自查的线索，补在第二行。
                            if (r.rule.isNotEmpty || r.outbound.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 5),
                              Text(
                                <String>[r.rule, r.outbound]
                                    .where((String s) => s.isNotEmpty)
                                    .join(' · '),
                                style: XvText.caption,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
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
