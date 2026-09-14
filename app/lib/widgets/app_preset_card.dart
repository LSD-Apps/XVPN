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
///   * **直连站点补充**：本该直连却被判进隧道的站点（默认启用，
///     因为把本该直连的站点送进隧道是缺陷而非选项）；
///   * **应用直连预置**：某些应用后端可直连（如 Cursor），默认关闭——
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
            '把确实能直连、却被默认规则送进隧道的域名拉出来。',
            style: XvText.caption,
          ),
          const SizedBox(height: 6),
          for (final preset in presets)
            _PresetRow(
              preset: preset,
              on: enabled.contains(preset.id),
              onChanged: (bool value) =>
                  state.setAppPresetEnabled(preset.id, value),
            ),
          const SizedBox(height: 6),
          // 预置经自动纠正表下发，而那张表是可热更新的规则集，因此不需要重连。
          Text(
            '改动会在十几秒内生效，无需重连。',
            style: XvText.caption,
          ),
        ],
      ),
    );
  }
}

/// 单条预置：常显摘要与例外；实测依据默认折叠，避免列表纵向膨胀。
class _PresetRow extends StatefulWidget {
  const _PresetRow({
    required this.preset,
    required this.on,
    required this.onChanged,
  });

  final AppPreset preset;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  State<_PresetRow> createState() => _PresetRowState();
}

class _PresetRowState extends State<_PresetRow> {
  bool _evidenceOpen = false;

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final title = Text(
      preset.label,
      style: XvText.bodyMuted.copyWith(color: XV.text),
      overflow: TextOverflow.ellipsis,
    );
    final status = widget.on
        ? RouteTag.green('已启用')
        : RouteTag.warn('未启用');
    final enableSwitch = XvSwitch(
      key: ValueKey<String>('app-preset-switch-${preset.id}'),
      value: widget.on,
      onChanged: widget.onChanged,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(child: title),
              const SizedBox(width: 8),
              status,
              const Spacer(),
              enableSwitch,
            ],
          ),
          const SizedBox(height: 3),
          Text(preset.summary, style: XvText.caption),
          // 例外必须摆出来：用户看到「直连」的开关，却不知道有几个域名被特意
          // 留在隧道里，遇到它们走隧道时就会以为程序判错了。
          if (preset.tunnelExceptions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              '例外（留在隧道，直连侧解析不出）：'
              '${preset.tunnelExceptions.join('、')}',
              style: XvText.caption,
            ),
          ],
          if (preset.evidence != null) ...<Widget>[
            const SizedBox(height: 2),
            TapAction(
              label: _evidenceOpen ? '收起依据' : '查看依据',
              onTap: () => setState(() => _evidenceOpen = !_evidenceOpen),
            ),
            if (_evidenceOpen)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '实测依据：${preset.evidence!}',
                  style: XvText.caption,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
