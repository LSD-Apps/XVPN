/// 分流学习：**策略、判据与决策**——一个不碰路由表的独立模块。
///
/// ## 为什么单独成模块
///
/// 学习机制原先与路由表混在一个 1062 行的类里，而它的**策略常量还横跨两个文件**：
/// 阈值在 `auto_route.dart`，判据与限流在 `core_monitor.dart`。后果很具体——
/// 想调一个阈值，得先想清楚它该在哪个文件；而新增挂死判据时，因为没有明确的
/// 归属地，它就顺手落进了观测层。
///
/// 这里的切分依据是「未来的迭代会碰什么」。会碰的只有三件事：
///
///   1. **一次观测算哪种证据**（`LearningPolicy.classifyDirectConnection`）；
///   2. **阈值**（同一个策略对象里的各个字段）；
///   3. **累计到多少才改判、以及迟滞**（`judgeSetback` / `shouldRevokeLearnedProxy`）。
///
/// 三件全是**纯逻辑**，没有一件需要碰路由表的存储、匹配或规则生成。因此把它们
/// 集中到这个模块，迭代学习策略就不必动那个承重的表——这是本模块存在的意义。
///
/// ## 边界
///
/// 本模块**不持有路由规则、也不持有观测状态**：
///
///   * 决策是纯函数（现有证据 + 策略 → 该做什么），因此可以逐条直测，不需要
///     构造路由表、也不需要伪造网络；
///   * 唯一带状态的是 [OutcomeThrottle]，而它只是一张「最近记过什么」的表，
///     与路由规则无关。
///
/// 规则怎么存、怎么匹配、怎么生成内核语法，仍然在 `auto_route.dart` 的
/// `AutoRouteTable` 里——那是它该管的事。
library;

/// 分流倾向。
enum RoutePreference {
  /// 强制走隧道。
  forceProxy,

  /// 强制直连。
  ///
  /// 由两个来源产生：用户手工指定，以及程序观察到的「直连解析落在国内网段」。
  forceDirect,
}

extension RoutePreferenceX on RoutePreference {
  String get label => this == RoutePreference.forceProxy ? '强制代理' : '强制直连';

  String get storageKey =>
      this == RoutePreference.forceProxy ? 'proxy' : 'direct';
}

/// 规则来源，决定它在表里的优先级。
enum RouteRuleSource {
  /// 用户手工指定。永远最高优先级，且不会被程序覆盖。
  user,

  /// 程序从证据里学到的（两个方向：直连没交付→走隧道，国内解析→直连）。
  learned,

  /// 由「直连白名单」预置安装进来的域名（见 `app_presets.dart`）。
  ///
  /// 优先级**最低**：它是一份静态清单，而 [learned] 是运行中观察到的证据、
  /// [user] 是用户的明确决定，两者都应当能推翻它。
  preset,
}

extension RouteRuleSourceX on RouteRuleSource {
  /// 界面展示名。
  ///
  /// 把「谁定的这条规则」说清楚是必要的：用户手工指定的规则不会被程序改，
  /// 而程序学到的会随证据变化。两者在界面上长得一样的话，用户会怀疑
  /// 「我明明指定过，怎么又变了」。
  String get label => switch (this) {
    RouteRuleSource.user => '手工指定',
    RouteRuleSource.learned => '程序学到',
    RouteRuleSource.preset => '内置白名单',
  };

  /// 优先级序号，**越小越优先**。
  ///
  /// 用它排序而不是在生成规则时靠书写顺序表达，是因为后者一被重排就是静默的
  /// 行为变更。这里定死：用户 > 学到 > 预置。
  int get rank => switch (this) {
    RouteRuleSource.user => 0,
    RouteRuleSource.learned => 1,
    RouteRuleSource.preset => 2,
  };
}

/// 一条**已关闭**直连连接的质量判定结果。
///
/// 三态而不是布尔：拿不准时不下结论，比下错结论安全——与 DNS 交叉校验
/// 「拿不到地理信息就不下结论」是同一条原则。
enum DirectOutcome {
  /// 不是直连连接，不参与这套判定。
  notApplicable,

