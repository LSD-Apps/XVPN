import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/auto_route.dart';
import '../core/core_log.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 完整失败记录。
///
/// 这一屏要做的事只有一件：把「这个网站打不开」变成**可执行的下一步**。
/// 界面上的失败摘要只给结论，用户真正需要的是「哪些域名有问题、为什么、
/// 我现在能做什么」——因此每一组后面直接给出「改走代理」，而不是让他记住
/// 域名，再跑到「自动纠正」卡片里手打一遍。
///
/// 单独成文件而不是留在连接页里：入口有两处——状态卡片上的诊断行（出问题时
/// 最显眼）与分流记录页的汇总卡（要分析问题时去的地方）。两处共用同一份实现，
/// 才不会出现「一个入口修好了、另一个还是旧行为」。
Future<void> showFailuresDialog(BuildContext context, AppState state) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (BuildContext context, void Function(void Function()) setDialogState) {
        final failures = state.failures;
        final groups = groupFailures(failures);
        final digest = state.failureDigest;
        return Dialog(
          backgroundColor: XV.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(XV.rCard),
            side: BorderSide(color: XV.line),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680, maxHeight: 580),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '连接失败记录',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: XV.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    failures.isEmpty
                        ? '本次连接期间还没有失败记录。'
                        : '共计 ${digest.total} 条：直连 ${digest.directFailures} / '
                              '隧道 ${digest.proxiedFailures}。${digest.advice}',
                    style: XvText.caption,
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: failures.isEmpty
                        ? const SizedBox.shrink()
                        : Container(
                            decoration: BoxDecoration(
                              color: XV.field,
                              border: Border.all(color: XV.line),
                              borderRadius: BorderRadius.circular(XV.rCtl),
                            ),
                            // 记录上限 200 条，组数更少，但一律用懒构建：
                            // 这个弹窗在连接异常时会被反复打开。
                            child: ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: groups.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                color: XV.line.withValues(alpha: 0.6),
                              ),
                              itemBuilder: (BuildContext context, int index) {
                                final group = groups[index];
                                // 已经有规则覆盖这个目标时不再给「改走代理」：
                                // 同一个入口反复出现在已经处理过的目标旁边，
                                // 只会让人以为上次点了没生效。
                                final ruled =
                                    state.autoRoute?.match(group.host) != null;
                                return FailureGroupTile(
                                  group: group,
                                  alreadyRuled: ruled,
                                  onForceProxy:
                                      group.suggestsMissingRule && !ruled
                                      ? () {
                                          final added = state
                                              .setDomainPreference(
                                                group.host,
                                                RoutePreference.forceProxy,
                                              );
                                          setDialogState(() {});
                                          if (!added && dialogContext.mounted) {
                                            // 归一化会把 IP、单标签主机名变成空串：
                                            // 这类目标本来就不参与按域名的分流。
                                            ScaffoldMessenger.of(
                                              dialogContext,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  '这个目标不能按域名指定走向（可能是 IP）',
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      : null,
                                );
                              },
                            ),
                          ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          failures.isEmpty ? '' : '${groups.length} 个目标',
                          style: TextStyle(fontSize: 11.5, color: XV.muted2),
                        ),
                      ),
                      XvButton(
                        label: '清空',
                        onPressed: failures.isEmpty
                            ? null
                            : () {
                                state.clearFailures();
                                setDialogState(() {});
                              },
                      ),
                      const SizedBox(width: 8),
                      XvButton(
                        label: '复制记录',
                        kind: XvButtonKind.primary,
                        onPressed: failures.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: failureReport(failures)),
                                );
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop();
                                }
                              },
                      ),
                      const SizedBox(width: 8),
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
    ),
  );
}

/// 失败记录里的一组（同一个目标、同一条路径）。
///
/// 标签颜色表达的是**用户能不能自己解决**，而不只是「哪条路失败了」：
///   * 琥珀色——判为直连却失败，疑似规则未覆盖，改规则就能好；
///   * 红色——走了隧道仍失败，问题在节点，改规则没有用；
///   * 蓝色——直连失败但目标是 IP 或属于 DNS 层问题，与分流规则无关。
/// 三者混用会让用户对着一个自己无能为力的问题反复折腾规则。
class FailureGroupTile extends StatelessWidget {
  const FailureGroupTile({
    super.key,
    required this.group,
    this.onForceProxy,
    this.alreadyRuled = false,
  });

  final FailureGroup group;

  /// 把这一组的目标改为走代理。为 null 表示这一组不适合这么处理。
  final VoidCallback? onForceProxy;

  /// 这个目标已经被某条规则覆盖（含后缀规则）。
  final bool alreadyRuled;

  @override
  Widget build(BuildContext context) {
    final actionable = group.suggestsMissingRule;
    final Widget tag = switch ((actionable, group.proxied)) {
      (true, _) => RouteTag.warn('直连失败'),
      (false, true) => RouteTag.danger('隧道失败'),
      (false, false) => RouteTag.direct('直连失败'),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  group.host,
                  style: XvText.monoSmall.copyWith(color: XV.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (group.count > 1) ...<Widget>[
                Text(
                  '×${group.count}',
                  style: TextStyle(fontSize: 11, color: XV.muted2),
                ),
                const SizedBox(width: 8),
              ],
              tag,
              if (alreadyRuled) ...<Widget>[
                const SizedBox(width: 10),
                RouteTag.green('已指定走向'),
              ] else if (onForceProxy != null) ...<Widget>[
                const SizedBox(width: 10),
                TapAction(label: '改走代理', onTap: onForceProxy!),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${group.lastSummary} · ${group.latest.reason}',
            style: XvText.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
