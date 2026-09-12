import '../models.dart';
import 'auto_route.dart';
import 'core_log.dart';
import 'dns_monitor.dart';

/// 对一个域名的查证结论。
///
/// 存在这一层的理由：界面上已经有五处能回答「为什么打不开」——分流记录、失败
/// 归因、DNS 监测、启动自检、内核日志——但它们各自回答的是**全局**的问题
/// （「有没有直连失败」「DNS 健不健康」）。用户真正的问法是「我打不开的这个
/// 网站到底怎么了」，那是一个按域名提问的问题，此前没有任何入口能回答。
///
/// 这里把三份已有的证据按域名汇总起来：
///   * 内核**实际**把它判到了哪条路（来自分流记录，不是推测）；
///   * 有没有规则覆盖它（程序学到的，或用户手工指定的）；
///   * 两路 DNS 的解析结果是否一致（答案一致性 / 就近判定的依据）。
///
/// 刻意不做的一件事：**不预测分流结果**。geosite-cn 是二进制规则集，Dart 侧
/// 读不了（没有 zlib），因此「这个域名会不会命中 geosite-cn」在客户端根本
/// 答不出来。与其编一个看起来像预测的东西，不如只说已经发生的事实。
class DomainCheck {
  const DomainCheck({
    required this.domain,
    required this.records,
    this.rule,
    this.dns,
  });

  /// 归一化之后要查证的域名。
  final String domain;

  /// 该域名最近的分流记录，最近的在前。
  final List<SplitRecord> records;

  /// 覆盖这个域名的规则（含后缀匹配）。为 null 表示没有规则。
  final AutoRouteEntry? rule;

  /// 两路 DNS 的对照结论。为 null 表示尚未探测（或探测失败）。
  final DnsCrossCheck? dns;

  /// 内核最近一次把它判到了哪条路。没有记录时为 null。
  RouteKind? get lastRoute => records.isEmpty ? null : records.first.kind;

  /// 是否观察到过它。
  bool get observed => records.isNotEmpty;

  /// 一句话结论。界面把它放在最显眼的位置。
  String get conclusion {
    if (!observed && rule == null && dns == null) {
      return '没有关于 $domain 的任何记录。访问一次后再来看，或者先确认域名拼写。';
    }
    if (dns != null && dns!.verdict == DnsVerdict.suspectPoisoning) {
      return '$domain 的解析结果可疑：直连解析器与隧道解析器给出的答案不一致。'
          '这类域名走隧道解析更可靠。';
    }
    if (rule != null && !observed) {
      return '$domain 已被规则覆盖（${rule!.preference.label}），但还没有观察到实际连接。';
    }
    if (observed) {
      final route = lastRoute == RouteKind.proxy ? '走隧道' : '直连';
      final source = rule == null
          ? '没有专门规则，按规则库判定'
          : '命中规则：${rule!.preference.label}';
      return '$domain 最近一次$route（$source）。';
    }
    if (dns != null) {
      // 有解析对照、但没有实际连接记录：把唯一掌握的结论说出来，
      // 而不是甩一句「还没观察到」把已有的证据也一起埋掉。
      return '$domain 还没有被观察到实际连接，但两路解析对照的结论是'
          '「${dns!.verdict.label}」。';
    }
    return '暂时只能确认 $domain 还没有被观察到。';
  }

  /// 分行展示的证据。界面直接渲染，不在 widget 里再拼字符串。
  List<({String label, String value})> get facts {
    final rows = <({String label, String value})>[];
    if (rule != null) {
      rows.add((
        label: '规则',
        value: '${rule!.preference.label}（${rule!.source.label}）',
      ));
    }
    if (dns != null) {
      rows.add((label: 'DNS 对照', value: dns!.verdict.label));
      rows.add((label: '直连解析', value: _join(dns!.domesticAnswers)));
      rows.add((label: '隧道解析', value: _join(dns!.tunnelAnswers)));
    } else {
      rows.add((label: 'DNS 对照', value: '尚未探测'));
    }
    if (records.isEmpty) {
      rows.add((label: '最近记录', value: '没有观察到'));
    } else {
      rows.add((
        label: '最近记录',
        value:
            '${records.length} 条，最近一次 ${records.first.timeDisplay} '
            '${records.first.kind.label}（${records.first.rule}）',
      ));
    }
    return rows;
  }

  static String _join(List<String> answers) =>
      answers.isEmpty ? '无结果' : answers.join('、');
}

/// 汇总查证结论。纯函数：三份证据进，一份结论出。
DomainCheck buildDomainCheck({
  required String domain,
  required List<SplitRecord> records,
  AutoRouteEntry? rule,
  DnsCrossCheck? dns,
}) {
  final normalized = AutoRouteTable.normalizeDomain(domain);
  // 归一化会把 IP、单标签主机名、空串都变成空串——那些目标不参与按域名的分流，
  // 因此没有规则可查。但**记录仍然要能匹配上**：用户输入一个 IP 来查证是合理
  // 的（分流记录页的搜索框就同时接受域名与 IP），若这里用空串去比对，明明有
  // 记录也会答「没有观察到」——那是在说假话。
  final matchKey = normalized.isEmpty
      ? domain.trim().toLowerCase()
      : normalized;
  final matched = <SplitRecord>[
    for (final record in records)
      if (hostOfTarget(record.target).toLowerCase() == matchKey) record,
  ];
  return DomainCheck(
    domain: matchKey.isEmpty ? domain.trim() : matchKey,
    records: List<SplitRecord>.unmodifiable(matched),
    rule: rule,
    dns: dns,
  );
}
