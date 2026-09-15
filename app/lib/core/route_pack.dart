/// 把本机学到 / 手工指定的域名分流规则打成可交换的文件。
///
/// 这就是 RULES 第六节「经验共享」的落地：没有中央服务器、不上传任何东西，
/// 只是一份 JSON。别人导入后变成**手工规则**——共享来的决定不该再被程序的
/// 推断改写。内置白名单不进包：那是随程序版本分发的，拷出去会变成第二事实。
library;

import 'dart:convert';

import 'auto_route.dart';

const String routePackFormat = 'xvpn-route-pack';
const int routePackVersion = 1;

/// 一份可导入的域名分流包。
class RoutePack {
  const RoutePack({
    required this.direct,
    required this.proxy,
  });

  final List<String> direct;
  final List<String> proxy;

  Map<String, Object?> toJson() => <String, Object?>{
        'format': routePackFormat,
        'version': routePackVersion,
        'direct': direct,
        'proxy': proxy,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 同时给出一份 sing-box 源规则集 JSON，方便丢进其它客户端。
  ///
  /// 只导出直连侧：本项目共享的场景是「这些域名其实能直连」，走隧道那一侧
  /// 往往绑定了某个人的失败现场，拷给别人容易误伤。
  String toSingBoxDirectRuleSet() => const JsonEncoder.withIndent('  ').convert(
        <String, Object?>{
          'version': 3,
          'rules': <Object?>[
            if (direct.isNotEmpty)
              <String, Object?>{
                'domain': direct,
                'domain_suffix': direct,
              },
          ],
        },
      );
}

/// 从自动纠正表导出。预置白名单排除在外。
RoutePack exportRoutePack(AutoRouteTable table) {
  final direct = <String>[];
  final proxy = <String>[];
  for (final entry in table.entries) {
    if (entry.source == RouteRuleSource.preset) continue;
    if (entry.preference == RoutePreference.forceDirect) {
      direct.add(entry.domain);
    } else {
      proxy.add(entry.domain);
    }
  }
  direct.sort();
  proxy.sort();
  return RoutePack(direct: direct, proxy: proxy);
}

/// 解析用户给的正文。认本项目的 pack，也认「一行一个域名」的直连清单。
RoutePack parseRoutePack(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('文件是空的');
  }
  if (trimmed.startsWith('{')) {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) {
      throw const FormatException('不是对象，无法作为规则包');
    }
    final json = decoded.cast<String, Object?>();
    final format = json['format']?.toString();
    if (format != null && format != routePackFormat) {
      throw FormatException('不认识的规则包格式「$format」');
    }
    return RoutePack(
      direct: _stringList(json['direct']),
      proxy: _stringList(json['proxy']),
    );
  }
  final direct = <String>[];
  for (final raw in trimmed.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final domain = AutoRouteTable.normalizeDomain(line);
    if (domain.isNotEmpty) direct.add(domain);
  }
  if (direct.isEmpty) {
    throw const FormatException('没有读到任何域名');
  }
  return RoutePack(direct: direct, proxy: const <String>[]);
}

/// 导入为手工规则。已有用户规则的域名不覆盖。
///
/// 返回实际写入的条数。
int importRoutePack(AutoRouteTable table, RoutePack pack) {
  var added = 0;
  void apply(String domain, RoutePreference preference) {
    final normalized = AutoRouteTable.normalizeDomain(domain);
    if (normalized.isEmpty) return;
    for (final entry in table.entries) {
      if (entry.domain == normalized && entry.source == RouteRuleSource.user) {
        return;
      }
    }
    table.setUserRule(normalized, preference);
    added++;
  }

  for (final domain in pack.direct) {
    apply(domain, RoutePreference.forceDirect);
  }
  for (final domain in pack.proxy) {
    apply(domain, RoutePreference.forceProxy);
  }
  return added;
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  final result = <String>[];
  for (final item in raw) {
    final value = item?.toString().trim() ?? '';
    if (value.isEmpty) continue;
    result.add(value);
  }
  return result;
}
