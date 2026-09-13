/// 热更新规则集：把「当前分流决策」以内核能反复拉取的规则集形式投递。
///
/// 它补的是**决策与执行之间的时间差**。内联路由规则写在 `config.json` 里，而内核
/// 拿着那份配置一直跑——不重连就不会读新规则。于是程序刚学到的纠正、用户刚做的
/// 改判，在**本次会话里统统不生效**：界面已经提示「已自动纠正」，那个域名却照样
/// 打不开，必须手动重连。这不是猜测，是在 Windows 上实测确认的（规则 21:20:07
/// 落盘，而内核配置停留在 21:05:53，`00.net` 从未进入运行中的配置）。
///
/// 投递方式是本机回环 HTTP：按标签提供规则集文档，内核按 [RouteRuleSetRefs.updateInterval]
/// 反复拉取。以下三件事都用真实内核（sing-box 1.14.0）实测过，方案就是照它们定的：
///
///   * 改写被服务的内容之后，**运行中的分流决策跟着变**——不需要重启内核，也不需要
///     重新生成配置。双向都验证过：把域名加入集合 → 该域名命中；移除 → 不再命中。
///   * **首次**拉取失败会让内核直接起不来（`start service: initialize rule-set`）。
///     因此本地服务必须在启动内核**之前**就绪，且启动时先自检一次（见
///     `route_rule_set_host.dart`）。
///   * 之后的刷新失败**不致命**：内核只报 ERROR 并继续运行。这也说明为什么不能
///     指望「退回本地缓存」——`path` 在本内核版本里不是合法字段，remote 规则集
///     没有磁盘缓存可用。
///   * 拉取**不进入 Clash API 的连接列表**。实测把服务端响应急意延迟 4 秒（连接
///     必然长期存在）、20 秒内采样 56 次，命中 0 次。因此它不会污染界面上的
///     「分流记录」与流量统计，也不需要为此加过滤——**别去「修」这个不存在的问题**。
///
/// 与内联规则的关系：[routeRuleSetDocs] 与 `AutoRouteTable.buildRouteRules()`
/// 都从 `AutoRouteTable.domainMatchForms()` 派生，两种投递方式的语义因此不可能
/// 分叉。配置生成器在拿不到本地服务地址时退回内联方式，行为与改造前一致。
library;

import 'auto_route.dart';
import 'outbound_tags.dart';

/// 热更新规则集的标签。
///
/// 分成四份而不是两份，是因为**优先级位置**不同：用户手工指定必须早于
/// `ip_is_private`（用户可能故意把内网域名指向代理），程序学到与内置白名单必须
/// 晚于它（私有地址段是确定边界，不该被推断出的证据推翻）。而 sing-box 的规则集
/// 本身不携带走向，因此「走向」与「位置」都得靠引用它的规则表达。
class AutoRouteRuleSetTags {
  const AutoRouteRuleSetTags._();

  /// 用户手工指定、走向隧道。
  static const String userProxy = 'xvpn-user-proxy';

  /// 用户手工指定、走向直连。
  static const String userDirect = 'xvpn-user-direct';

  /// 程序学到 + 内置白名单，走向隧道。
  static const String autoProxy = 'xvpn-auto-proxy';

  /// 程序学到 + 内置白名单，走向直连。
  static const String autoDirect = 'xvpn-auto-direct';

  /// 全部标签。顺序即配置里四份规则集的书写顺序，读起来与路由规则顺序一致。
  static const List<String> all = <String>[
    userProxy,
    userDirect,
    autoProxy,
    autoDirect,
  ];

