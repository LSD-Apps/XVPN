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

/// 一个域名的交付速率相对本机整体水平的结论。
enum RateVerdict {
  /// 样本不足或基准未建立，不下结论。
  ///
  /// 与 [DirectOutcome.pending] 同一条原则：拿不准时不下结论，
  /// 比下错结论安全。
  insufficient,

  /// 与该域名自身的其他观测处在同一水平：没有理由改路由。
  healthy,

  /// 明显偏慢（低于基准的 [LearningPolicy.slowFraction]）。
  slow,
}

/// 滚动窗口的中位数。
///
/// 与 `dns_monitor.dart` 的 `LatencyWindow` 是同一个思路（**中位数而不是均值**：
/// 一次 3 秒超时能把均值从 20ms 拉到 100ms 以上，而中位数几乎不受影响），
/// 但刻意不复用那个类——它属于 DNS 监测的词汇，而学习模块不该依赖 DNS 层。
///
/// 容量取小（默认 16）：这里要回答的是「这个域名**现在**快不快」，
/// 而不是「它历史上平均多快」。窗口过大时，一个已经变慢的域名会因为
/// 旧的好样本而迟迟不被判定。
class RollingMedian {
  RollingMedian({this.capacity = 16}) : assert(capacity > 0);

  final int capacity;

  final List<double> _samples = <double>[];

  int get length => _samples.length;

  bool get isEmpty => _samples.isEmpty;

  bool get isNotEmpty => _samples.isNotEmpty;

  void add(double value) {
    if (value.isNaN || value.isInfinite || value < 0) return;
    _samples.add(value);
    while (_samples.length > capacity) {
      _samples.removeAt(0);
    }
  }

