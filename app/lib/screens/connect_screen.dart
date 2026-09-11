import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/core_log.dart';
import '../core/dns_monitor.dart';
import '../format.dart';
import '../models.dart';
import '../protocols/vpn_protocol.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/connect_ring.dart';
import 'import_conf.dart';

/// 连接页。三种状态：未导入 / 未连接 / 已连接（含连接中）。
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key, required this.state, required this.compact});

  final AppState state;

  /// true 为移动端排布，false 为桌面端排布。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!state.hasProfiles) return _EmptyState(state: state, compact: compact);
    return compact ? _buildMobile(context) : _buildDesktop(context);
  }

  // ---------------------------------------------------------------- 桌面端

  Widget _buildDesktop(BuildContext context) {
    final profile = state.activeProfile!;
    // 窗口够高时让底部两张卡铺满剩余高度，界面才不显得空；
    // 窗口偏矮时退回滚动布局，避免内容被压扁或溢出。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const minimumFillHeight = 620.0;
        final body = <Widget>[
          _buildHeader(),
          const SizedBox(height: 13),
          _buildHero(context, profile, compact: false),
          const SizedBox(height: 13),
          _buildStats(),
          const SizedBox(height: 13),
        ];

        if (constraints.maxHeight < minimumFillHeight) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ...body,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 106,
                      child: IntrinsicHeight(child: _buildChecksCard(context)),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      flex: 100,
                      child: IntrinsicHeight(child: _buildRecentCard()),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ...body,
            // 铺满剩余高度：两张卡等高拉伸，最近分流内部自行滚动。
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 106, child: _buildChecksCard(context)),
                  const SizedBox(width: 13),
                  Expanded(flex: 100, child: _buildRecentCard()),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('连接', style: XvText.screenTitle),
        const SizedBox(height: 4),
        Text('分流规则由内置规则库自动应用，无需手动维护', style: XvText.screenSubtitle),
      ],
    );
  }

  // ---------------------------------------------------------------- 移动端

  Widget _buildMobile(BuildContext context) {
    final profile = state.activeProfile!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MobileHeader(
          // 头部左侧已经有应用图标，这里再写品牌名就重复了；
          // 与其它页保持一致，写页面名。
          title: '连接',
          statusLabel: switch (state.status) {
            VpnStatus.connected => '已连接',
            VpnStatus.connecting => '连接中',
            VpnStatus.disconnected => '未连接',
          },
          statusActive: state.isConnected,
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 10),
                _buildHero(context, profile, compact: true),
                const SizedBox(height: 14),
                _buildStats(),
                _buildMobileStatsFooter(),
                const SizedBox(height: 12),
                _buildMobileChecksCard(),
                const SizedBox(height: 12),
                _buildMobileSplitCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 连接状态卡

  Widget _buildHero(BuildContext context, VpnProfile profile, {required bool compact}) {
    final connected = state.isConnected;
    final connecting = state.isConnecting;

    final ring = ConnectRing(
      size: compact ? ConnectRing.mobileSize : ConnectRing.desktopSize,
      active: connected || connecting,
      icon: Icons.power_settings_new,
      title: connecting
          ? '连接中…'
          : (connected ? '已连接' : '未连接'),
      titleStyle: compact
          ? TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: connected ? XV.greenSoft : XV.muted,
            )
          : null,
      // 未连接时与桌面端计时器保持一致，显示占位而不是 00:00:00，
      // 否则会让人以为「已经连了 0 秒」。
      sublabel: compact && connected ? fmtDuration(state.elapsed) : (compact ? '--:--:--' : null),
      // 连接中不允许再次点击：圆环没有禁用态，重复触发会并发跑两遍 connect()。
      onTap: connecting ? null : state.toggleConnection,
    );

    final info = Column(
      crossAxisAlignment: compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Flexible(
              child: Text(
                profile.name,
                style: compact
                    ? TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: XV.text,
                      )
                    : XvText.heroTitle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (connected && state.latencyMs != null) ...<Widget>[
              const SizedBox(width: 10),
              _LatencyBadge(millis: state.latencyMs!),
            ],
          ],
        ),
        SizedBox(height: compact ? 5 : 12),
        if (compact)
          Text(
            '${profile.endpointDisplay}${state.latencyMs == null ? '' : ' · ${state.latencyMs} ms'}',
            style: XvText.caption,
          )
        else
          Wrap(
            spacing: 20,
            runSpacing: 9,
            children: <Widget>[
              _MetaItem(label: '服务器', value: profile.endpointDisplay),
              _MetaItem(label: '隧道地址', value: profile.tunnelAddressDisplay),
              _MetaItem(label: '分流', value: _splitDescription()),
            ],
          ),
        SizedBox(height: compact ? 0 : 16),
        if (!compact)
          Row(
            children: <Widget>[
              if (connected)
                XvButton(
                  label: '断开连接',
                  kind: XvButtonKind.danger,
                  icon: Icons.power_settings_new,
                  onPressed: state.disconnect,
                )
              else
                XvButton(
                  label: connecting ? '连接中…' : '连接',
                  kind: XvButtonKind.primary,
                  icon: Icons.bolt_outlined,
                  onPressed: connecting ? null : state.connect,
                ),
              const SizedBox(width: 10),
              XvButton(
                label: '切换配置',
                onPressed: () => _showProfilePicker(context),
              ),
            ],
          ),
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Column(
          children: <Widget>[
            ring,
            const SizedBox(height: 14),
            info,
          ],
        ),
      );
    }

    return XvCard(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ring,
          const SizedBox(width: 26),
          Expanded(child: info),
        ],
      ),
    );
  }

  String _splitDescription() => switch (state.settings.splitMode) {
        SplitMode.smart => '国内直连 · 国外走代理',
        SplitMode.globalProxy => '全部走代理',
        SplitMode.globalDirect => '全部直连',
      };

  /// 分流模式的标签。三种模式的含义完全不同，标签必须跟着变，
  /// 否则用户选了「全局代理」却看到「国内直连」，会以为设置没生效。
  Widget _splitModeTag() => switch (state.settings.splitMode) {
        SplitMode.smart => RouteTag.direct('国内直连'),
        SplitMode.globalProxy => RouteTag.kind(RouteKind.proxy),
        SplitMode.globalDirect => RouteTag.direct('全部直连'),
      };

  // ---------------------------------------------------------------- 统计

  Widget _buildStats() {
    final down = fmtRate(state.downBps);
    final up = fmtRate(state.upBps);
    final total = fmtBytes(state.totalBytes);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: _StatCard(
              label: '↓ 下载',
              value: down.value,
              unit: down.unit,
              spark: state.downHistory,
              color: XV.green,
              compact: compact,
            ),
          ),
          SizedBox(width: compact ? 10 : 13),
          Expanded(
            child: _StatCard(
              label: '↑ 上传',
              value: up.value,
              unit: up.unit,
              spark: state.upHistory,
              color: XV.green,
              compact: compact,
            ),
          ),
          // 移动端窄，放不下第三张卡，因此把「本次累计」并进下载卡的第二行，
          // 而不是直接不显示——它是用户判断「这次连上跑了多少流量」的唯一数字。
          if (!compact) ...<Widget>[
            const SizedBox(width: 13),
            Expanded(
              child: _StatCard(
                label: '本次累计',
                value: total.value,
                unit: total.unit,
                spark: state.totalHistory,
                color: XV.blue,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 移动端统计行下面的补充信息：本次累计 + 失败计数。
  ///
  /// 桌面端这两项分别由第三张卡和侧栏质量指标承担，移动端两者都没有。
  Widget _buildMobileStatsFooter() {
    final total = fmtBytes(state.totalBytes);
    final failures = state.failures.length;
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
      child: Row(
        children: <Widget>[
          Text('本次累计 ${total.value}${total.unit}', style: XvText.caption),
          const Spacer(),
          Text(
            failures == 0 ? '无失败连接' : '$failures 次失败',
            style: XvText.caption.copyWith(
              color: failures == 0 ? XV.muted2 : XV.amber,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------- 零配置校验 / 最近分流

  Widget _buildChecksCard(BuildContext context) {
    return XvCard(child: _checksBody(forceTun: false));
  }

  /// 零配置接管状态的内容。
  ///
  /// 桌面端与移动端共用同一份，避免两端各写一遍后慢慢跑偏——尤其是底部的
  /// 失败归因：那是「打不开网页到底是规则判错了还是节点不通」的唯一出口，
  /// 移动端漏掉它，检测能力就等于没有。
  ///
  /// [forceTun]：安卓上 VpnService 的 TUN 是唯一接管方式，设置页也刻意没有
  /// 「接管方式」这一项，因此这里必须写 TUN，不能跟着桌面端的设置走——
  /// 否则手机上会显示一行根本不存在的「系统代理」。
  Widget _checksBody({required bool forceTun}) {
    // 行数随状态变化（未连接 3 行、已连接最多 7 行），而卡片高度由布局决定，
    // 两者不一定匹配，因此统一走可滚动容器：够高就正常显示，不够就在卡片内
    // 滚动，而不是抛 RenderFlex overflow 或把内容裁掉。
    return XvScrollableColumn(children: _checksContent(forceTun: forceTun));
  }

  List<Widget> _checksContent({required bool forceTun}) {
    final profile = state.activeProfile!;
    final connected = state.isConnected;
    final digest = state.failureDigest;

    return <Widget>[
      const XvCardTitle('零配置接管状态'),
      CheckRow(
        // 已支持多种协议，这里跟随实际导入的配置，不再写死 WireGuard。
        title: '已导入 ${state.profiles.length} 个配置',
        detail: '${profile.name} · ${profile.protocolType.label} · 自动解析，无需填写参数',
      ),
      const SizedBox(height: 11),
      CheckRow(
        title: connected ? '智能分流已生效' : '智能分流已就绪',
        detail: '国内域名与 IP 直连，其余走隧道（规则库 2 项）',
      ),
      const SizedBox(height: 11),
      // 两端各只有一条接管路径，因此这里直接按平台写明，不再跟随设置项——
      // 桌面端此前有一个「TUN」选项，选了也不会生效（见设置页的说明）。
      if (forceTun)
        const CheckRow(
          title: 'TUN 虚拟网卡接管',
          detail: '由 VpnService 提供，接管全部程序',
        )
      else
        CheckRow(
          title: connected ? '系统代理已自动设置' : '系统代理将在连接后设置',
          detail: '127.0.0.1:2080 · 断开时自动还原',
          mono: true,
        ),
      // 出现失败时把归因结论摆到最显眼的位置：
      // 用户看到的是「网站打不开」，需要被告知是规则问题还是节点问题。
      if (digest.hasProblems) ...<Widget>[
        const SizedBox(height: 11),
        _DiagnosisRow(digest: digest),
      ],
      // 以下三块是「检测能力」的可见出口。
      //
      // 它们的共同作用是回答用户真正的疑问——「为什么有的网站打不开」。
      // 只在连上之后显示：未连接时这些探测没有意义，显示出来只会是
      // 一排「待检测」的噪音。
      if (connected) ...<Widget>[
        const SizedBox(height: 11),
        _splitVolumeRow(),
        const SizedBox(height: 11),
        _selfCheckRow(),
        const SizedBox(height: 11),
        _dnsRow(),
        _learnedRow(),
      ],
    ];
  }

  /// 分流占比：本次已传输的流量里有多少真的走了隧道。
  ///
  /// 这是判断「分流是否按预期工作」最直接的数字。原先界面上只有一个
  /// 「本次累计」，用户无法回答「这些流量到底走没走隧道」。
  ///
  /// 顺带带上活连接数与内核内存：前者反映当前负载，后者是「大数据量下
  /// 是否真的顺畅」最直接的自查指标（连接数上千时它会明显上涨）。
  Widget _splitVolumeRow() {
    final proxied = state.proxiedBytes;
    final direct = state.directBytes;
    final total = proxied + direct;
    if (total == 0) {
      return const SizedBox.shrink();
    }
    final percent = (proxied * 100 / total).round();
    final proxiedText = fmtBytes(proxied);
    final directText = fmtBytes(direct);
    final memory = fmtBytes(state.kernelMemory);
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: CheckRow(
        title: '流量分布：$percent% 走隧道',
        detail: '隧道 ${proxiedText.value}${proxiedText.unit} · '
            '直连 ${directText.value}${directText.unit} · '
            '活连接 ${state.connectionCount} 条'
            '${state.kernelMemory > 0 ? ' · 内核内存 ${memory.value}${memory.unit}' : ''}',
        mono: true,
      ),
    );
  }

  /// 启动自检结论。
  ///
  /// 它回答的是「连上了但打不开网站」时最容易搞错的那个问题：
  /// 到底是本地网络的事，还是节点的事。两者表现一样，处置方式相反。
  Widget _selfCheckRow() {
    final report = state.selfCheckReport;
    if (report == null) {
      return CheckRow(
        title: '正在自检两条路径…',
        detail: '分别验证国内直连与隧道出口是否可用',
      );
    }
    return CheckRow(
      title: report.hasFailures ? report.conclusion : '自检通过 · ${report.conclusion}',
      detail: report.advice,
      warn: report.hasFailures,
    );
  }

  /// DNS 健康状况。
  Widget _dnsRow() {
    final report = state.dnsReport;
    if (report == null || report.isEmpty) {
      return const CheckRow(
        title: '正在探测 DNS…',
        detail: '国内解析器与隧道解析器分别计时，并交叉校验解析结果',
      );
    }
    final abnormal = report.resolvers.any((ResolverHealth h) => h.consecutiveFailures > 0);
    return CheckRow(
      title: 'DNS · ${report.verdict.label}',
      detail: '${report.summary} · ${report.verdict.advice}',
      warn: abnormal || report.verdict == DnsVerdict.suspectPoisoning,
      mono: true,
    );
  }

  /// 「程序自己学会了什么」。
  ///
  /// 自动纠正是在背后改路由的，如果不告诉用户，他只会觉得
  /// 「有时候能连有时候不能」。这里把学到的判断摆出来，并允许一键撤销。
  Widget _learnedRow() {
    final learned = state.learnedDecisions;
    if (learned.isEmpty) return const SizedBox.shrink();
    final first = learned.first;
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: CheckRow(
        title: '已自动纠正 ${learned.length} 个域名的分流',
        detail: '${first.domain}：${first.reason}',
        warn: true,
      ),
    );
  }

  /// 移动端的同一张卡：配色与留白跟随移动端卡片规范。
  Widget _buildMobileChecksCard() {
    return XvCard(
      color: XV.panel2,
      radius: 12,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: _checksBody(forceTun: true),
    );
  }

  /// 最近分流。
  ///
  /// 卡片本身铺满可用高度，列表超出时在卡片内部滚动——这样无论窗口多高，
  /// 卡片都不会被内容撑破，也不会留下大片空白。
  Widget _buildRecentCard() {
    final records = state.records;
    return XvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('最近分流'),
          if (records.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  '连接后这里会显示每一条连接走了直连还是代理',
                  textAlign: TextAlign.center,
                  style: XvText.caption,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: records.length,
                itemBuilder: (BuildContext context, int i) =>
                    _RecordRow(record: records[i], showRule: true),
              ),
            ),
        ],
      ),
    );
  }

  /// 移动端的「智能分流」卡片，对应原型 M2 底部那一块。
  Widget _buildMobileSplitCard() {
    final records = state.records.take(3).toList(growable: false);
    final dotColor = <RouteKind, Color>{
      RouteKind.proxy: XV.violet,
      RouteKind.direct: XV.blue,
    };

    return XvCard(
      color: XV.panel2,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  // 跟着真实的分流模式走。此前这里写死「智能分流」，
                  // 选了全局代理/全局直连后仍在显示智能分流，是错误信息。
                  '${state.settings.splitMode.label} · ${state.isConnected ? '已启用' : '待连接'}',
                  style: TextStyle(fontSize: 11, color: XV.muted2),
                ),
              ),
              _splitModeTag(),
            ],
          ),
          const SizedBox(height: 11),
          if (records.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('暂无分流记录', textAlign: TextAlign.center, style: XvText.caption),
            )
          else
            for (final record in records)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: dotColor[record.kind],
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        record.target,
                        style: XvText.bodyMuted.copyWith(color: XV.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    RouteTag.kind(record.kind),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 选择配置

  Future<void> _showProfilePicker(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: XV.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(XV.rCard),
            side: BorderSide(color: XV.line),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('切换配置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: XV.text)),
                  const SizedBox(height: 12),
                  for (final p in state.profiles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            state.setActiveProfile(p.id);
                            Navigator.of(dialogContext).pop();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(XV.rCtl),
                              color: p.id == state.activeProfile?.id ? XV.panel3 : Colors.transparent,
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(p.name, style: XvText.bodyMuted.copyWith(color: XV.text)),
                                      const SizedBox(height: 3),
                                      Text(p.endpointDisplay, style: XvText.monoSmall),
                                    ],
                                  ),
                                ),
                                if (p.id == state.activeProfile?.id) RouteTag.green('当前'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      XvButton(label: '关闭', onPressed: () => Navigator.of(dialogContext).pop()),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ 子组件

class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.millis});

  final int millis;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: XV.green.withValues(alpha: 0.1),
        border: Border.all(color: XV.green.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '延迟 $millis ms',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: XV.greenSoft),
      ),
    );
  }
}

