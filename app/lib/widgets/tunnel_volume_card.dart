import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/tunnel_report.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import 'common.dart';

/// 「隧道流量去向」卡片：隧道带宽被谁占了，以及能不能改走直连。
///
/// 它存在的唯一理由是**让「误入隧道」可见**。本程序是白名单式直连，不在
/// `geosite-cn` 内的域名必然进隧道（`geoip-cn` 不参与域名目标的判定，见
/// `docs/RULES.md` 的实测）。这类流量不会失败、不会报错，只是白白占用隧道带宽，
/// 因此此前既没有任何界面提示，也没有任何入口能让用户发现并处理。
///
/// 这里把已观测到的走隧道目标按流量降序排出来，并就地给出「改为直连」——
/// 动作复用 `AppState.preferDirectFor`，与手工指定是同一条路径，不新增机制。
class TunnelVolumeCard extends StatelessWidget {
  const TunnelVolumeCard({
    super.key,
    required this.state,
    required this.compact,
  });

  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final entries = state.tunnelVolume;
    final total = state.tunnelVolumeTotalBytes;

    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('隧道流量去向'),
          Text(
            entries.isEmpty
                ? '还没有观察到走隧道的流量。连接后这条清单会按流量从多到少列出'
                      '走隧道的目标，便于判断哪些本该直连。'
                : '按已观测到的流量从多到少排列。不在规则库内的域名必然走隧道，'
                      '若它其实可以直连，这里会白占隧道带宽——可就地改为直连。',
            style: XvText.caption,
          ),
          if (entries.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text('清单合计 ${_bytes(total)}', style: XvText.caption),
            const SizedBox(height: 4),
            for (final entry in entries)
              _buildEntry(context, entry),
          ],
        ],
      ),
    );
  }

  Widget _buildEntry(BuildContext context, TunnelVolumeEntry entry) {
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
                        entry.target,
                        style: XvText.bodyMuted.copyWith(color: XV.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    RouteTag.kind(RouteKind.proxy, label: '走隧道'),
                    if (entry.hasRule) ...<Widget>[
                      const SizedBox(width: 6),
                      RouteTag.green('已有规则'),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(_detail(entry), style: XvText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (entry.canPreferDirect)
            TapAction(
              label: '改为直连',
              onTap: () => _prefer(context, entry),
            ),
        ],
      ),
    );
  }

  void _prefer(BuildContext context, TunnelVolumeEntry entry) {
    state.preferDirectFor(entry.domain);
    // 改的是内核配置里的路由表，而内核是拿着已生成的配置在跑，所以必须说明
    // 「什么时候生效」，否则用户会以为点了立刻变，然后怀疑没生效。
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '已把 ${entry.domain} 改为直连，下一次连接（或重连）时生效',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  static String _detail(TunnelVolumeEntry entry) {
    final parts = <String>[
      _bytes(entry.bytes),
      '${entry.connections} 条连接',
      if (entry.failures > 0) '失败 ${entry.failures} 次',
      // 把「为什么在隧道里」写出来：命中规则库、有专门规则、还是默认规则兜底。
      entry.hasRule ? '命中规则：${entry.rule}' : '没有专门规则，按默认规则走隧道',
    ];
    return parts.join(' · ');
  }

  static String _bytes(int value) {
    final size = fmtBytes(value);
    return '${size.value}${size.unit}';
  }
}