  /// 确实交付了内容（字节数达到下限）：可信的正向证据。
  delivered,

  /// 握手成功但没有数据：存活够久却几乎没交付。对分流而言是一次失败。
  stalled,

  /// 证据不足（存活短且字节少）：可能是一个正常的小响应，也可能是一次快速
  /// 失败——后者由内核日志的 `ERROR` 行负责归因，不需要在这里重复计。
  pending,
}

/// 一次观测该记成哪一类证据。
///
/// 它与 [RoutePreference] 是**两件事**：证据描述发生了什么，倾向描述该怎么走。
/// 学习就是把前者累积成后者。
enum EvidenceKind {
  /// 连接失败（内核日志里会有 `ERROR` 行）。
  connectionFailure,

  /// 握手成功但没有数据。见 [LearningPolicy.stallFloor]。
  stall,

  /// 确实交付了内容。见 [LearningPolicy.substantiveByteFloor]。
  delivery,
}

/// 学习策略：所有阈值、判据与限流参数都在这里。
///
/// 集中在一处是本模块的主要目的——在此之前它们横跨两个文件。
class LearningPolicy {
  const LearningPolicy({
    this.promotionThreshold = 3,
    this.domesticPromotionThreshold = 2,
    this.revokeSuccessThreshold = 3,
    this.substantiveByteFloor = 8 * 1024,
    this.stallFloor = const Duration(seconds: 6),
    this.outcomeWindow = const Duration(seconds: 15),
    this.capacity = 400,
    this.decayAfter = const Duration(days: 14),
    this.maxPendingEvidence = 200,
    this.maxOutcomeLog = 2000,
  }) : assert(capacity > 0),
       assert(promotionThreshold > 0),
       assert(revokeSuccessThreshold > 0);

  /// 连续多少次「直连没有交付」才改判走隧道。
  ///
  /// 取 3 而不是 1：单次失败可能只是网络抖动或对端临时故障，一次抖动就把域名
  /// 永久推进隧道，会让用户觉得「分流时好时坏」。
  final int promotionThreshold;

  /// 直连解析连续多少次落在国内网段，才把走隧道的域名改成直连。
  ///
  /// 取 2 而不是 1：这是**推断**而不是事实——「解析到国内地址」是事实，
  /// 「所以该直连」是推断（该地址可能并不可达，比如服务由规则集范围内的 CDN
  /// 承载却走不通）。也不需要 3：那会让一个明显在国内的站点白走两轮隧道。
  final int domesticPromotionThreshold;

  /// 学到的强制代理规则需要**连续**多少次「确实交付」才撤销。
  ///
  /// 取 3 与 [promotionThreshold] 对称：改判与撤销都要连续三次，因此交替出现的
  /// 成败永远攒不满任何一边的阈值，规则稳定；而网络真的恢复时连续成功会很快
  /// 攒够，撤销照样及时。
  final int revokeSuccessThreshold;

  /// 判定「交付了内容」的字节下限。
  ///
  /// 实测校准（2026-09，中国大陆·深圳，**直连**，`curl --noproxy '*'`）：
  ///
  /// ```
  /// 成功的请求  交付 577,137 字节（一次慢的：448,401 字节 / 12.0s）
  /// 挂死的请求  交付 0 字节（存活 8–10 秒）
  /// ```
  ///
  /// 两者相差**三个数量级**，因此这个下限取得宽松也不会误判。取 8 KB：远低于
  /// 任何真实页面或下载对象，又远高于「隐约漏出几个字节」的情形。
  ///
  /// 为什么不能沿用「跑出过任何字节就算成功」：实测里最常见的失败形态恰恰是
  /// 「TLS 握手几百毫秒就成功、随后只漏出零星字节就挂住」，用 `> 0` 会把这一类
  /// 记成成功，进而把连续失败计数清零。
  final int substantiveByteFloor;

  /// 判定「握手成功但没有交付」的存活时长下限。
  ///
  /// 实测：挂死连接的存活时长为 8–10 秒（受客户端超时限制，真实值只会更长），
  /// 而成功的连接为 0.8–4.6 秒。**但只看时长不够**——同一批实测里有一次存活
  /// 12.0 秒却交付了 448 KB 的「慢但成功」。因此必须与字节数联合判断，
  /// 这正是 [classifyDirectConnection] 的写法。
  final Duration stallFloor;

