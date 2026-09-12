import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/core_log.dart';
import '../core/dns_monitor.dart';
import '../core/screen_navigation.dart';
import '../core/wireguard_handshake.dart';
import '../format.dart';
import '../models.dart';
import '../protocols/vpn_protocol.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/connect_ring.dart';
import 'failures_dialog.dart';
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
          // 顶部原本还有「连接」标题、一行副标题和一个状态标签，现已移除：
          // 状态由圆环本身表达（未连接 / 连接中 / 正在建立隧道 / 已连接），
          // 再在页头重复一遍只是噪音，而且占掉了首屏最宝贵的高度。
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

  // 桌面端页头已整体移除：原来有「连接」标题、一行副标题和一个状态标签，
  // 三者都不带来新信息——标题与侧边栏当前项重复，副标题是泛泛的说明，
  // 状态则由圆环表达。去掉之后首屏可以把高度留给连接卡与统计。

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
          // 状态标签不再显示：圆环里已经写着当前状态，页头再来一颗状态点是重复
          // 信息；而且两者可能因为刷新时机不同而短暂不一致，反而让人怀疑。
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
                _buildMobileChecksCard(context),
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

  Widget _buildHero(
    BuildContext context,
    VpnProfile profile, {
    required bool compact,
  }) {
    final connected = state.isConnected;
    // connecting 与 warmingUp 对「主控件该做什么」完全一致：都表示一次尝试
    // 正在飞，此时点它是取消。合并成一个判断，避免两处各写一遍后走偏。
    final busy = state.isConnecting;

    final ring = ConnectRing(
      size: compact ? ConnectRing.mobileSize : ConnectRing.desktopSize,
      active: connected || busy,
      icon: Icons.power_settings_new,
      // 预热与「连接中」必须分开说：内核其实已经就绪，用户此时点取消也是有
      // 意义的，含混成一句「连接中…」会让人以为还在启动阶段。
      title: state.isWarmingUp
          ? '正在建立隧道…'
          : (busy ? '连接中…' : (connected ? '已连接' : '未连接')),
      // 预热期间叠加流转弧：这一段要等几秒到二十秒，光有一句静止的文案
      // 看不出程序在动还是卡住了。
      warmup: state.isWarmingUp,
      titleStyle: compact
          ? TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: connected ? XV.greenSoft : XV.muted,
            )
          : null,
      // 建立隧道期间圆环是可点的，且必须一眼看出点它是「取消」：一份坏配置的
      // 预热会一直卡到门控超时（最多 20 秒），没有出口就只能干等。此前这里
      // 在连接中直接传 null，把整个取消诉求挡掉了。
      sublabel: busy
          ? '点击取消'
          : (compact && connected
                ? fmtDuration(state.elapsed)
                : (compact ? '--:--:--' : null)),
      onTap: busy ? state.cancelConnect : state.toggleConnection,
    );

    final info = Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
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
              else if (busy)
                // 连接中 / 建立隧道中：主按钮变成取消，而不是一个点不动的
                // 「连接中…」。坏配置的预热会一直等到门控超时，必须给出口。
                XvButton(
                  label: '取消连接',
                  icon: Icons.close,
                  onPressed: state.cancelConnect,
                )
              else
                XvButton(
                  label: '连接',
                  kind: XvButtonKind.primary,
                  icon: Icons.bolt_outlined,
                  onPressed: state.connect,
                ),
              const SizedBox(width: 10),
              XvButton(
                label: '切换配置',
                onPressed: () => showProfilePicker(context, state),
              ),
            ],
          ),
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Column(
          children: <Widget>[ring, const SizedBox(height: 14), info],
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
    return XvCard(child: _checksBody(context, forceTun: false));
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
  Widget _checksBody(BuildContext context, {required bool forceTun}) {
    // 行数随状态变化（未连接 3 行、已连接最多 7 行），而卡片高度由布局决定，
    // 两者不一定匹配，因此统一走可滚动容器：够高就正常显示，不够就在卡片内
    // 滚动，而不是抛 RenderFlex overflow 或把内容裁掉。
    //
    // 标题走 header 而不是放进 children：否则卡片内部一滚动，标题就跟着滚出去，
    // 用户滚下去看内容时看不出这块在讲什么。
    final content = _checksContent(context, forceTun: forceTun);
    return XvScrollableColumn(
      header: content.isNotEmpty ? content.first : null,
      children: content.length > 1 ? content.sublist(1) : const <Widget>[],
    );
  }

  List<Widget> _checksContent(BuildContext context, {required bool forceTun}) {
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
        const CheckRow(title: 'TUN 虚拟网卡接管', detail: '由 VpnService 提供，接管全部程序')
      else
        CheckRow(
          title: connected ? '系统代理已自动设置' : '系统代理将在连接后设置',
          // 地址取自内核的**实际**值：默认 2080 被占用时会换一个，
          // 写死 2080 等于给用户一个抄不走、也用不上的地址。
          detail: '${state.takeOverEndpoint} · 断开时自动还原',
          mono: true,
        ),
      // 出现失败时把归因结论摆到最显眼的位置：
      // 用户看到的是「网站打不开」，需要被告知是规则问题还是节点问题。
      // 详细的失败列表在分流记录页，这里只给结论与入口。
      if (digest.hasProblems) ...<Widget>[
        const SizedBox(height: 11),
        _DiagnosisRow(
          digest: digest,
          onShowDetail: () => showFailuresDialog(context, state),
        ),
      ],
      // 握手状态：放在最前面，因为它是「连不上时唯一能区分病因」的证据。
      //
      // 只在预热与已连接时显示：断开之后握手状态停留在上一次的结论上，
      // 把它留在界面上会让用户拿着旧结论排查这一次。
      if (state.isWarmingUp || connected) ...<Widget>[
        const SizedBox(height: 11),
        _handshakeRow(),
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
        _dnsRow(context),
        _learnedRow(),
      ],
      // MTU 校验：与「连上之后才显示」的那几块不同，它只依赖配置里声明的 MTU
      // 与探测结果，未连接时也应有明确说法（而不是一片空白让用户以为漏了）。
      const SizedBox(height: 11),
      _mtuRow(forceTun: forceTun),
      // 内核日志入口。
      //
      // 刻意**不受**「只在连上时显示」的限制：最该翻日志的时刻恰恰是没连上的
      // 时候。此前这 40 行日志只在一句错误信息里露出最后一行，用户遇到问题
      // 除了描述现象，没有任何可供排查的原始材料。
      if (state.kernelLog.isNotEmpty) ...<Widget>[
        const SizedBox(height: 11),
        _kernelLogRow(context),
      ],
    ];
  }

  /// 「隧道握手」这一行。
  ///
  /// 之所以值得占一行：**连不上时它是唯一能把病因分开的证据**。同样一句
  /// 「连不上」，握手「已应答」说明密钥与 UDP 通路都成立、问题在数据面；
  /// 握手「无应答」则说明本客户端压根没被受理（对端公钥不对、服务端没配这个
  /// peer、UDP 被挡）——两者的处置方式完全相反。
  ///
  /// 状态未知时**不显示**：可能是这份配置不是 WireGuard，内核换了措辞，
  /// 或者**本平台根本不产生握手日志**（见
  /// [VpnCore.supportsHandshakeState]）。与其显示一个永远停在「正在读取…」
  /// 的占位让人以为程序卡住了，不如少说一句。
  Widget _handshakeRow() {
    if (!state.handshakeVisible) return const SizedBox.shrink();
    if (state.activeProfile?.protocolType != VpnProtocol.wireGuard) {
      return const SizedBox.shrink();
    }

    final handshake = state.handshake;
    if (!handshake.isKnown) {
      // 是 WireGuard、平台也支持，但还没认出日志（刚点连接的头一两百毫秒）。
      return const CheckRow(title: '隧道握手', detail: '正在读取内核握手状态…');
    }

    final peer = handshake.peerPublicKey;
    return CheckRow(
      title: '隧道握手',
      detail: peer == null ? handshake.summary : '${handshake.summary} · $peer',
      mono: true,
      // 只有「已应答」才是好消息。等待中与无应答都标成需要注意：前者可能是
      // 正常握手过程，也可能是永远不会来的应答，用户看到黄色才知道要多等一会。
      warn: handshake.phase != HandshakePhase.responded,
    );
  }

  /// 「内核日志」入口。
  ///
  /// 卡片里只放行数与最后一行（多数时候它就是结论），完整内容进弹窗看——
  /// 几百行日志塞进这张卡会把它撑爆，而用户九成时候只需要知道「最近说了什么」。
  Widget _kernelLogRow(BuildContext context) {
    final lines = state.kernelLog;
    final dropped = state.kernelLogDropped;
    return CheckRow(
      title: dropped > 0
          ? '内核日志 ${lines.length} 行（更早的 $dropped 行已滚出）'
          : '内核日志 ${lines.length} 行',
      detail: lines.isEmpty ? '' : lines.last,
      mono: true,
      action: TapAction(label: '查看', onTap: () => _showKernelLog(context)),
    );
  }

  /// 完整日志弹窗：可选中、可复制、可清空。
  ///
  /// 「复制」是这里最重要的动作——用户要把日志发出来求助时，手抄几百行不现实。
  Future<void> _showKernelLog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder:
            (
              BuildContext context,
              void Function(void Function()) setDialogState,
            ) {
              final lines = state.kernelLog;
              final dropped = state.kernelLogDropped;
              return Dialog(
                backgroundColor: XV.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(XV.rCard),
                  side: BorderSide(color: XV.line),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 680,
                    maxHeight: 560,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '内核日志',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: XV.text,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '内核自己写下的原始记录。分流判定、连接失败原因都在这里，'
                          '反馈问题时请一并附上。',
                          style: XvText.caption,
                        ),
                        if (dropped > 0) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            '只保留最近 ${state.kernelLog.length} 行，更早的 $dropped 行已滚出。',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: XV.amberSoft,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Flexible(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: XV.field,
                              border: Border.all(color: XV.line),
                              borderRadius: BorderRadius.circular(XV.rCtl),
                            ),
                            child: SingleChildScrollView(
                              // 打开时直接停在最新一行：用户关心的是「刚才发生了什么」。
                              reverse: true,
                              child: SelectableText(
                                lines.isEmpty ? '（暂无日志）' : lines.join('\n'),
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.6,
                                  color: XV.text,
                                  fontFamilyFallback: XV.monoFallback,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                '${lines.length} 行',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: XV.muted2,
                                ),
                              ),
                            ),
                            XvButton(
                              label: '清空',
                              onPressed: () {
                                state.clearKernelLog();
                                setDialogState(() {});
                              },
                            ),
                            const SizedBox(width: 8),
                            XvButton(
                              label: '复制全部',
                              kind: XvButtonKind.primary,
                              onPressed: lines.isEmpty
                                  ? null
                                  : () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: lines.join('\n')),
                                      );
                                      if (dialogContext.mounted) {
                                        Navigator.of(dialogContext).pop();
                                      }
                                    },
                            ),
                            const SizedBox(width: 8),
                            XvButton(
                              label: '关闭',
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
      ),
    );
  }

  /// 分流占比：本次会话里有多少流量真的进了隧道。
  ///
  /// 口径改动过，原因值得记下来：**原来用的是「当前活连接」的字节快照**，而
  /// 内核只按出站给出每条连接的用量、没有分出站的历史累计。HTTP 请求大多在
  /// 一秒内结束，1 秒一次的轮询基本抓不到它们，于是这个数字常年停在 0%——
  /// 面板看起来「永远不变」，而隧道其实一直在正常工作。
  ///
  /// 现在改用状态层逐轮累加出来的会话累计值（`sessionProxiedBytes`），
  /// 它随流量增长，并且不受连接存活时间影响。
  Widget _splitVolumeRow() {
    final proxied = state.sessionProxiedBytes;
    final direct = state.sessionDirectBytes;
    final total = proxied + direct;
    if (total == 0) {
      // 还没有任何可归属的流量时不显示，避免给出一行恒为 0% 的假数据。
      return const SizedBox.shrink();
    }
    final percent = (proxied * 100 / total).round();
    final proxiedText = fmtBytes(proxied);
    final directText = fmtBytes(direct);
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: CheckRow(
        title: '本次分流：$percent% 走隧道',
        detail:
            '隧道 ${proxiedText.value}${proxiedText.unit} · '
            '直连 ${directText.value}${directText.unit} · '
            '当前活连接 ${state.connectionCount} 条',
        mono: true,
      ),
    );
  }

  /// 启动自检结论。
  ///
  /// 它回答的是「连上了但打不开网站」时最容易搞错的那个问题：
  /// 到底是本地网络的事，还是节点的事。两者表现一样，处置方式相反。
  ///
  /// 结论是**一次采样**的结果：自检每 10 分钟自动重跑一次，但用户遇到
  /// 「刚才还好好的」时不该干等下一个周期，因此行尾给了重测入口。
  Widget _selfCheckRow() {
    final report = state.selfCheckReport;
    if (report == null) {
      return CheckRow(
        title: '正在自检两条路径…',
        detail: '分别验证国内直连与隧道出口是否可用',
        action: TapAction(
          label: '重测',
          onTap: () => unawaited(state.runSelfCheck()),
        ),
      );
    }
    return CheckRow(
      title: report.hasFailures
          ? report.conclusion
          : '自检通过 · ${report.conclusion}',
      detail: report.advice,
      warn: report.hasFailures,
      action: TapAction(
        label: '重测',
        onTap: () => unawaited(state.runSelfCheck()),
      ),
    );
  }

  /// DNS 健康状况。
  ///
  /// 与自检同理：这是一次采样的结论（每 45 秒自动重测），也给一个手动重测入口。
  Widget _dnsRow(BuildContext context) {
    final report = state.dnsReport;
    final retry = TapAction(
      label: '重测',
      onTap: () => unawaited(state.refreshDns()),
    );
    if (report == null || report.isEmpty) {
      return CheckRow(
        title: '正在探测 DNS…',
        detail: '国内解析器与隧道解析器分别计时，并交叉校验解析结果',
        action: retry,
      );
    }
    // 告警只给「真的该让用户注意」的情况。
    //
    // 此前用的是 `consecutiveFailures > 0`，也就是**丢一个 UDP 包就变黄**：文字
    // 里写着「一致」，颜色却在报警。用户看到的是「DNS 检测一直提示异常」，而
    // 探测本身完全正常。现在与结论共用同一个门槛（[ResolverHealth.downThreshold]），
    // 颜色与文字不再互相矛盾。
    final abnormal = report.resolvers.any((ResolverHealth h) => h.isDown);
    return CheckRow(
      title: 'DNS · ${report.verdict.label}',
      detail: '${report.summary} · ${report.verdict.advice}',
      warn: abnormal || report.verdict == DnsVerdict.suspectPoisoning,
      mono: true,
      // 两个入口各有用处：重测是「刚才还好好的」时的第一反应，详情是
      // 「为什么慢」的唯一出口。挤在一行里但都不省略。
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          retry,
          const SizedBox(width: 2),
          TapAction(label: '详情', onTap: () => _showDnsDetail(context)),
        ],
      ),
    );
  }

  /// DNS 明细弹窗。
  ///
  /// 存在的理由：这一行只能放一句结论，而「DNS 检测」采集到的**关键证据**全在
  /// 每个解析器身上——哪一台、多快、失败过几次。这些字段此前被完整地算出来、
  /// 却没有任何界面读取（[ResolverHealth] 的 server / lastMillis / statusLabel
  /// 都只用于一个 `isDown` 判断），于是「为什么慢」这个问题在产品里问不出来。
  /// 弹窗把原始证据摆出来，用户与排查者都能自己下判断。
  Future<void> _showDnsDetail(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (BuildContext dialogContext) => Dialog(
        backgroundColor: XV.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XV.rCard),
          side: BorderSide(color: XV.line),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'DNS 明细',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: XV.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '国内解析器与隧道解析器分别计时，并交叉校验同一个域名的答案。'
                  '这里的数字是最近若干次探测的滚动窗口。',
                  style: XvText.caption,
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _dnsLine(
                          '结论',
                          '${_dnsVerdictOf()} · ${_dnsAdviceOf()}',
                        ),
                        const SizedBox(height: 10),
                        _dnsLine('直连解析', _windowText(_dnsReportOf().direct)),
                        const SizedBox(height: 6),
                        _dnsLine('隧道解析', _windowText(_dnsReportOf().tunnel)),
                        const SizedBox(height: 14),
                        Text(
                          '解析器',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: XV.muted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ..._dnsReportOf().resolvers.map(_dnsResolverRow),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: XvButton(
                    label: '关闭',
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 当前报告；还没有探测结果时给一份空报告。
  ///
  /// 弹窗必须在任何时刻都能打开（用户可能在首轮探测完成前就点进来），
  /// 因此不能假设报告已经存在。
  DnsReport _dnsReportOf() =>
      state.dnsReport ??
      DnsReport(
        checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
        resolvers: const <ResolverHealth>[],
        direct: LatencyWindow(capacity: 1),
        tunnel: LatencyWindow(capacity: 1),
        verdict: DnsVerdict.unknown,
      );

  String _dnsVerdictOf() => _dnsReportOf().verdict.label;

  String _dnsAdviceOf() => _dnsReportOf().verdict.advice;

  /// 一个耗时窗口的可读描述。没有样本时如实说「还没有样本」。
  String _windowText(LatencyWindow window) {
    if (window.isEmpty) return '还没有样本';
    final median = window.median;
    final p95 = window.p95;
    return '中位 ${median}ms · p95 ${p95}ms · ${window.length} 次采样';
  }

  Widget _dnsResolverRow(ResolverHealth health) {
    final accent = health.isDown
        ? XV.redSoft
        : (health.isFlaky ? XV.amberSoft : XV.greenSoft);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 128,
            child: Text(
              health.server,
              style: XvText.monoSmall.copyWith(color: accent),
            ),
          ),
          SizedBox(width: 40, child: Text(health.role, style: XvText.caption)),
          Expanded(
            child: Text(
              '${health.statusLabel}'
              '${health.lastMillis == null ? '' : ' · ${health.lastMillis}ms'}'
              ' · 失败 ${health.failures}/${health.samples}'
              '${health.lastMillis == null ? '' : ' · ${health.lastSummary}'}',
              style: XvText.caption,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dnsLine(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 72, child: Text(label, style: XvText.caption)),
        Expanded(
          child: Text(value, style: XvText.bodyMuted.copyWith(color: XV.text)),
        ),
      ],
    );
  }

  /// 「配置的 MTU 在这个节点上能不能用」。
  ///
  /// 只在 TUN 模式下说明「由内核自行处理」：安卓端没有本地混合入站端口，也就
  /// 没有可校验的入口。两端**都显示这一行**，只是内容按平台给——呈现结构一致、
  /// 能力差异写明，而不是桌面有、移动没有。
  ///
  /// 未校验时显示「待校验」而不是隐藏：隐藏会让用户不确定这项检查是否存在。
  Widget _mtuRow({required bool forceTun}) {
    if (forceTun) {
      return const CheckRow(title: 'MTU', detail: 'TUN 模式下按配置下发，分片由内核自行处理');
    }

    final retry = TapAction(
      label: '重测',
      onTap: () => unawaited(state.recheckMtu()),
    );
    final check = state.mtuCheck;

    if (check == null) {
      return CheckRow(
        title: 'MTU 校验',
        detail: '连接后会按配置的 MTU 往隧道里推一个包，确认这个值真的能用',
        action: retry,
      );
    }

    final summary = check.summary;
    if (summary == null) {
      return CheckRow(title: 'MTU 校验', detail: '配置里没有声明 MTU，使用内核默认值，无需校验');
    }

    return CheckRow(
      title: 'MTU 校验',
      // 结论本身已经带上了用户能采取的动作（例如「可尝试下调」），
      // 这里不再拼接建议，避免同一句话出现两遍。
      detail: summary,
      warn: check.isProblem,
      mono: true,
      action: retry,
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
  Widget _buildMobileChecksCard(BuildContext context) {
    return XvCard(
      color: XV.panel2,
      radius: 12,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: _checksBody(context, forceTun: true),
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
              // 右侧留出滚动条的宽度。
              //
              // 桌面端 Flutter 的 Material 滚动行为会**自动**给可滚动区域叠一条
              // 滚动条，而它是浮在内容之上的、不占布局宽度。列表原先用
              // `padding: EdgeInsets.zero`，于是滚动条正好压在行内容（末尾的
              // 判定标签与时间）上，看起来像是重叠。留 10px 之后两者互不遮挡。
              child: ListView.builder(
                padding: const EdgeInsets.only(right: 10),
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
              child: Text(
                '暂无分流记录',
                textAlign: TextAlign.center,
                style: XvText.caption,
              ),
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
}

// ---------------------------------------------------------------- 选择配置

/// 打开「切换配置」弹窗。
///
/// 做成顶层函数而不是 `ConnectScreen` 的私有方法，是为了能在**空配置**下直接
/// 测到它：连接页在没有配置时走的是导入引导，根本不渲染「切换配置」按钮，而空
/// 列表恰恰是这个弹窗最该帮上忙的时候——用户需要一条去添加配置的路。测试从这
/// 个入口单独打开弹窗，不依赖按钮是否渲染。
Future<void> showProfilePicker(BuildContext context, AppState state) async {
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
                Text(
                  '切换配置',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: XV.text,
                  ),
                ),
                const SizedBox(height: 12),
                if (state.profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('还没有导入任何配置', style: XvText.caption),
                  )
                else
                  // 配置多时必须能滚。弹窗高度受屏幕限制，把全部行直接排进
                  // Column 会在配置较多时抛 RenderFlex overflow。
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
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
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 11,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(
                                        XV.rCtl,
                                      ),
                                      color: p.id == state.activeProfile?.id
                                          ? XV.panel3
                                          : Colors.transparent,
                                    ),
                                    child: Row(
                                      children: <Widget>[
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              Text(
                                                p.name,
                                                style: XvText.bodyMuted
                                                    .copyWith(color: XV.text),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                p.endpointDisplay,
                                                style: XvText.monoSmall,
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (p.id == state.activeProfile?.id)
                                          RouteTag.green('当前'),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                // 引导入口：「切换配置」只解决「切到已有哪一份」，用户想新增
                // 一份时由这里给出去配置页的路。措辞沿用配置页里两条导入路径
                // 的原文（「选择配置文件」「手动填写」），不另造同义词。
                ImportActionTile(
                  icon: Icons.tune,
                  title: '管理 / 添加配置',
                  description: '用「选择配置文件」或「手动填写」添加新配置',
                  onTap: () {
                    // 先关弹窗再发出跳转意图：用户看到的是弹窗消失、页面切
                    // 过去，而不是弹窗仍盖在新页面上。跳转本身由外壳监听
                    // [ScreenNavigation] 完成——页面这一层够不到外壳的索引。
                    Navigator.of(dialogContext).pop();
                    ScreenNavigation.instance.request(AppSection.profiles);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    XvButton(
                      label: '关闭',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
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
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: XV.greenSoft,
        ),
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
  const _DiagnosisRow({required this.digest, this.onShowDetail});

  final FailureDigest digest;

  /// 打开完整失败记录的入口。
  ///
  /// 结论一行讲得完，证据讲不完。此前这里只给结论与四个域名，用户想深究
  /// 就只能自己去翻内核日志——而日志里并没有「哪些域名被判直连却失败」这个
  /// 已经归好类的视图。完整列表在分流记录页也有一份，两处共用同一个弹窗。
  final VoidCallback? onShowDetail;

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
            child: Text(
              '!',
              style: TextStyle(fontSize: 10, height: 1, color: fg),
            ),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                alarming ? '有连接被判为直连但失败（疑似规则未覆盖）' : '有连接失败，但判定正常',
                style: XvText.bodyMuted.copyWith(
                  color: XV.text,
                  fontWeight: FontWeight.w600,
                ),
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
        if (onShowDetail != null) ...<Widget>[
          const SizedBox(width: 8),
          TapAction(label: '详情', onTap: onShowDetail!),
        ],
      ],
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.label, required this.value});

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

/// 空状态：只做一件事 —— 让用户把配置弄进来。
///
/// 桌面端整块区域都是拖拽落点（对应原型里「把 .conf 拖到这里」的承诺）；
/// 移动端没有拖拽，只保留文件选择器。两者都额外提供手填入口作为兜底。
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
            builder: (BuildContext context, BoxConstraints constraints) =>
                SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
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
                          child: Icon(
                            Icons.file_upload_outlined,
                            size: 29,
                            color: XV.muted,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '导入配置',
                          style: TextStyle(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w700,
                            color: XV.text,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '选择 WireGuard 的 .conf、\nOpenVPN 的 .ovpn 或 Hysteria2 链接\n其余设置已经内置好了',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: XV.muted,
                            height: 1.85,
                          ),
                        ),
                        const SizedBox(height: 24),
                        XvButton(
                          label: '选择配置文件',
                          kind: XvButtonKind.primary,
                          icon: Icons.folder_open_outlined,
                          expand: true,
                          height: 46,
                          onPressed: () => pickAndImportConf(context, state),
                        ),
                        const SizedBox(height: 10),
                        XvButton(
                          label: '手动填写',
                          icon: Icons.edit_outlined,
                          expand: true,
                          height: 46,
                          onPressed: () =>
                              startManualConfigForm(context, state),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: EdgeInsets.only(bottom: 30),
                          child: Text(
                            '首次连接时系统会询问 VPN 授权，允许即可',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: XV.muted2,
                              height: 1.75,
                            ),
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
                    child: Icon(
                      Icons.file_upload_outlined,
                      size: 27,
                      color: XV.muted,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '导入你的 VPN 配置',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: XV.text,
                    ),
                  ),
                  const SizedBox(height: 11),
                  // 段落宽度按原型限到 430：不限的话它会跟着 520 的容器一起拉宽，
                  // 桌面上一行塞下过多字，是「看起来不规范」的来源之一。
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 430),
                    child: Text(
                      '把 .conf、.ovpn 或 Hysteria2 节点文件拖进来就行。分流规则已经内置，'
                      '不需要填写任何 IP 段、规则或路由表。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: XV.muted,
                        height: 1.8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 26),
                  DropTarget(
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: (DropDoneDetails detail) {
                      setState(() => _dragging = false);
                      if (detail.files.isEmpty) return;
                      importConfFromPath(
                        context,
                        state,
                        detail.files.first.path,
                      );
                    },
                    child: DashedBox(
                      // 只在真的拖拽中才高亮。
                      //
                      // 原型里那个 hover 态是**设计稿的静态示意**（展示悬停时什么样），
                      // 早先照着它把 highlighted 写死成 true，结果平时也是绿框绿底，
                      // 看起来像一直处于激活状态。
                      highlighted: _dragging,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 30,
                          horizontal: 20,
                        ),
                        child: Column(
                          children: <Widget>[
                            Text(
                              _dragging ? '松开鼠标即可导入' : '把配置文件拖到这里',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: XV.text,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: XV.green.withValues(alpha: 0.08),
                                border: Border.all(
                                  color: XV.green.withValues(alpha: 0.2),
                                ),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '.conf / .ovpn / .yaml',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: XV.green,
                                  fontFamilyFallback: XV.monoFallback,
                                ),
                              ),
                            ),
                            // 原型里这一行是有的，早先漏掉了——它不只是文案，
                            // 还决定这个框该有多高。
                            const SizedBox(height: 9),
                            Text(
                              '或点击下方按钮选择文件',
                              style: TextStyle(fontSize: 12, color: XV.muted2),
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
                        label: '选择配置文件',
                        kind: XvButtonKind.primary,
                        onPressed: () => pickAndImportConf(context, state),
                      ),
                      const SizedBox(width: 10),
                      XvButton(
                        label: '手动填写',
                        icon: Icons.edit_outlined,
                        onPressed: () => startManualConfigForm(context, state),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    '支持标准 WireGuard 客户端导出的 .conf（含 wg-quick 生成）、\n'
                    'OpenVPN 客户端导出的 .ovpn，以及 Hysteria2 分享链接 / config.yaml\n'
                    '配置只保存在本机，不会上传；导入后自动连接并完成分流',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: XV.muted2,
                      height: 1.8,
                    ),
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
