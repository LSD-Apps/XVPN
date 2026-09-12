import 'protocols/parsed_profile.dart';
import 'protocols/vpn_protocol.dart';

/// 隧道状态机。
///
/// [warmingUp] 是「内核已经就绪、但隧道还不能载流量」这一段。它不是实现细节，
/// 而是**用户实际能感觉到的一段等待**：实测同一可用节点上，内核报就绪时
/// WireGuard 握手仍在进行，约 5 秒后才有第一个成功往返，这期间走隧道的请求
/// 全部超时。把这一段单独说出来，用户看到的才是「正在建立隧道」，而不是
/// 「明明显示已连接，却什么都打不开」。
enum VpnStatus { disconnected, connecting, warmingUp, connected }

/// 状态文案的**唯一来源**。
///
/// 三处界面（连接页页头、桌面端页头、分流页页头）都要显示它。此前各自写一份
/// switch，直接后果就是「建立隧道中」只在移动端存在——桌面端的页头根本没有
/// 状态位。把映射挂在枚举上，两端能差的只剩「放在哪」，不再是「有没有」。
extension VpnStatusX on VpnStatus {
  String get label => switch (this) {
    VpnStatus.connected => '已连接',
    VpnStatus.warmingUp => '建立隧道中',
    VpnStatus.connecting => '连接中',
    VpnStatus.disconnected => '未连接',
  };
}

/// 导入一份配置的结果。
enum ImportOutcome {
  /// 可以直接用了。
  imported,

  /// 配置本身没问题，但它需要账号密码（OpenVPN 的 auth-user-pass）而这次
  /// 没带上。**配置已经导入成功**，界面应当弹表单补填，而不是报错——
  /// 用户中途取消也只是暂时连不上，不会丢掉刚导入的配置。
  needsCredentials,
}

/// 一条连接被判定的结果。UI 用它渲染「代理 / 直连」标签。
enum RouteKind { proxy, direct }

/// 分流模式。默认智能分流即「命中规则集的流量直连、其余走代理」。
enum SplitMode { smart, globalProxy, globalDirect }

extension SplitModeX on SplitMode {
  String get label => switch (this) {
    SplitMode.smart => '智能分流',
    SplitMode.globalProxy => '全局代理',
    SplitMode.globalDirect => '全局直连',
  };

  String get description => switch (this) {
    SplitMode.smart => '命中规则集的域名与 IP 直连，其余走隧道',
    SplitMode.globalProxy => '所有流量都经过隧道',
    SplitMode.globalDirect => '不使用隧道，仅保持连接',
  };
}

extension RouteKindX on RouteKind {
  String get label => this == RouteKind.proxy ? '代理' : '直连';
}

/// 一个已导入的 VPN 配置。除文件名外全部来自配置文件解析结果，
/// 用户不需要手填任何字段。
class VpnProfile {
  const VpnProfile({
    required this.id,
    required this.name,
    required this.parsed,
  });

  final String id;

  /// 展示名，默认取配置文件名。
  final String name;

  /// 协议无关的解析结果。界面与配置生成都只依赖它，
  /// 因此新增协议时二者都不需要改动。
  final ParsedProfile parsed;

  /// 协议类型，用于界面标注与工厂分发。
  VpnProtocol get protocolType => parsed.protocol;

  String get endpointDisplay => parsed.serverDisplay;

  String get tunnelAddressDisplay => parsed.addressDisplay;

  /// 配置里声明的 DNS。UI 仅作展示，真正的解析策略由内置规则决定。
  String get dnsDisplay => parsed.dnsDisplay;
}

/// 分流记录：只记录域名与判定结果，不记录请求内容。
///
/// **同一个目标只会有一条记录**。此前的实现是「一条连接一条记录」，于是打开一个
/// 视频网站，列表里会刷出几十条一模一样的域名——真正要看的信息（走了哪条路、
/// 跑了多少流量、有没有失败）全被自己淹没了。现在同目标的多次访问合并到一条：
/// [connections] 累加次数，[uploadBytes] / [downloadBytes] 累加流量，
/// [lastSeen] 记录最近一次活动时间。
class SplitRecord {
  SplitRecord({
    required this.time,
    required this.target,
    required this.kind,
    required this.rule,
    required this.outbound,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.connections = 1,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? time;

  /// 本目标**首次**出现的时间。列表顺序按它保持稳定，行不会因更新而跳动。
  final DateTime time;

  final String target;
  final RouteKind kind;

  /// 命中的规则名，例如 geosite-cn / geoip-cn / 默认规则。
  final String rule;
  final String outbound;

  /// 累计上传 / 下载字节。由内核的精确计数逐轮取增量累加而来。
  int uploadBytes;
  int downloadBytes;

  /// 被访问过多少次（合并了几条连接）。
  int connections;

  /// 最近一次活动时间。
  DateTime lastSeen;

  /// 该目标发生过多少次连接失败。由状态层按目标回填——内核只在日志里给出失败，
  /// 不把它算进连接快照。
  int failures = 0;

  int get totalBytes => uploadBytes + downloadBytes;

  String get timeDisplay => _clock(time);

  /// 最近活动的时刻，形如 `14:03:21`。用户据此判断这条记录有多新。
  String get lastSeenDisplay => _clock(lastSeen);

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// 一条连接上的**流量增量**。
///
/// 为什么需要单独一个类型：分流记录现在按目标合并成一行，而流量是随连接存活的
/// 每一秒增长的。内核给的是「该连接累计多少字节」，只有把它与上一轮的值相减，
/// 才能得到「这一秒新增多少」，从而累加进那一行。
///
/// 用增量而不是累计值，是为了让状态层不必自己保存每个连接的历史——那份账本
/// 留在观测引擎里，与「谁负责读内核」这件事待在一起。
class ConnectionTraffic {
  const ConnectionTraffic({
    required this.target,
    required this.kind,
    required this.uploadDelta,
    required this.downloadDelta,
  });

  final String target;
  final RouteKind kind;

  /// 自上一轮以来新增的上传 / 下载字节。
  final int uploadDelta;
  final int downloadDelta;

  int get totalDelta => uploadDelta + downloadDelta;
}

/// 用户可调项。全部有合理默认值，不改也能正常使用。
class AppSettings {
  const AppSettings({
    this.autoConnectOnImport = true,
    this.splitMode = SplitMode.smart,
    this.logSplits = true,
    this.ruleSetUpdatedAt,
  });

  final bool autoConnectOnImport;
  final SplitMode splitMode;
  final bool logSplits;
  final DateTime? ruleSetUpdatedAt;

  AppSettings copyWith({
    bool? autoConnectOnImport,
    SplitMode? splitMode,
    bool? logSplits,
    DateTime? ruleSetUpdatedAt,
  }) {
    return AppSettings(
      autoConnectOnImport: autoConnectOnImport ?? this.autoConnectOnImport,
      splitMode: splitMode ?? this.splitMode,
      logSplits: logSplits ?? this.logSplits,
      ruleSetUpdatedAt: ruleSetUpdatedAt ?? this.ruleSetUpdatedAt,
    );
  }
}