  /// 同一个域名的同类观测之间的最小间隔。
  ///
  /// 取 15 秒的依据：轮询周期是 1 秒，而一次页面加载/一次重试风暴都在几秒内
  /// 完成；15 秒既能把它们折叠成一次，又能让持续存在的问题在大约 45 秒内
  /// 攒满「连续 3 次」。更长会让纠正变迟钝，更短则挡不住突发。
  final Duration outcomeWindow;

  /// 学习表容量上限。超出时淘汰证据最弱的条目。
  final int capacity;

  /// 多久没有任何新证据就淘汰一条学到的规则。
  final Duration decayAfter;

  /// 未定性证据（待定区）的条数上限。超过就整表清空。
  ///
  /// 它只影响「再数几次」的成本，因此清空比做 LRU 更简单也更划算。
  final int maxPendingEvidence;

  /// 限流表的容量上限。超出即整体清空，理由同上。
  final int maxOutcomeLog;

  /// 一次「直连没有交付」适用的阈值。
  ///
  /// 解析结果不一致是**确定性**证据（直连解析与隧道解析给出完全不同的答案），
  /// 不必再等两次，因此阈值降为 1。
  int setbackThreshold({required bool poisoned}) =>
      poisoned ? 1 : promotionThreshold;

  /// 判定一条**已关闭**直连连接的质量。
  ///
  /// 必须联合判断字节数与存活时长：只看时长会把「慢但成功」误判成挂死。
  DirectOutcome classifyDirectConnection({
    required bool direct,
    required int bytes,
    required Duration? alive,
  }) {
    if (!direct) return DirectOutcome.notApplicable;
    // 交付够多 → 这条直连确实把内容送出来了，是可信的正向证据。
    if (bytes >= substantiveByteFloor) return DirectOutcome.delivered;
    // 存活够久却几乎没交付 → 挂死。这是实测中最常见、而原先完全看不见的一类。
    if (alive != null && alive >= stallFloor) return DirectOutcome.stalled;
    // 其余（短命且字节少）不下结论。
    return DirectOutcome.pending;
  }

  /// 这类观测对应哪种证据。与 [classifyDirectConnection] 配对使用。
  EvidenceKind evidenceFor(DirectOutcome outcome) => switch (outcome) {
    DirectOutcome.delivered => EvidenceKind.delivery,
    DirectOutcome.stalled => EvidenceKind.stall,
    DirectOutcome.notApplicable || DirectOutcome.pending =>
      EvidenceKind.connectionFailure,
  };
}

/// 记一次「直连没有交付」之后该怎么处置。
///
/// 纯函数：给出现有证据与策略，给出结论。不持有状态、不碰路由表，因此可以逐条
/// 直测——「累计到多少才改判」这类逻辑最容易写错，而它恰恰不该需要伪造网络才能验证。
///
/// [consecutiveFailures] 是**含这一次**的连续计数；[currentPreference] 为 null
/// 表示这个域名还没有任何规则。
///
/// 注意这里**不看累计成功次数**。原实现的条件是
/// `consecutiveFailures >= 阈值 && directSuccesses == 0`，那道闸门是永久性的：
/// 只要该域名历史上成功过**一次**，就再也不可能被学成走隧道，无论后来失败多少次。
/// 对「偶尔能连上、大部分时候连不上」的域名（实测 github.com 正是这种形态），
/// 等于把学习路径整个关掉。现在连续成功本身就会清零失败计数，因此「连续失败 N 次」
/// 已经隐含了「最近没有成功过」。
({bool promote, EvidenceKind record, String reason}) judgeSetback({
  required LearningPolicy policy,
  required int consecutiveFailures,
  required RoutePreference? currentPreference,
  required bool stalled,
  required bool poisoned,
}) {
  final threshold = policy.setbackThreshold(poisoned: poisoned);
  final record = stalled ? EvidenceKind.stall : EvidenceKind.connectionFailure;
  final alreadyForced = currentPreference == RoutePreference.forceProxy;

  if (consecutiveFailures >= threshold && !alreadyForced) {
    return (
      promote: true,
      record: record,
      reason: poisoned
          ? '解析结果不一致，已自动改为走隧道'
          : stalled
          ? '连续 $consecutiveFailures 次直连握手成功但没有数据，已自动改为走隧道'
          : '连续 $consecutiveFailures 次判为直连但失败，已自动改为走隧道',
    );
  }

  return (
    promote: false,
    record: record,
    reason: stalled
        ? '直连握手成功但没有数据 $consecutiveFailures/$threshold 次，继续观察'
        : '失败 $consecutiveFailures/$threshold 次，继续观察',
  );
}

