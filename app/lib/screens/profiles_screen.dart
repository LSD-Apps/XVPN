import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../protocols/vpn_protocol.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'credential_dialog.dart';
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

    final hasProfiles = state.profiles.isNotEmpty;
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
                  Text(
                    hasProfiles
                        ? '导入的配置都保存在本机，随时可以切换'
                        : '导入一份配置就能开始使用，分流规则已经内置',
                    style: XvText.screenSubtitle,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        // 导入入口固定成一张卡，位置与分量不随「有没有配置」变化。
        _ImportCard(state: state, compact: false),
        const SizedBox(height: 13),
        Expanded(
          child: hasProfiles
              ? ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: state.profiles.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 13),
                  itemBuilder: (BuildContext context, int i) => _ProfileCard(
                    profile: state.profiles[i],
                    isActive: state.profiles[i].id == state.activeProfile?.id,
                    hasCredentials: state.profileHasCredentials(
                      state.profiles[i].id,
                    ),
                    onActivate: () =>
                        state.setActiveProfile(state.profiles[i].id),
                    onEditCredentials: () =>
                        _promptCredentials(context, state.profiles[i]),
                    onRemove: () => state.removeProfile(state.profiles[i].id),
                  ),
                )
              : _buildEmpty(context),
        ),
      ],
    );
  }

  /// 还没有任何配置时的提示。
  ///
  /// 导入入口本身已经在上方的 [_ImportCard] 里给了，这里不再重复放按钮——
  /// 两处按钮指向同一个动作，只会让人犹豫该点哪一个。
  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.folder_open_outlined, size: 26, color: XV.muted2),
          const SizedBox(height: 12),
          Text('还没有导入任何配置', style: TextStyle(fontSize: 14, color: XV.muted)),
          const SizedBox(height: 6),
          Text('用上面的任一方式导入即可', style: XvText.caption),
        ],
      ),
    );
  }

  /// 移动端：作为设置页里的一张卡，对应原型 M4 的「配置」区。
  ///
  /// 列表与导入入口合成一张卡：已有配置时先列列表再给入口，没有配置时
  /// 只留入口。这样「配置」在设置页里始终是一个完整的区域，
  /// 而不是列表与两行零散文字链拼起来的碎片。
  Widget _buildEmbedded(BuildContext context) {
    return XvCard(
      color: XV.panel2,
      radius: 12,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
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
                  // 需要账号密码的配置（OpenVPN 的 auth-user-pass）有两种状态：
                  // 还没填（红色标签 + 填写入口）和已经填好（只留一个改密码入口）。
                  // 没有这个入口时，用户会看到「需要账号密码」的提示却无处可填。
                  if (p.parsed.requiresCredentials &&
                      !state.profileHasCredentials(p.id))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: RouteTag.warn('缺账号密码'),
                    ),
                  if (p.parsed.requiresCredentials &&
                      !state.profileHasCredentials(p.id))
                    TapAction(
                      label: '填写',
                      onTap: () => _promptCredentials(context, p),
                    )
                  else if (p.parsed.requiresCredentials)
                    TapAction(
                      label: '改密码',
                      onTap: () => _promptCredentials(context, p),
                    ),
                  if (p.id == state.activeProfile?.id)
                    RouteTag.green('当前')
                  else
                    TapAction(
                      // 与桌面端卡片统一叫法：都叫「设为当前」。此前移动端写
                      // 「切换」、桌面端写「设为当前」，同一个动作两种说法，
                      // 本项目把这种分叉当作缺陷处理。
                      label: '设为当前',
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
          if (state.profiles.isNotEmpty) const SizedBox(height: 10),
          _ImportCard(state: state, compact: true),
        ],
      ),
    );
  }

  /// 补填或修改某份配置的账号密码。
  ///
  /// 改密码会让隧道按新凭据重建（见 [AppState.setProfileCredentials]），
  /// 因此这里不需要额外提示——状态栏会如实反映「连接中」。
  Future<void> _promptCredentials(
    BuildContext context,
    VpnProfile profile,
  ) async {
    final credentials = await showCredentialDialog(
      context,
      fileName: profile.name,
      storageNote: '账号密码：${state.protector.description}',
    );
    if (credentials == null) return;
    state.setProfileCredentials(
      profile.id,
      username: credentials.username,
      password: credentials.password,
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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: XV.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '确定删除「${profile.name}」？删除后需要重新导入才能使用。',
                  style: XvText.caption,
                ),
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

/// 导入卡片：把「选文件」与「手动填写」两条路径固定放在一起。
///
/// 设计意图（针对原来「布局割裂」的问题）：
///
///   * **同一个位置、同一个分量**。两条路径从「页面右上角按钮 + 空状态按钮 +
///     卡片底部两行文字链」收敛成一张卡里的两个同规格入口，位置不再随
///     「有没有配置」变化，用户不用重新找。
///   * **权重有主次但规格一致**。选文件是主路径（品牌绿描边），手动填写是备选
///     （中性描边），二者结构相同：图标 + 标题 + 一句说明，整块可点。
///   * **说明写在入口里**。每条路径各自讲清楚「什么时候该用它」，
///     而不是在卡片底部堆一段通用提示。
///
/// 桌面端另有一行拖拽提示：那是最快的路径，但拖拽区在「还没有配置」时才展开，
/// 因此这里用文字点到即止，不重复放一个大的落点。
class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.state, required this.compact});

  final AppState state;

  /// 移动端排布：卡片已经是设置页里的一张卡，这里不再套一层卡片。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final fileTile = ImportActionTile(
          icon: Icons.folder_open_outlined,
          title: '选择配置文件',
          description: '从本机挑一个 .conf、.ovpn 或 .yaml 文件',
          primary: true,
          onTap: () => pickAndImportConf(context, state),
        );
        final manualTile = ImportActionTile(
          icon: Icons.edit_outlined,
          title: '手动填写',
          description: '从零填写 WireGuard、OpenVPN 或 Hysteria2 参数',
          onTap: () => startManualConfigForm(context, state),
        );

        // 窄屏并排会把「说明」压成两行以上，反而更乱，因此竖排。
        // 阈值按两个入口各自的最小可用宽度估算。
        const minTileWidth = 250;
        if (constraints.hasBoundedWidth &&
            constraints.maxWidth < minTileWidth * 2 + 10) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[fileTile, const SizedBox(height: 10), manualTile],
          );
        }
        // 横向并排时**不能**用 CrossAxisAlignment.stretch：卡片在移动端设置页里
        // 处于可滚动容器中，纵向约束是无界的，stretch 会让子项去撑满这个无界高度
        // 从而报布局错误（实测矮屏下直接崩出 21 个异常）。两个入口的内边距
        // 完全一致，本来就等高，用 start 不影响观感。
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: fileTile),
            const SizedBox(width: 10),
            Expanded(child: manualTile),
          ],
        );
      },
    );

    if (compact) return content;

    return XvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('导入配置'),
          content,
          const SizedBox(height: 10),
          Text(
            '也可以直接把配置文件拖进窗口。协议按内容自动识别，'
            '分流规则与 DNS 策略都已经内置，无需再填任何参数。',
            style: XvText.caption,
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.isActive,
    required this.hasCredentials,
    required this.onActivate,
    required this.onEditCredentials,
    required this.onRemove,
  });

  final VpnProfile profile;
  final bool isActive;

  /// 这份配置是否已经保存了账号密码。
  ///
  /// 与 `AppState.profileHasCredentials` 同义。桌面卡片此前完全没有凭据入口，
  /// 用户在导入对话框里选了「稍后填写」之后就卡住了——OpenVPN 根本无法使用，
  /// 唯一的绕法是重新导入一遍。移动端一直有这两个入口，桌面端缺失属于功能缺口。
  final bool hasCredentials;

  final VoidCallback onActivate;

  /// 补填或修改账号密码。两个状态共用这一个动作。
  final VoidCallback onEditCredentials;

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
              // 需要账号密码的配置（OpenVPN 的 auth-user-pass）与移动端一样有
              // 两种状态：还没填（红色标签 + 「填写」）和已经填好（只留「改密码」）。
              // 导入对话框里那句「不填也可以先添加，之后在「配置」页补填」承诺的
              // 就是这个入口——承诺了却没有入口，用户就只能重新导入。
              if (profile.parsed.requiresCredentials && !hasCredentials) ...<Widget>[
                RouteTag.warn('缺账号密码'),
                const SizedBox(width: 8),
                XvButton(label: '填写', onPressed: onEditCredentials),
                const SizedBox(width: 8),
              ] else if (profile.parsed.requiresCredentials) ...<Widget>[
                XvButton(label: '改密码', onPressed: onEditCredentials),
                const SizedBox(width: 8),
              ],
              if (!isActive) ...<Widget>[
                XvButton(label: '设为当前', onPressed: onActivate),
                const SizedBox(width: 8),
              ],
              XvButton(
                label: '删除',
                kind: XvButtonKind.danger,
                onPressed: onRemove,
              ),
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
          TextSpan(
            text: '$label ',
            style: TextStyle(color: XV.muted2),
          ),
          TextSpan(
            text: value,
            style: TextStyle(color: XV.text, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
