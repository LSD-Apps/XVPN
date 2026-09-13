/// 隧道流量去向：谁在消耗隧道带宽，以及它为什么在隧道里。
///
/// 存在的理由很直接：本程序是白名单式直连，**不在 `geosite-cn` 内的域名必然进隧道**
/// （见 `docs/RULES.md` 的实测：`geoip-cn` 不参与域名目标的判定）。因此「该直连却
/// 走了隧道」的流量不会失败、不会报错，只会静静地占用隧道带宽、多一跳延迟，并把
/// 访问来源换成境外 IP——用户完全看不出原因，程序此前也没有任何入口给出线索。
///
/// 这一层把已有的观测数据（`SplitRecord` 里逐目标的字节数与连接数）汇总成一份
/// **按浪费排序的清单**，让「谁在吃隧道」从看不见变成一眼可见。它只做汇总，
/// 不改路由：是否改为直连由用户决定（复用 `setDomainPreference`）。
library;

import '../models.dart';
import 'auto_route.dart';

/// 一个走隧道目标的分流去向。
class TunnelVolumeEntry {
  const TunnelVolumeEntry({
    required this.target,
    required this.domain,
    required this.bytes,
    required this.connections,
    required this.failures,
    required this.rule,
    required this.hasRule,
    required this.canPreferDirect,
  });

  /// 内核给出的目标原文（可能是域名、`域名:端口` 或 IP）。
  final String target;

  /// 归一化后的域名。IP 或单标签主机名为空串——那些不能按域名改分流。
  final String domain;

  /// 已传输字节（上传 + 下载）。
  final int bytes;

  final int connections;
  final int failures;

  /// 命中的规则名，用于回答「它为什么走隧道」。
  final String rule;

  /// 是否已被某条规则覆盖（程序学到的或用户指定的）。
  final bool hasRule;

  /// 能否给出「改为直连」这个动作。IP 目标与已有用户规则的不给。
  final bool canPreferDirect;
}

/// 汇总走隧道的目标，按流量降序。
///
/// [limit] 为 0 表示不截断。只统计 `RouteKind.proxy`：这份清单回答的是
/// 「隧道被谁占了」，直连的流量不在这里。
///
/// 纯函数：记录与规则表进，清单出。因此排序、截断、可动作性判定都能直接单测，
/// 不必渲染界面。
List<TunnelVolumeEntry> rankTunnelTargets(
  Iterable<SplitRecord> records, {
  AutoRouteTable? table,
  int limit = 20,
}) {
  final entries = <TunnelVolumeEntry>[];
  for (final record in records) {
    if (record.kind != RouteKind.proxy) continue;
    final domain = AutoRouteTable.normalizeDomain(record.target);
    final rule = table?.match(domain);
    entries.add(
      TunnelVolumeEntry(
        target: record.target,
        domain: domain,
        bytes: record.totalBytes,
        connections: record.connections,
        failures: record.failures,
        rule: record.rule,
        hasRule: rule != null,
        // 没有可用的域名就不能改分流：按域名的规则对 IP 目标没有意义，
        // 而已经手工指定过的条目不该再给一个会覆盖它的动作。
        canPreferDirect:
            domain.isNotEmpty &&
            !(rule != null && rule.source == RouteRuleSource.user),
      ),
    );
  }
  // 流量降序；流量相同时按连接数降序，再按目标字典序——保证顺序稳定，
  // 否则同一份数据两次渲染的次序可能不同，界面会莫名其妙地跳动。
  entries.sort((TunnelVolumeEntry a, TunnelVolumeEntry b) {
    final byBytes = b.bytes.compareTo(a.bytes);
    if (byBytes != 0) return byBytes;
    final byConnections = b.connections.compareTo(a.connections);
    if (byConnections != 0) return byConnections;
    return a.target.compareTo(b.target);
  });
  if (limit > 0 && entries.length > limit) {
    return List<TunnelVolumeEntry>.unmodifiable(entries.sublist(0, limit));
  }
  return List<TunnelVolumeEntry>.unmodifiable(entries);
}

/// 走隧道的总字节数。用于在界面上给出「这份清单覆盖了多少」。
int tunnelVolumeTotal(Iterable<SplitRecord> records) {
  var total = 0;
  for (final record in records) {
    if (record.kind == RouteKind.proxy) total += record.totalBytes;
  }
  return total;
}