  /// 拉取规则集所用的 HTTP 客户端标签。
  ///
  /// 必须显式声明并用 [AutoRouteRuleSetTags.httpClient] 引用，不能省。省掉会让内核
  /// 退回「隐式默认 HTTP 客户端」，而那条路径在 1.14.0 已弃用、1.16.0 移除；用旧的
  /// `download_detour` 同样是弃用路径。声明一个 HTTP 客户端是当前版本里唯一不产生
  /// 弃用警告的写法。
  ///
  /// 它的 `detour` 必须指向 `direct`，理由不是「省一次绕路」而是**可用性**：
  ///
  ///   * 不指定 `detour` 时实测拉取会绕过路由引擎（日志里没有对应的出站记录），
  ///     能不能到达只取决于内核对默认客户端的处理——也就是说，一旦将来内核版本改成
  ///     让默认客户端跟随 `route.final`，而 `final` 是我们的隧道，回环请求就会先进
  ///     隧道，于是**首次拉取失败、内核起不来**。这个故障形态不会在升级前的测试里
  ///     暴露，只会表现为「新版本装上一连就失败」；
  ///   * 指定 `detour: direct` 时，实测拉取**无条件**走 direct 出站：即使配置里没有
  ///     `ip_is_private` 这条规则、`final` 指向一个必然失败的出站，拉取照样成功。
  ///     这正是想要的——「把决策投递给内核」这件事不该依赖任何分流判定，尤其不该
  ///     依赖隧道是否可用（隧道本身出问题时，恰恰更需要纠正分流）。
  ///
  /// 代价是一条已经存在的不变量：`direct` 出站必须带上 `domain_resolver`，否则它在
  /// 内核眼里是「空出站」，这个 detour 会被拒绝（实测报错
  /// `detour to an empty direct outbound makes no sense`）。生成配置的那一侧已经
  /// 保证了这一点，且有一条真实内核校验会拦住它的回退。
  static const String httpClient = 'xvpn-rule-set-client';

  /// [httpClient] 的 detour：拉取规则集固定走的出站标签。
  ///
  /// 引用 [OutboundTags.direct] 而不是写字面量 `'direct'`：同一个字符串还被路由
  /// 规则生成与流量统计用来判断走向，分叉一次就会变成「拉取跟着隧道走」而没人
  /// 看得出来。
  static const String httpClientDetour = OutboundTags.direct;
}

/// 供配置生成器引用的规则集地址。
class RouteRuleSetRefs {
  const RouteRuleSetRefs({required this.urls, this.updateInterval = defaultUpdateInterval});

  /// 默认拉取间隔。
  ///
  /// 取 10 秒是「纠正够快」与「刷新开销可忽略」之间的折中：每次刷新只是本机的
  /// 一次极小请求加一次 JSON 解析（上限 400 条域名、约十几 KB），实测内核启动
  /// 仍在 0.03 秒完成。更短的间隔换不来可感的收益，更长则让「自动纠正」重新变得
  /// 像个需要等待的机制。
  static const Duration defaultUpdateInterval = Duration(seconds: 10);

  /// 标签 → 本机 HTTP 地址。
  final Map<String, String> urls;

  /// 内核重新拉取规则集的间隔。
  final Duration updateInterval;

  /// 某个标签的地址；没有则返回 null（调用方据此退回内联方式）。
  String? urlOf(String tag) => urls[tag];

  /// 四份地址是否齐全。缺任何一份都不能走热更新：路由规则会引用全部四个标签，
  /// 少一个内核就会因「引用了未定义的 rule_set」拒绝启动。
  bool get isComplete =>
      AutoRouteRuleSetTags.all.every((String tag) => urls.containsKey(tag));
}

/// 把当前决策翻成四份规则集文档（`format: source`）。
///
/// 返回的键是标签，值是内核可直接解析的文档。`version` 字段**必须**有：缺了它
/// 内核会在初始化路由器时报 `missing rule-set version` 并拒绝启动（实测）。
Map<String, Map<String, Object?>> routeRuleSetDocs(AutoRouteTable table) {
  final forms = table.domainMatchForms();
  return <String, Map<String, Object?>>{
    AutoRouteRuleSetTags.userProxy: _docFor(forms.userProxy),
    AutoRouteRuleSetTags.userDirect: _docFor(forms.userDirect),
    AutoRouteRuleSetTags.autoProxy: _docFor(forms.autoProxy),
    AutoRouteRuleSetTags.autoDirect: _docFor(forms.autoDirect),
  };
}

/// 一组匹配式 → 一份规则集文档。
///
/// 空集合产出空的 `rules`，这是合法的（实测内核接受 `{"version":3,"rules":[]}`），
/// 且语义正确——空规则集什么都不匹配。四份规则集恒被定义、恒被引用，因此路由规则
/// 里不需要为「这一组恰好为空」写特例。
Map<String, Object?> _docFor(DomainMatchForms forms) {
  return <String, Object?>{
    'version': 3,
    'rules': <Object?>[
      if (forms.exact.isNotEmpty || forms.suffix.isNotEmpty)
        <String, Object?>{
          if (forms.exact.isNotEmpty) 'domain': forms.exact,
          if (forms.suffix.isNotEmpty) 'domain_suffix': forms.suffix,
        },
    ],
  };
}
