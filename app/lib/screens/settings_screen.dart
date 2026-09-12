import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../version.dart';
import '../widgets/auto_route_card.dart';
import '../widgets/common.dart';
import '../widgets/update_card.dart';
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

  /// 桌面端页面级滚动容器的 Key。
  static const Key desktopScrollKey = Key('settings-desktop-scroll');

  @override
  Widget build(BuildContext context) {
    return compact ? _buildMobile(context) : _buildDesktop(context);
  }

  // ---------------------------------------------------------------- 桌面端

  Widget _buildDesktop(BuildContext context) {
    return SingleChildScrollView(
      // 具名 Key：设置页在矮窗口下必然需要滚动，而测试与自动化要能稳定地
      // 定位到这个滚动容器（页面上还有卡片内部的滚动区域，按类型找会歧义）。
      key: desktopScrollKey,
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
          _buildTakeoverCard(compact: false),
          const SizedBox(height: 13),
          _buildSplitCard(compact: false),
          const SizedBox(height: 13),
          AutoRouteCard(state: state, compact: false),
          const SizedBox(height: 13),
          const UpdateCard(),
          const SizedBox(height: 13),
          _buildAboutCard(context, compact: false),
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

  /// 启动相关设置。
  ///
  /// 这里**只有**「导入后自动连接」一项——它是真的：`AppState.importConf`
  /// 在导入成功且当前未连接时会立刻拨号。
  ///
  /// 原先还有一项「开机自动启动并连接」。它只是把一个布尔值存进设置文件，
  /// 从来没有任何代码把它落到系统的启动项里（Windows 需要写注册表 Run 键，
  /// 安卓需要 BOOT_COMPLETED 接收器），开关拨过去不会产生任何效果。
  /// 一个拨了没反应的开关比没有这个开关更糟，因此去掉，等真正能兑现时再加回来。
  Widget _buildStartupCard() {
    return XvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('启动'),
          SettingRow(
            title: '导入配置后自动连接',
            description: '免去点一次连接的步骤',
            isLast: true,
            control: XvSwitch(
              value: state.settings.autoConnectOnImport,
              onChanged: (bool v) => state.updateSettings(
                state.settings.copyWith(autoConnectOnImport: v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 流量接管方式。
  ///
  /// 这一块此前**只有桌面端有**，移动端整张卡片缺失。两端接管方式本来就不同
  /// （桌面走系统代理、安卓走 VpnService 的 TUN），但「用什么接管、有什么限制」
  /// 这件事两边都该讲清楚，否则同一份设置在两端的信息结构就不一致了。
  ///
  /// 桌面端刻意**不提供 TUN 选项**：sing-box 的 tun 入站需要 wintun 驱动与
  /// 管理员权限，两者都不具备，选了也不会生效——那是一个安静的假承诺，
  /// 界面上写着「接管全部程序」，实际只有认系统代理的程序走隧道。
  ///
  /// [compact] 为 true 时按移动端卡片规范渲染（panel2 / 12 圆角 / 更紧的内边距），
  /// 与其它卡片保持一致。
  Widget _buildTakeoverCard({required bool compact}) {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final isLinux = defaultTargetPlatform == TargetPlatform.linux;

    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('流量接管方式'),
          SettingRow(
            title: isAndroid ? 'TUN 虚拟网卡' : '系统代理',
            description: isAndroid
                ? '由 VpnService 提供，接管全部程序（含游戏与命令行工具）。'
                : '免管理员权限，浏览器与绝大多数软件立即生效；断开时自动还原系统设置。',
            isLast: true,
            control: RouteTag.green('已启用'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              isAndroid
                  ? '安卓只能走 TUN：VpnService 的文件描述符必须在应用进程内创建，'
                        '系统代理那条路在这里不成立。因此没有可选项，接入即接管全部程序。'
                  : isLinux
                  ? '暂不支持 TUN 虚拟网卡：它需要提权的辅助进程接管路由与 DNS，'
                        '当前版本未内置。现在只有认系统代理的程序会走隧道'
                        '（浏览器与绝大多数桌面软件）；游戏、命令行工具还不覆盖，'
                        '请等待后续版本。'
                  : '暂不支持 TUN 虚拟网卡：它需要 wintun 驱动与管理员权限，'
                        '当前版本未内置。需要接管游戏、命令行工具等不认系统代理的程序时，'
                        '请等待后续版本。',
              style: XvText.caption,
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
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 6)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (compact)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '分流',
                    style: TextStyle(fontSize: 11, color: XV.muted2),
                  ),
                ),
                // 标签跟着当前模式走，写死「规则直连」在另外两种模式下是错的。
                switch (state.settings.splitMode) {
                  SplitMode.smart => RouteTag.direct('规则直连'),
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
                : 'geosite-cn · geoip-cn · 更新于 ${fmtDate(state.ruleSetUpdatedAt)}',
            control: XvButton(label: '检查更新', onPressed: state.refreshRuleSet),
          ),
          SettingRow(
            title: '记录分流日志',
            description: '关闭后不再记录任何域名',
            // 卡片最后一行不画分隔线。此前写的是 isLast: compact，桌面端因此
            // 在末行下面多出一条悬空的线，与其它卡片的处理也不一致。
            isLast: true,
            control: XvSwitch(
              value: state.settings.logSplits,
              onChanged: (bool v) =>
                  state.updateSettings(state.settings.copyWith(logSplits: v)),
            ),
          ),
        ],
      ),
    );
  }

  /// 关于：应用内读到许可全文的唯一入口。
  ///
  /// 此前分发物里一直带着 LICENSE / NOTICE.md，但应用内没有任何入口，用户
  /// 实际上读不到——「随包分发」不等于「可见」。这里用 Material 的
  /// [showLicensePage]：它会聚合 Flutter 自动生成的依赖许可，以及
  /// `registerBundledLicenses()` 注册的本项目许可、第三方声明与内核静态依赖。
  ///
  /// 版本号取自 `version.dart`，与「设置页侧栏底部」显示的是同一个值，
  /// 因此许可页不会出现与安装包对不上的版本。
  Widget _buildAboutCard(BuildContext context, {required bool compact}) {
    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 6)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('关于'),
          SettingRow(
            title: '开源许可',
            description: '查看本项目（GPL-3.0-or-later）与第三方组件的许可证全文',
            isLast: true,
            control: XvButton(
              label: '查看',
              onPressed: () => _openLicenses(context),
            ),
          ),
        ],
      ),
    );
  }

  void _openLicenses(BuildContext context) {
    showLicensePage(
      context: context,
      applicationName: 'XVPN',
      applicationVersion: appVersion,
      applicationLegalese:
          'Copyright (C) 2026 LUSIDA（Start）\n'
          'SPDX-License-Identifier: GPL-3.0-or-later',
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
                        description: '导入 .conf / .ovpn / Hysteria2 节点后直接建立隧道',
                        isLast: true,
                        control: XvSwitch(
                          value: state.settings.autoConnectOnImport,
                          onChanged: (bool v) => state.updateSettings(
                            state.settings.copyWith(autoConnectOnImport: v),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 与桌面端保持一致的信息结构：接管方式两端都讲清楚，
                // 只是内容按平台不同（桌面系统代理 / 安卓 TUN）。
                _buildTakeoverCard(compact: true),
                const SizedBox(height: 12),
                _buildSplitCard(compact: true),
                const SizedBox(height: 12),
                AutoRouteCard(state: state, compact: true),
                const SizedBox(height: 12),
                ProfilesScreen(state: state, embedded: true),
                const SizedBox(height: 12),
                const UpdateCard(compact: true),
                const SizedBox(height: 12),
                _buildAboutCard(context, compact: true),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
