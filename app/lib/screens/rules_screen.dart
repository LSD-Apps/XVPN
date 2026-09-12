import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/rulesets.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/auto_route_card.dart';
import '../widgets/common.dart';

/// 分流规则页。
///
/// 这里管两层的「规则」：
///   * **规则集**（规则库）：内置的 geosite-cn / geoip-cn 与用户新增的自定义
///     规则集，可以启用/停用、查看元信息、删除与恢复；
///   * **域名分流规则**：程序学到的与用户手工指定的按域名走向。
///
/// 分流模式原本长在设置页的「分流」卡片里，一并搬到这里——三件事讲的都是
/// 「流量怎么走」，放在同一页才有一致的上下文。设置页则回到纯偏好（外观、
/// 启动、接管方式、记录、更新、关于）。
class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key, required this.state, required this.compact});

  final AppState state;
  final bool compact;

  static const _splitLabels = <String>['智能分流', '全局代理', '全局直连'];

  /// 桌面端页面级滚动容器的 Key。测试要能稳定地定位到它（页面上还有卡片内部
  /// 的滚动区域，按类型找会歧义）。
  static const Key desktopScrollKey = Key('rules-desktop-scroll');

  @override
  Widget build(BuildContext context) {
    return compact ? _buildMobile(context) : _buildDesktop(context);
  }

  // ---------------------------------------------------------------- 桌面端

  Widget _buildDesktop(BuildContext context) {
    return SingleChildScrollView(
      key: desktopScrollKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('分流规则', style: XvText.screenTitle),
              const SizedBox(height: 4),
              Text(
                '分流模式、规则集与域名走向都在这里维护',
                style: XvText.screenSubtitle,
              ),
            ],
          ),
          const SizedBox(height: 13),
          _buildSplitCard(compact: false),
          const SizedBox(height: 13),
          _buildRuleSetsCard(context, compact: false),
          const SizedBox(height: 13),
          AutoRouteCard(state: state, compact: false),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 移动端

  Widget _buildMobile(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const MobileHeader(title: '分流规则'),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 10),
                _buildSplitCard(compact: true),
                const SizedBox(height: 12),
                _buildRuleSetsCard(context, compact: true),
                const SizedBox(height: 12),
                AutoRouteCard(state: state, compact: true),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 分流模式

  Widget _buildSplitCard({required bool compact}) {
    final modeIndex = SplitMode.values.indexOf(state.settings.splitMode);
    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('分流模式'),
          Text(state.settings.splitMode.description, style: XvText.rowDesc),
          const SizedBox(height: 10),
          XvSegmented(
            labels: _splitLabels,
            index: modeIndex,
            expand: true,
            onChanged: (int i) => state.updateSettings(
              state.settings.copyWith(splitMode: SplitMode.values[i]),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '「全局代理」「全局直连」会忽略规则集与域名规则；改动在下一次连接'
            '（或重连）时写进内核配置。',
            style: XvText.caption,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 规则集

  Widget _buildRuleSetsCard(BuildContext context, {required bool compact}) {
    final entries = state.ruleSets;
    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('规则集'),
          Text(
            '内置规则集是二进制 .srs 文件，不能文本编辑：「编辑」用于启用/停用与'
            '查看来源、大小、更新时间。自定义规则集可以改名与修改下载链接。',
            style: XvText.caption,
          ),
          const SizedBox(height: 6),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '当前没有任何规则集。可「恢复内置规则」找回出厂规则集，'
                '或「新增」一个自定义规则集。',
                style: XvText.rowDesc,
              ),
            )
          else
            for (final entry in entries)
              _buildRuleSetRow(context, entry, compact: compact),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              XvButton(
                label: '新增',
                icon: Icons.add,
                onPressed: () => _showRuleSetDialog(context, null),
              ),
              XvButton(label: '检查更新', onPressed: state.refreshRuleSet),
              XvButton(
                label: '恢复内置规则',
                onPressed: () => _confirmRestoreBuiltins(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRuleSetRow(
    BuildContext context,
    RuleSetEntry entry, {
    required bool compact,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  entry.name,
                  style: XvText.bodyMuted.copyWith(color: XV.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (entry.isBuiltin)
                RouteTag.green('内置')
              else
                RouteTag.direct('自定义'),
              if (!entry.enabled) ...<Widget>[
                const SizedBox(width: 6),
                RouteTag.warn('已停用'),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            _ruleSetSubtitle(entry),
            style: XvText.caption,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              XvSwitch(
                value: entry.enabled,
                onChanged: (bool v) => state.setRuleSetEnabled(entry.name, v),
              ),
              const Spacer(),
              TapAction(
                label: '编辑',
                onTap: () => _showRuleSetDialog(context, entry),
              ),
              TapAction(
                label: '删除',
                danger: true,
                onTap: () => _confirmDeleteRuleSet(context, entry),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ruleSetSubtitle(RuleSetEntry entry) {
    final parts = <String>[
      entry.kind.label,
      if (entry.sizeBytes > 0) _sizeLabel(entry.sizeBytes),
      if (entry.updatedAt != null)
        '更新于 ${fmtDate(entry.updatedAt!)}'
      else
        '使用出厂副本',
      entry.url,
    ];
    return parts.join(' · ');
  }

  static String _sizeLabel(int bytes) {
    final size = fmtBytes(bytes);
    return '${size.value}${size.unit}';
  }

  // ---------------------------------------------------------------- 弹窗

  /// 新增或编辑一个规则集。内置规则集只展示元信息。
  Future<void> _showRuleSetDialog(
    BuildContext context,
    RuleSetEntry? entry,
  ) async {
    final result = await showDialog<_RuleSetDialogResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) =>
          _RuleSetDialog(entry: entry, state: state),
    );
    if (result == null || !context.mounted) return;
    final error = entry == null
        ? await state.addCustomRuleSet(name: result.name, url: result.url)
        : await state.updateCustomRuleSet(
            oldName: entry.name,
            name: result.name,
            url: result.url,
          );
    if (!context.mounted) return;
    if (error != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(error, style: TextStyle(fontSize: 12.5, color: XV.text)),
          backgroundColor: XV.panel3,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          entry == null ? '已新增规则集「${result.name}」' : '已保存规则集「${result.name}」',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _confirmDeleteRuleSet(
    BuildContext context,
    RuleSetEntry entry,
  ) async {
    final confirmed = await XvConfirmDialog.show(
      context,
      title: '删除规则集',
      message: entry.isBuiltin
          ? '确定删除内置规则集「${entry.name}」？删除后本程序不再使用它，'
                '磁盘上的副本会一并清掉；可用「恢复内置规则」随时找回。'
          : '确定删除自定义规则集「${entry.name}」？它的文件会从磁盘删除，'
                '需要重新「新增」才能找回。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !context.mounted) return;
    state.deleteRuleSet(entry.name);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '已删除规则集「${entry.name}」',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _confirmRestoreBuiltins(BuildContext context) async {
    final confirmed = await XvConfirmDialog.show(
      context,
      title: '恢复内置规则',
      message:
          '恢复内置规则会做两件事：\n'
          '· 重新启用两个内置规则集（geosite-cn、geoip-cn）；\n'
          '· 清除程序自动学到的域名分流规则。\n\n'
          '你手工指定的域名规则与自定义规则集会保留。',
      confirmLabel: '恢复',
    );
    if (!confirmed || !context.mounted) return;
    state.restoreBuiltinRuleSets();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '已恢复内置规则集，并清除程序学到的规则',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}

/// 规则集表单的返回值。
class _RuleSetDialogResult {
  const _RuleSetDialogResult({required this.name, required this.url});

  final String name;
  final String url;
}

/// 新增 / 编辑规则集的表单。
///
/// 做成独立 StatefulWidget 而不是就地用 StatefulBuilder：`showDialog` 的 Future
/// 在退场动画播完**之前**就已返回，控制器若在那时被释放，动画里的输入框就会
/// 用到已释放对象并抛异常（这类错误在测试里表现为
/// 「A TextEditingController was used after being disposed」）。
class _RuleSetDialog extends StatefulWidget {
  const _RuleSetDialog({required this.entry, required this.state});

  final RuleSetEntry? entry;
  final AppState state;

  @override
  State<_RuleSetDialog> createState() => _RuleSetDialogState();
}

class _RuleSetDialogState extends State<_RuleSetDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.entry?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.entry?.url ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final builtin = entry?.isBuiltin ?? false;
    final isNew = entry == null;
    return Dialog(
      backgroundColor: XV.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XV.rCard),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  builtin
                      ? '内置规则集'
                      : (isNew ? '新增规则集' : '编辑规则集'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: XV.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  builtin
                      ? '内置规则集来自上游的二进制 .srs 文件，本程序不解析、'
                            '也不能编辑它的内容。这里只查看来源与更新时间；'
                            '启用/停用请用列表里的开关。'
                      : '填写规则集的名称与下载链接。链接必须指向一个 .srs 文件，'
                            '程序会下载并校验格式，成功后才加入列表。',
                  style: XvText.caption,
                ),
                const SizedBox(height: 14),
                if (builtin) ...<Widget>[
                  _metaRow('名称', entry!.name),
                  _metaRow('来源', entry.url),
                  _metaRow(
                    '大小',
                    entry.sizeBytes > 0
                        ? RulesScreen._sizeLabel(entry.sizeBytes)
                        : '尚未量过',
                  ),
                  _metaRow(
                    '更新',
                    entry.updatedAt != null
                        ? fmtDate(entry.updatedAt!)
                        : '从未更新（使用出厂副本）',
                  ),
                ] else ...<Widget>[
                  Text('名称', style: XvText.rowTitle),
                  const SizedBox(height: 6),
                  XvControlBox(
                    child: TextField(
                      controller: _name,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: XV.text,
                        fontFamilyFallback: XV.monoFallback,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: '例如 my-rules',
                        hintStyle: TextStyle(fontSize: 12.5, color: XV.muted2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('下载链接', style: XvText.rowTitle),
                  const SizedBox(height: 6),
                  XvControlBox(
                    child: TextField(
                      controller: _url,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: XV.text,
                        fontFamilyFallback: XV.monoFallback,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: 'https://example.com/my-rules.srs',
                        hintStyle: TextStyle(fontSize: 12.5, color: XV.muted2),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    XvButton(
                      label: builtin ? '关闭' : '取消',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    if (!builtin) ...<Widget>[
                      const SizedBox(width: 10),
                      XvButton(
                        label: isNew ? '添加' : '保存',
                        kind: XvButtonKind.primary,
                        onPressed: () => Navigator.of(context).pop(
                          _RuleSetDialogResult(
                            name: _name.text.trim(),
                            url: _url.text.trim(),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 54,
            child: Text(label, style: TextStyle(fontSize: 11.5, color: XV.muted2)),
          ),
          Expanded(
            child: Text(
              value,
              style: XvText.monoSmall.copyWith(color: XV.text),
            ),
          ),
        ],
      ),
    );
  }
}