/// 分流诊断行：把「打不开」翻译成用户能理解的结论。
///
/// 与绿色的 CheckRow 刻意区分开——那条是「一切正常」，这条是「有问题，
/// 而且问题在哪」。这正是检测能力的价值：用户不需要懂分流规则，
/// 只需要知道该换节点还是该反馈规则缺失。
class _DiagnosisRow extends StatelessWidget {
  const _DiagnosisRow({required this.digest});

  final FailureDigest digest;

  @override
  Widget build(BuildContext context) {
    final suspected = digest.suspectedMissingRules;
    // 疑似规则未覆盖属于「我们能改」的问题，用琥珀色提示；
    // 纯粹的节点失败用红色，表示问题在外部。
    final alarming = suspected.isNotEmpty;
    final accent = alarming ? XV.amber : XV.red;
    final fg = alarming ? XV.amberSoft : XV.redSoft;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 17,
          height: 17,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.withValues(alpha: 0.12),
            border: Border.all(color: accent.withValues(alpha: 0.32)),
          ),
          child: Center(
            child: Text('!', style: TextStyle(fontSize: 10, height: 1, color: fg)),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                alarming ? '有连接被判为直连但失败（疑似规则未覆盖）' : '有连接失败，但判定正常',
                style: XvText.bodyMuted.copyWith(color: XV.text, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(digest.advice, style: XvText.caption),
              if (suspected.isNotEmpty) ...<Widget>[
                const SizedBox(height: 5),
                Text(
                  suspected.take(4).join('   ·   '),
                  style: XvText.monoSmall.copyWith(color: fg),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MetaItem extends StatelessWidget {  const _MetaItem({required this.label, required this.value});

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

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.spark,
    required this.color,
    this.compact = false,
  });

  final String label;
  final String value;
  final String unit;
  final List<double> spark;
  final Color color;

  /// 移动端的卡片规范与桌面端不同：设计稿里移动统计卡是 panel2 底 + 12 圆角
  /// + 更紧的内边距（`.m-stat`），而不是桌面的 panel + rCard。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return XvCard(
      color: compact ? XV.panel2 : null,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(13, 12, 13, 12)
          : const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: XvText.statLabel),
          SizedBox(height: compact ? 6 : 8),
          RichText(
            text: TextSpan(
              style: XvText.statValue,
              children: <InlineSpan>[
                TextSpan(text: value),
                TextSpan(text: ' $unit', style: XvText.statUnit),
              ],
            ),
          ),
          SizedBox(height: compact ? 7 : 9),
          Sparkline(values: spark, color: color),
        ],
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record, this.showRule = false});

  final SplitRecord record;
  final bool showRule;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              record.target,
              style: XvText.bodyMuted.copyWith(color: XV.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showRule) ...<Widget>[
            Expanded(
              child: Text(
                record.rule,
                style: XvText.caption,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
          ],
          RouteTag.kind(record.kind),
        ],
      ),
    );
  }
}

