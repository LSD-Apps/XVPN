import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../widgets/common.dart';
import 'profiles_screen.dart';

/// 设置页。每一项都有合理默认值，不改也能正常用。
/// 移动端没有「流量接管方式」——Android 上 TUN 是唯一方式。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.state,
    required this.compact,
    required this.theme,
  });

  final AppState state;
  final bool compact;

  /// 主题控制器。桌面端标题栏右侧也有一个切换按钮，两处共用同一份状态。
  final ThemeController theme;

  static const _splitLabels = <String>['智能分流', '全局代理', '全局直连'];
  static const _themeLabels = <String>['跟随系统', '亮色', '深色'];

  @override
  Widget build(BuildContext context) {
    return compact ? _buildMobile(context) : _buildDesktop(context);
  }

  // ---------------------------------------------------------------- 桌面端

  Widget _buildDesktop(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('设置', style: XvText.screenTitle),
              SizedBox(height: 4),
              Text('这里的每一项都有合理默认值，不改也能正常用', style: XvText.screenSubtitle),
            ],
          ),
          const SizedBox(height: 13),
          _buildAppearanceCard(compact: false),
          const SizedBox(height: 13),
          _buildStartupCard(),
          const SizedBox(height: 13),
          _buildTakeoverCard(),
          const SizedBox(height: 13),
          _buildSplitCard(compact: false),
        ],
      ),
    );
  }

  /// 外观：主题切换。
  ///
  /// 桌面端标题栏右侧那个按钮只是快捷入口，设置页这里才是完整的选项；
  /// 移动端没有标题栏，这里是唯一的入口，因此两端都必须有。
  Widget _buildAppearanceCard({required bool compact}) {
    final index = switch (theme.value) {
      ThemeMode.system => 0,
      ThemeMode.light => 1,
      ThemeMode.dark => 2,
    };
    final control = XvSegmented(
      labels: _themeLabels,
      index: index,
      expand: compact,
      onChanged: (int i) => theme.value = switch (i) {
        1 => ThemeMode.light,
        2 => ThemeMode.dark,
        _ => ThemeMode.system,
      },
    );
    const description = '跟随系统时，随系统的深色模式自动切换';

    if (compact) {
      return XvCard(
        color: XV.panel2,
        radius: 12,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const XvCardTitle('外观'),
            const SizedBox(height: 11),
            Text('主题', style: XvText.rowTitle),
            const SizedBox(height: 4),
            Text(description, style: XvText.rowDesc),
            const SizedBox(height: 10),
            control,
          ],
        ),
      );
    }

    return XvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('外观'),
          SettingRow(
            title: '主题',
            description: description,
            isLast: true,
            controlWidth: 252,
            control: control,
          ),
        ],
      ),
    );
  }

  Widget _buildStartupCard() {    return XvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('启动'),
          SettingRow(
            title: '导入配置后自动连接',
            description: '免去点一次连接的步骤',
            control: XvSwitch(
              value: state.settings.autoConnectOnImport,
              onChanged: (bool v) =>
                  state.updateSettings(state.settings.copyWith(autoConnectOnImport: v)),
            ),
          ),
          SettingRow(
            title: '开机自动启动并连接',
            description: '开机后静默建立隧道',
            isLast: true,
            control: XvSwitch(
              value: state.settings.launchAtStartup,
              onChanged: (bool v) => state.updateSettings(state.settings.copyWith(launchAtStartup: v)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTakeoverCard() {
    return XvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('流量接管方式'),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: OptionCard(
                    selected: state.settings.takeoverMode == TakeoverMode.systemProxy,
                    title: '系统代理（推荐）',
                    description: '免管理员权限，浏览器与绝大多数软件立即生效；断开时自动还原系统设置。',
                    onTap: () => state.updateSettings(
                      state.settings.copyWith(takeoverMode: TakeoverMode.systemProxy),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OptionCard(
                    selected: state.settings.takeoverMode == TakeoverMode.tun,
                    title: 'TUN 虚拟网卡',
                    description: '接管全部程序（含不认系统代理的游戏、命令行工具），需要管理员权限。',
                    onTap: () => state.updateSettings(
                      state.settings.copyWith(takeoverMode: TakeoverMode.tun),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitCard({required bool compact}) {
    final modeIndex = SplitMode.values.indexOf(state.settings.splitMode);
    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact ? const EdgeInsets.fromLTRB(14, 13, 14, 6) : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (compact)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('分流', style: TextStyle(fontSize: 11, color: XV.muted2)),
                ),
                // 标签跟着当前模式走，写死「国内直连」在另外两种模式下是错的。
                switch (state.settings.splitMode) {
                  SplitMode.smart => RouteTag.direct('国内直连'),
                  SplitMode.globalProxy => RouteTag.kind(RouteKind.proxy),
                  SplitMode.globalDirect => RouteTag.direct('全部直连'),
                },
              ],
            )
          else
            const XvCardTitle('分流'),
          if (compact) ...<Widget>[
            const SizedBox(height: 11),
            Text('分流模式', style: XvText.rowTitle),
            const SizedBox(height: 4),
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
            Divider(height: 25, thickness: 1, color: XV.line2),
          ] else
            SettingRow(
              title: '分流模式',
              description: state.settings.splitMode.description,
              controlWidth: 252,
              control: XvSegmented(
                labels: _splitLabels,
                index: modeIndex,
                onChanged: (int i) => state.updateSettings(
                  state.settings.copyWith(splitMode: SplitMode.values[i]),
                ),
              ),
            ),
          SettingRow(
            title: '规则库',
            description: compact
                ? 'geosite-cn · geoip-cn · ${fmtDate(state.ruleSetUpdatedAt)}'
                : '国内域名 geosite-cn · 国内 IP geoip-cn · 更新于 ${fmtDate(state.ruleSetUpdatedAt)}',
            control: XvButton(
              label: '检查更新',
              onPressed: state.refreshRuleSet,
            ),
          ),
          SettingRow(
            title: '记录分流日志',
            description: '关闭后不再记录任何域名',
            // 卡片最后一行不画分隔线。此前写的是 isLast: compact，桌面端因此
            // 在末行下面多出一条悬空的线，与其它卡片的处理也不一致。
            isLast: true,
            control: XvSwitch(
              value: state.settings.logSplits,
              onChanged: (bool v) => state.updateSettings(state.settings.copyWith(logSplits: v)),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 移动端

  Widget _buildMobile(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const MobileHeader(title: '设置'),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 10),
                _buildAppearanceCard(compact: true),
                const SizedBox(height: 12),
                XvCard(
                  color: XV.panel2,
                  radius: 12,
                  padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const XvCardTitle('启动'),
                      SettingRow(
                        title: '导入后自动连接',
                        description: '导入 .conf 后直接建立隧道',
                        control: XvSwitch(
                          value: state.settings.autoConnectOnImport,
                          onChanged: (bool v) => state.updateSettings(
                            state.settings.copyWith(autoConnectOnImport: v),
                          ),
                        ),
                      ),
                      SettingRow(
                        title: '开机自动连接',
                        description: '开机后静默建立隧道',
                        isLast: true,
                        control: XvSwitch(
                          value: state.settings.launchAtStartup,
                          onChanged: (bool v) => state.updateSettings(
                            state.settings.copyWith(launchAtStartup: v),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _buildSplitCard(compact: true),
                const SizedBox(height: 12),
                ProfilesScreen(state: state, embedded: true),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
