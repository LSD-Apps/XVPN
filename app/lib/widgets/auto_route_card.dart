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
          Row(
            children: <Widget>[
              Expanded(
                child: XvSearchField(
                  hint: '例如 example.com',
                  controller: _domainController,
                  onChanged: (_) {
                    if (_inputError != null) setState(() => _inputError = null);
                  },
                ),
              ),
              const SizedBox(width: 8),
              XvSegmented(
                labels: const <String>['走代理', '直连'],
                index: _preference == RoutePreference.forceProxy ? 0 : 1,
                onChanged: (int i) => setState(() {
                  _preference = i == 0
                      ? RoutePreference.forceProxy
                      : RoutePreference.forceDirect;
                }),
              ),
              const SizedBox(width: 8),
              XvButton(label: '添加', onPressed: _submit),
            ],
          ),
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
