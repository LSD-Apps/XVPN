import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/app_presets.dart';
import '../theme.dart';
import 'common.dart';

/// 「直连白名单」卡片。
///
/// 它回答的是一个容易被误解的问题：**「某个域名明明能直连，为什么还走隧道？」**
///
/// 本程序是白名单式直连（命中 `geosite-cn` / `geoip-cn` 才直连），而 `geoip-cn`
/// **不参与域名目标的判定**（实测见 `docs/RULES.md`）——因此不在 `geosite-cn`
/// 内的域名**必然**进隧道，没有任何兜底。这里把两类「确实能直连」的域名显式
/// 白名单化：
///
///   * **国内长尾站点补充**：本该直连却被判进隧道的国内站点（默认启用，
///     因为把国内站点送进隧道是缺陷而非选项）；
///   * **境外应用预置**：在国内可直连的境外应用（如 Cursor），默认关闭——
///     正常情况下它们本就该走隧道，直连是例外。
///
/// 做成用户可见的开关而不是写死在配置生成里，是因为可达性会随链路与时间变化：
/// 写死的话，某天这些域名连不上了，用户既看不出原因、也无法关掉它。
class AppPresetCard extends StatelessWidget {
  const AppPresetCard({super.key, required this.state, required this.compact});

  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final presets = state.appPresets;
    if (presets.isEmpty) return const SizedBox.shrink();
    final enabled = state.enabledAppPresets.toSet();

    return XvCard(
      color: compact ? XV.panel2 : XV.panel,
      radius: compact ? 12 : XV.rCard,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('直连白名单'),
          Text(
            '把「确实能直连、却被默认规则送进隧道」的域名显式拉出来。两类：'
            '国内长尾站点补充（修正 geosite-cn 未收录导致的误判，默认启用）与'
            '境外应用预置（正常情况下它们本该走隧道，因此需要显式启用）。'
            '默认规则是「不在规则库内就走隧道」，而 geoip-cn 不参与域名目标的'
            '判定，所以这两类域名都收不到任何兜底。',
            style: XvText.caption,
          ),
          const SizedBox(height: 6),
          for (final preset in presets)
            _buildPreset(preset, enabled.contains(preset.id)),
          const SizedBox(height: 6),
          Text(
            '改动在下一次连接（或重连）时写进内核配置。',
            style: XvText.caption,
          ),
        ],
      ),
    );
  }

  Widget _buildPreset(AppPreset preset, bool on) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  preset.label,
                  style: XvText.bodyMuted.copyWith(color: XV.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (on) RouteTag.green('已启用') else RouteTag.warn('未启用'),
              const Spacer(),
              XvSwitch(
                key: ValueKey<String>('app-preset-switch-${preset.id}'),
                value: on,
                onChanged: (bool value) =>
                    state.setAppPresetEnabled(preset.id, value),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(preset.summary, style: XvText.caption),
          // 例外必须摆出来：用户看到「直连」的开关，却不知道有几个域名被特意
          // 留在隧道里，遇到它们走隧道时就会以为程序判错了。
          if (preset.tunnelExceptions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              '例外（留在隧道，国内解析不出）：'
              '${preset.tunnelExceptions.join('、')}',
              style: XvText.caption,
            ),
          ],
          if (preset.evidence != null) ...<Widget>[
            const SizedBox(height: 2),
            Text('实测依据：${preset.evidence!}', style: XvText.caption),
          ],
        ],
      ),
    );
  }
}
