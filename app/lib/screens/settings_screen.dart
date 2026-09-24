import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/auto_start.dart';
import '../core/links.dart';
import '../theme.dart';
import '../theme_controller.dart';
import '../widgets/common.dart';
import '../widgets/update_card.dart';
import 'legal_notice_dialog.dart';
import 'profiles_screen.dart';

/// 设置页。每一项都有合理默认值，不改也能正常用。
/// 移动端没有「流量接管方式」——Android 上 TUN 是唯一方式。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.state,
    required this.compact,
    required this.theme,
    this.autoStart,
    this.openExternalUrl = launchInBrowser,
  });

  final AppState state;
  final bool compact;

  /// 主题控制器。桌面端标题栏右侧也有一个切换按钮，两处共用同一份状态。
  final ThemeController theme;

  /// 「开机自动启动」的状态与原生桥。
  ///
  /// 为 null（或原生回答「当前形态用不了」）时这一行**不渲染**：一个拨了不会
  /// 有任何效果的开关比没有这个开关更糟。桌面端由 [XvShell] 传下来，与托盘
  /// 菜单共用同一个实例。
  final AutoStartController? autoStart;

  /// 打开外部链接的实现。默认交给系统浏览器；测试注入记录器断言点了哪个地址。
  ///
  /// 与标题栏 GitHub 按钮（`_GitHubButton`）同一处理由：测试环境里没有浏览器，
  /// 真实的 `url_launcher` 必然失败，无法据此断言「许可入口把人送到了哪里」。
  final ExternalUrlLauncher openExternalUrl;

  static const _themeLabels = <String>['跟随系统', '亮色', '深色'];

  /// 桌面端页面级滚动容器的 Key。
  static const Key desktopScrollKey = Key('settings-desktop-scroll');

  /// 「随系统启动」那一行的开关。
  ///
  /// 具名 Key 是给测试用的：这一行只在后端可用时才渲染，而设置页里有多个
  /// 外观相同的开关，按类型取「最后一个」会随卡片顺序变化而悄悄指错对象。
  static const Key autoStartSwitchKey = Key('settings-auto-start-switch');

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
          _buildStartupCard(compact: false),
          const SizedBox(height: 13),
          _buildTakeoverCard(compact: false),
          const SizedBox(height: 13),
          _buildLoggingCard(compact: false),
          const SizedBox(height: 13),
          // **不能写成 `const UpdateCard()`**：`XV` 的颜色是读取可变调色板的
          // 静态 getter（见 theme.dart 的 applyPalette），而 const 组件实例在
          // 重建时被判定为同一个对象（identical），子树**不会重新构建**，
          // 于是它一直显示创建时那套橙色/面板色——切到暗色主题后，同一页里只有
          // 这一张卡片没有跟着变。
          //
          // 这一页其余卡片都是方法调用（`_buildXxxCard(...)`），每次重建都是新
          // 实例，因此只有它是 const，也只有它出问题。
          UpdateCard(),
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
  /// 「导入后自动连接」是真的：`AppState.importConf` 在导入成功且当前未连接时
  /// 会立刻拨号。
  ///
  /// 「随系统启动」也是真的，而且**这次是真的落地了**：Windows 上由原生写
  /// `HKCU\...\CurrentVersion\Run`——见 windows/runner/auto_start.cc。此前这一项
  /// 只是把一个布尔值存进设置文件，从来没有任何代码把它落到系统的启动项里，
  /// 于是被去掉了；现在后端存在，因此加了回来，并且同样出现在托盘菜单上
  /// （用户可以不开设置页就切换）。
  ///
  /// 后端在当前形态下用不了时（Linux 尚未实现），这一行**整个不渲染**——见
  /// [autoStart] 的说明。
  Widget _buildStartupCard({required bool compact}) {
    final controller = autoStart;
    // 系统启动项那一行只有在后端可用时才出现，而「谁在最后」决定谁不画分隔线：
    // 写死在某一项上，另一项成为末行时就会多出一条悬空的分隔线。
    final showAutoStart = controller != null && controller.supported;

    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('启动'),
          SettingRow(
            title: compact ? '导入后自动连接' : '导入配置后自动连接',
            description: compact ? '导入配置文件或 ss:// 分享链接后直接建立隧道' : '免去点一次连接的步骤',
            isLast: !showAutoStart,
            control: XvSwitch(
              value: state.settings.autoConnectOnImport,
              onChanged: (bool v) => state.updateSettings(
                state.settings.copyWith(autoConnectOnImport: v),
              ),
            ),
          ),
          if (showAutoStart)
            // 状态由原生回读（用户在「任务管理器 → 启动」里也能改），因此这一行
            // 必须跟着控制器重建，而不是只读一次 `state.settings`。
            ListenableBuilder(
              listenable: controller,
              builder: (BuildContext context, _) => SettingRow(
                title: '随系统启动',
                description: controller.enabled ? '开机后自动运行' : '开机后自动启动幽门',
                isLast: true,
                control: XvSwitch(
                  key: autoStartSwitchKey,
                  value: controller.enabled,
                  onChanged: controller.setEnabled,
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

  /// 记录分流日志。
  ///
  /// 这一项原本长在「分流」卡片里，而分流模式与规则库搬去了独立的「分流规则」
  /// 页。它留在这里是因为它管的不是**怎么分流**，而是**要不要把观察到的东西
  /// 记下来**——一个纯记录偏好，与外观、启动同属设置页的范畴。分流记录页的
  /// 脚注也据此写着「可在设置中关闭」，两处因此仍然对得上。
  Widget _buildLoggingCard({required bool compact}) {
    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('记录'),
          SettingRow(
            title: '记录分流明细',
            description:
                '关闭后不再按域名记账，已有记录会清空。'
                '连接页的「本次连接」流量与隧道/直连占比仍会更新',
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

  /// 关于：许可与法律两条边界的入口。
  ///
  /// 两者刻意用不同的方式呈现，因为它们承担的责任不同：
  ///
  ///   * 「法律与使用声明」在应用内读全文（`legal_notice_dialog.dart`）。它说明
  ///     的是**本软件的边界**——它是客户端而不是 VPN 服务，不提供节点或订阅。
  ///     这条边界必须在离线时也读得到，否则等于一个假入口。
  ///   * 「开源许可」跳到项目主页的许可章节（`links.dart` 的 [kLicenseUrl]）。
  ///     许可证与第三方声明的正文随仓库与各平台发布包分发，这里只是把人送过去。
  ///     此前应用内自绘了一个完整的许可浏览界面，并把 `LICENSE` / `NOTICE.md` /
  ///     `THIRD-PARTY-NOTICES.md` 一起打进安装包——那 400 KB 里绝大多数是 Flutter
  ///     与内核依赖的聚合许可（111 个模块、1683 段），没有人会在手机上逐条读，
  ///     却要所有人一起付出包体。许可**必须可获取**，但不必长在应用里。
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
            title: '法律与使用声明',
            description: '本软件是自备配置的客户端，不是 VPN 服务；不提供节点或订阅',
            control: XvButton(
              label: '阅读',
              onPressed: () => showLegalNoticeDialog(context),
            ),
          ),
          SettingRow(
            title: '开源许可',
            description: '本项目为 GPL-3.0-or-later；许可证与第三方组件声明全文在项目主页',
            control: XvButton(
              label: '查看',
              onPressed: () => _openLicenses(context),
            ),
          ),
          SettingRow(
            // 作者与官网合成一项：它们回答的是同一个问题——「这是谁做的东西，
            // 出了事该去哪里看」。拆成两行只会让「关于」这张卡变成一张名片。
            title: '作者与官网',
            description: 'LUSIDA · www.lusida.net',
            isLast: true,
            control: XvButton(
              label: '访问',
              onPressed: () => _openExternal(
                context,
                kWebsiteUrl,
                label: '官方网站',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 在浏览器里打开项目主页的许可章节。
  Future<void> _openLicenses(BuildContext context) =>
      _openExternal(context, kLicenseUrl, label: '许可页面');

  /// 用系统默认浏览器打开一个外部地址。
  ///
  /// 失败不能静默：没有默认浏览器、平台通道缺失都会走到这里，而用户点了按钮
  /// 却什么都没发生，比给一条「请手动访问 …」的提示更糟。与标题栏 GitHub 按钮
  /// 同一套容错。
  ///
  /// [label] 只影响失败提示的措辞；地址本身原样给出，用户可以自己抄走。
  Future<void> _openExternal(
    BuildContext context,
    String url, {
    required String label,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool opened;
    try {
      opened = await openExternalUrl(Uri.parse(url));
    } on Object catch (error) {
      debugPrint('打开$label失败：$error');
      opened = false;
    }
    if (opened) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '无法打开浏览器，请手动访问 $url',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XV.rCtl),
          side: BorderSide(color: XV.red.withValues(alpha: 0.35)),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ---------------------------------------------------------------- 移动端

  Widget _buildMobile(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 不能用 const：它读 XV 的主题色（见 UpdateCard 那里的说明），
        // const 实例在重建时会被复用、build 不重跑，切主题后颜色不跟随。
        MobileHeader(title: '设置'),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 10),
                _buildAppearanceCard(compact: true),
                const SizedBox(height: 12),
                _buildStartupCard(compact: true),
                const SizedBox(height: 12),
                // 与桌面端保持一致的信息结构：接管方式两端都讲清楚，
                // 只是内容按平台不同（桌面系统代理 / 安卓 TUN）。
                _buildTakeoverCard(compact: true),
                const SizedBox(height: 12),
                _buildLoggingCard(compact: true),
                const SizedBox(height: 12),
                ProfilesScreen(state: state, embedded: true),
                const SizedBox(height: 12),
                // 同桌面端：不能用 const，否则切主题时不重建（原因见那里的说明）。
                UpdateCard(compact: true),
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
