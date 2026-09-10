import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../protocols/vpn_protocol.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'import_conf.dart';

/// 配置文件页。
///
/// 桌面端是独立一页；移动端并入设置页（[embedded] = true），与设计稿 M4 一致。
class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key, required this.state, this.embedded = false});

  final AppState state;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    if (embedded) return _buildEmbedded(context);
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
                  Text('配置文件', style: XvText.screenTitle),
                  SizedBox(height: 4),
                  Text('导入的 .conf 都保存在本机，随时可以切换', style: XvText.screenSubtitle),
                ],
              ),
            ),
            XvButton(
              label: '导入配置',
              kind: XvButtonKind.primary,
              onPressed: () => pickAndImportConf(context, state),
            ),
          ],
        ),
        const SizedBox(height: 13),
        Expanded(
          child: state.profiles.isEmpty
              ? _buildEmpty(context)
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: state.profiles.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 13),
                  itemBuilder: (BuildContext context, int i) => _ProfileCard(
                    profile: state.profiles[i],
                    isActive: state.profiles[i].id == state.activeProfile?.id,
                    onActivate: () => state.setActiveProfile(state.profiles[i].id),
                    onRemove: () => state.removeProfile(state.profiles[i].id),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text('还没有导入任何配置', style: TextStyle(fontSize: 14, color: XV.muted)),
          const SizedBox(height: 10),
          Text(
            '导入一个 .conf 就能开始使用，分流规则已经内置',
            style: XvText.caption,
          ),
          const SizedBox(height: 20),
          XvButton(
            label: '选择 .conf 文件',
            kind: XvButtonKind.primary,
            onPressed: () => pickAndImportConf(context, state),
          ),
        ],
      ),
    );
  }

  /// 移动端：作为设置页里的一张卡，对应原型 M4 的「配置」区。
  Widget _buildEmbedded(BuildContext context) {
    return XvCard(
      color: XV.panel2,
      radius: 12,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('配置'),
          for (final p in state.profiles)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      p.name,
                      style: XvText.bodyMuted.copyWith(color: XV.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (p.id == state.activeProfile?.id)
                    RouteTag.green('当前')
                  else
                    TapAction(
                      label: '切换',
                      onTap: () => state.setActiveProfile(p.id),
                    ),
                  // 删除入口：桌面端在配置卡片上有「删除」按钮，移动端此前完全没有，
                  // 结果手机上的配置只能增不能删。放在切换按钮右侧并撑足热区。
                  TapAction(
                    label: '删除',
                    danger: true,
                    onTap: () => _confirmRemove(context, p),
                  ),
                ],
              ),
            ),
          InkWell(
            onTap: () => pickAndImportConf(context, state),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text('导入新配置…', style: TextStyle(fontSize: 12.5, color: XV.muted)),
                  ),
                  Text('＋', style: TextStyle(fontSize: 13, color: XV.muted2)),
                ],
              ),
            ),
          ),
          // 粘贴导入原先只在「一个配置都没有」的空状态页里可达，导入第一个配置后就
          // 再也找不到了。放在这里，两条导入路径随时都在。
          TapAction(
            label: '粘贴配置文本…',
            onTap: () => startConfPasteDialog(context, state),
          ),
        ],
      ),
    );
  }

  /// 删除前确认。
  ///
  /// 删除会连带断开当前连接（见 [AppState.removeProfile]），因此不能一点就删，
  /// 否则用户在手机上误触会直接掉线。
  Future<void> _confirmRemove(BuildContext context, VpnProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) => Dialog(
        backgroundColor: XV.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XV.rCard),
          side: BorderSide(color: XV.line),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '删除配置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: XV.text),
                ),
                const SizedBox(height: 8),
                Text('确定删除「${profile.name}」？删除后需要重新导入才能使用。', style: XvText.caption),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    XvButton(
                      label: '取消',
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                    ),
                    const SizedBox(width: 10),
                    XvButton(
                      label: '删除',
                      kind: XvButtonKind.danger,
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed == true) state.removeProfile(profile.id);
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.isActive,
    required this.onActivate,
    required this.onRemove,
  });

  final VpnProfile profile;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return XvCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        profile.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: XV.text,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isActive) ...<Widget>[
                      const SizedBox(width: 10),
                      RouteTag.green('当前'),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 20,
                  runSpacing: 9,
                  children: <Widget>[
                    // 协议标注放最前：导入多种协议的配置后，一眼就能分辨。
                    _Field(label: '协议', value: profile.protocolType.label),
                    _Field(label: '服务器', value: profile.endpointDisplay),
                    _Field(label: '隧道地址', value: profile.tunnelAddressDisplay),
                    // 协议特有的补充字段由解析结果统一提供，
                    // 因此新增协议时这里不需要改动。
                    for (final detail in profile.parsed.details)
                      _Field(label: detail.label, value: detail.value),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Row(
            children: <Widget>[
              if (!isActive) ...<Widget>[
                XvButton(label: '设为当前', onPressed: onActivate),
                const SizedBox(width: 8),
              ],
              XvButton(label: '删除', kind: XvButtonKind.danger, onPressed: onRemove),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: XvText.bodyMuted,
        children: <InlineSpan>[
          TextSpan(text: '$label ', style: TextStyle(color: XV.muted2)),
          TextSpan(
            text: value,
            style: TextStyle(color: XV.text, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