/// 记一次「确实交付」之后是否该撤销学到的强制代理规则。
///
/// 用**连续**成功而不是累计成功：实测的坏时段里失败成簇、成功偶尔插进来，
/// 累计计数会让两次侥幸成功就推翻刚学到的规则，规则因此反复横跳。
///
/// 用户指定的规则不动——那是人的明确决定。
bool shouldRevokeLearnedProxy({
  required LearningPolicy policy,
  required int consecutiveSuccesses,
  required RouteRuleSource source,
  required RoutePreference preference,
}) =>
    source == RouteRuleSource.learned &&
    preference == RoutePreference.forceProxy &&
    consecutiveSuccesses >= policy.revokeSuccessThreshold;

/// 同类观测的时间窗限流。
///
/// 为什么需要它（两种错误做法各踩过一个）：
///
///   * **一次会话只记一次**：一个域名最多只能贡献 1 次观测，而晋升需要连续 3 次、
///     撤销也需要连续 3 次，于是**两条阈值都永远攒不满**——挂死推不动晋升，
///     成功也撤销不了规则。这是把「够不够」交给「记几次」来管，而它们本来该由
///     阈值来管。
///   * **每条连接都记**：一次页面加载会开出几十条连接，同一个故障会被重复计成
///     几十次，阈值同样失去意义。
///
/// 因此用时间窗：同一个域名在 [LearningPolicy.outcomeWindow] 内只记一次。
/// 一次故障里的多条连接被折成一次观测，而持续存在几分钟的问题会稳定累积——
/// 这正是「这个域名现在是不是有问题」想问的东西。
///
/// 这是本模块里唯一带状态的东西，而它只是一张「最近记过什么」的表，
/// 与路由规则无关。
class OutcomeThrottle {
  OutcomeThrottle({required this.policy});

  final LearningPolicy policy;

  /// 每类证据各一份「最近记录时刻」，按域名索引。
  ///
  /// 分类存放而不是合成一个带类的键：不同类证据互不影响，同名的两种证据
  /// 不该互相限流（一个域名完全可能既挂死过、也正常交付过——那正是「不稳定」
  /// 这件事本身）。
  final Map<EvidenceKind, Map<String, DateTime>> _last = <EvidenceKind, Map<String, DateTime>>{
    for (final kind in EvidenceKind.values) kind: <String, DateTime>{},
  };

  /// 该域名此刻是否该记这一类观测。
  ///
  /// 返回 true 时**同时**打上时间戳，因此调用方不需要（也不该）再单独调用一次
  /// 记录——分开写会引入「检查与记录之间被插入别的观测」的窗口。
  bool tryRecord(EvidenceKind kind, String domain, DateTime now) {
    final log = _last[kind]!;
    final last = log[domain];
    if (last != null && now.difference(last) < policy.outcomeWindow) {
      return false;
    }
    log[domain] = now;
    if (log.length > policy.maxOutcomeLog) log.clear();
    return true;
  }

  /// 该域名是否在时间窗内已经记过这一类观测。只读，用于诊断与测试。
  bool recentlyRecorded(EvidenceKind kind, String domain, DateTime now) {
    final last = _last[kind]![domain];
    return last != null && now.difference(last) < policy.outcomeWindow;
  }

  void clear() {
    for (final log in _last.values) {
      log.clear();
    }
  }
}