  /// 中位数。窗口为空时返回 null。
  double? get median {
    if (_samples.isEmpty) return null;
    final sorted = List<double>.of(_samples)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  void clear() => _samples.clear();
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
    this.minRateSampleBytes = 64 * 1024,
    this.minReferenceSamples = 5,
    this.slowFraction = 0.25,
    this.slowSamplesNeeded = 3,
    this.rateRetryCooldown = const Duration(minutes: 30),
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

  // ---------------------------------------------------------------- 交付速率
  //
  // 为什么需要「速率」这一维度：**二值判据抓不住「能通但很慢」**。
  // 一条连接交付了 50 KB 却用了 30 秒，在 [classifyDirectConnection] 里
  // 算「确实交付」——它确实交付了，只是慢到用户能察觉。
  //
  // 为什么阈值必须是**相对**的：绝对速率没有意义。实测本机国内基线也只有
  // 337 KB/s，而同一批测量里 github.com 的成功样本是 125–760 KB/s。
  // 因此判据是「相对本机整体水平」而不是「相对某个绝对值」。

  /// 一条连接要被计入速率统计，至少需交付这么多字节。
  ///
  /// 取 64 KB 的依据：更小的传输由 TCP 慢启动与往返时延主导，算出来的速率反映的是
  /// 握手过程而不是链路水平。实测里 270 字节的响应（raw 的完整文件）因此被排除在
  /// 外——那是正确行为，不是损失。
  ///
  /// **只需要字节下限，不需要时长下限。** 一开始我加了「至少存活 1 秒」，但测试
  /// 立刻暴露出它的问题：实测里 github.com 的一个**好样本**是 577 KB / 764 ms
  /// （755 KB/s），它会被那道时长下限滤掉——而它正是应该用来**清除偏慢计数**的
  /// 正面证据。而它的保护作用是多余的：速率低本身就蕴含了时长长
  /// （2 KB/s 传 64 KB 必然用了 32 秒），不需要另设门槛。
  final int minRateSampleBytes;

  /// 建立「本机整体水平」这个基准至少需要多少个样本。
  ///
  /// 基准没建立之前不下任何结论：拿几个样本当基准，会把「今天恰好没跑过
  /// 大传输」误判成「所有站点都慢」。
  final int minReferenceSamples;

  /// 低于基准的这个比例即视为「偏慢」。
  ///
  /// 取 1/4：实测里同一次 github.com 的两次成功交付相差 20 倍
  /// （0.76 秒/577 KB 与 12.0 秒/448 KB），因此阈值必须留出足够宽的间隔，
  /// 否则正常的抖动就会被判成偏慢。
  ///
  /// **这是本次引入里最需要现场校准的一个数**：它决定「多慢算慢」，
  /// 而我没有条件在真实坏窗口里标定它。宁可取保守（偏大间隔、偏慢才触发）。
  final double slowFraction;

  /// 直连路径上**连续**多少次偏慢才改判走隧道。
  ///
  /// 与 [promotionThreshold] 同一个理由：单次偏慢可能只是那一次传输的偶然，
  /// 而一次误判会把域名推上隧道、白耗隧道带宽。
  final int slowSamplesNeeded;

  /// 一次「试走隧道但隧道同样慢」之后，多久内不再重试。
  ///
  /// 这个冷却期的存在是为了**防止来回横跳**：若没有它，直连偏慢 → 上隧道 →
  /// 隧道也偏慢 → 回直连 → 直连仍偏慢 → 又上隧道……用户看到的是分流反复变化。
  ///
  /// 用时间而不是「次数」做冷却，是因为它天然衰减、不需要额外的清理逻辑——
  /// 与本项目其它衰减策略（`decayAfter`）保持一致。
  final Duration rateRetryCooldown;

  /// 一条连接的交付速率（字节/秒）。时长非正时返回 null。
  static double? bytesPerSecond(int bytes, Duration duration) {
    if (bytes <= 0) return null;
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return null;
    return bytes / seconds;
  }

  /// 这次观测是否够格计入速率统计。见 [minRateSampleBytes]。
  bool isRateSampleMeaningful(int bytes) => bytes >= minRateSampleBytes;

  /// 判断一个域名的交付速率相对本机整体水平是否偏慢。
  ///
  /// 纯函数：两个中位数与基准样本数进，结论出。因此阈值语义可以逐条直测，
  /// 不需要构造路由表、也不需要伪造网络。
  ///
  /// **刻意不设「该域名至少要有 N 个样本」这道门槛。** 一开始我加了它（要求
  /// `domainSamples >= slowSamplesNeeded`），结果与调用方的**连续计数**重复计了
  /// 一遍「3 次」：判据要 3 个样本才肯给结论，而连续计数又要 3 次偏慢，于是实际
  /// 需要 5 次样本才提升，与文档写的「连续 3 次」不符。测试当场撞出来了。
  ///
  /// 现在样本数量的要求由连续计数**独自**承担——「连续 3 次偏慢」必然意味着
  /// 至少 3 个样本。判据只负责回答「这一次看起来偏慢吗」。
  RateVerdict judgeDeliveryRate({
    required double? domainMedian,
    required double? linkMedian,
    required int linkSamples,
  }) {
    // 基准未建立，或该域名还没有任何样本 → 不下结论。
    if (linkSamples < minReferenceSamples) return RateVerdict.insufficient;
    if (domainMedian == null || linkMedian == null) {
      return RateVerdict.insufficient;
    }
    if (linkMedian <= 0) return RateVerdict.insufficient;
    return domainMedian < linkMedian * slowFraction
        ? RateVerdict.slow
        : RateVerdict.healthy;
  }

  /// 此刻是否允许发起一次「试走隧道」。
  ///
  /// 冷却期的唯一用途是防止直连/隧道之间来回横跳，见 [rateRetryCooldown]。
  bool rateTrialAllowed({required DateTime now, required DateTime? lastTrialAt}) {
    if (lastTrialAt == null) return true;
    return now.difference(lastTrialAt) >= rateRetryCooldown;
  }

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