/// 空状态：只做一件事 —— 让用户把文件弄进来。
///
/// 桌面端整块区域都是拖拽落点（对应原型里「把 .conf 拖到这里」的承诺）；
/// 移动端没有拖拽，只保留文件选择器。两者都额外提供粘贴入口作为兜底。
class _EmptyState extends StatefulWidget {
  const _EmptyState({required this.state, required this.compact});

  final AppState state;
  final bool compact;

  @override
  State<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<_EmptyState> {
  bool _dragging = false;

  AppState get state => widget.state;
  bool get compact => widget.compact;

  @override
  Widget build(BuildContext context) {
    return compact ? _buildMobile(context) : _buildDesktop(context);
  }

  Widget _buildMobile(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const MobileHeader(title: '连接', statusLabel: '未连接'),
        Expanded(
          // 空间够时垂直居中，不够时（手机横屏、分屏、大字号）可以滚。
          // 直接放 Column 会在矮屏上抛 RenderFlex overflow。
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
              Container(
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  color: XV.panel3,
                  border: Border.all(color: XV.line),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(Icons.file_upload_outlined, size: 29, color: XV.muted),
              ),
              const SizedBox(height: 20),
              Text(
                '导入配置',
                style: TextStyle(fontSize: 17.5, fontWeight: FontWeight.w700, color: XV.text),
              ),
              const SizedBox(height: 10),
              Text(
                '选择一个 WireGuard .conf 文件\n其余设置已经内置好了',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: XV.muted, height: 1.85),
              ),
              const SizedBox(height: 24),
              XvButton(
                label: '选择 .conf 文件',
                kind: XvButtonKind.primary,
                icon: Icons.folder_open_outlined,
                expand: true,
                height: 46,
                onPressed: () => pickAndImportConf(context, state),
              ),
              const SizedBox(height: 14),
              _PasteLink(onTap: () => startConfPasteDialog(context, state)),
              const SizedBox(height: 20),
              Padding(
                padding: EdgeInsets.only(bottom: 30),
                child: Text(
                  '首次连接时系统会询问 VPN 授权，允许即可',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: XV.muted2, height: 1.75),
                ),
              ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktop(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: XV.panel3,
                      border: Border.all(color: XV.line),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: Icon(Icons.file_upload_outlined, size: 27, color: XV.muted),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '导入你的 WireGuard 配置',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: XV.text),
                  ),
                  const SizedBox(height: 11),
                  Text(
                    '把 .conf 文件拖进来就行。分流规则已经内置，不需要填写任何 IP 段、规则或路由表。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: XV.muted, height: 1.8),
                  ),
                  const SizedBox(height: 26),
                  DropTarget(
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: (DropDoneDetails detail) {
                      setState(() => _dragging = false);
                      if (detail.files.isEmpty) return;
                      importConfFromPath(state, detail.files.first.path);
                    },
                    child: DashedBox(
                      highlighted: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
                        child: Column(
                          children: <Widget>[
                            Text(
                              _dragging ? '松开鼠标即可导入' : '把 .conf 文件拖到这里',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: XV.text,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: XV.green.withValues(alpha: 0.08),
                                border: Border.all(color: XV.green.withValues(alpha: 0.2)),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '.conf',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: XV.green,
                                  fontFamilyFallback: XV.monoFallback,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      XvButton(
                        label: '选择 .conf 文件',
                        kind: XvButtonKind.primary,
                        onPressed: () => pickAndImportConf(context, state),
                      ),
                      const SizedBox(width: 10),
                      XvButton(
                        label: '粘贴配置内容',
                        onPressed: () => startConfPasteDialog(context, state),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    '支持标准 WireGuard 客户端导出的 .conf（含 wg-quick 生成的配置）\n'
                    '配置只保存在本机，不会上传；导入后自动连接并完成分流',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: XV.muted2, height: 1.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 次级入口：粘贴配置文本。样式刻意弱化，不抢主按钮。
class _PasteLink extends StatelessWidget {
  const _PasteLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          child: Text(
            '或粘贴配置内容',
            style: TextStyle(fontSize: 12, color: XV.muted2),
          ),
        ),
      ),
    );
  }
}

