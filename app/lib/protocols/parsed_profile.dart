import 'vpn_protocol.dart';

/// 导入失败的统一异常。message 直接面向用户，因此必须是可读的中文说明。
class VpnConfigException implements Exception {
  VpnConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 配置提示的严重程度。
///
/// - [warn]：必须知道，否则会连不上或明显异常
/// - [info]：建议知道，影响性能或稳定性
enum ProfileNoticeKind { warn, info }

/// 面向用户的一条配置提示。
///
/// 与 [ParsedProfile.details] 的键值事实分开：事实给人核对字段，提示给人做决策。
/// 导入确认、桌面列表、移动端共用同一类型，避免各处用字符串 `kind` 分叉。
class ProfileNotice {
  const ProfileNotice.warn(this.message) : kind = ProfileNoticeKind.warn;

  const ProfileNotice.info(this.message) : kind = ProfileNoticeKind.info;

  final ProfileNoticeKind kind;
  final String message;

  bool get isWarn => kind == ProfileNoticeKind.warn;
}

/// 一份已导入配置的协议无关视图。
///
/// 界面与配置生成只依赖这个抽象，因此新增协议时二者都不需要改动；
/// 协议特有的字段通过 [details] 以「标签 + 值」的形式暴露出来。
///
/// 各协议用 **extends** 而不是 implements：共享的 [displayDetails] /
/// [unusedKeys] / [needsIpv4OnlyDns] 等默认实现才能真正生效，
/// 避免每个协议再抄一份或各写各的。
abstract class ParsedProfile {
  const ParsedProfile();

  /// 所属协议。
  VpnProtocol get protocol;

  /// 服务器展示串，例如 `vpn.example.net:51820`。
  String get serverDisplay;

  /// 隧道地址展示串，例如 `10.0.0.3`。某些协议没有这个概念，返回 `—`。
  String get addressDisplay;

  /// DNS 展示串。
  String get dnsDisplay;

  /// 配置里声明的解析器地址。用于挑选隧道内使用的 DNS；
  /// 没有声明的协议（如 OpenVPN）返回空列表。
  List<String> get declaredDns;

  /// 隧道是否具备 IPv6 地址。决定是否需要把 DNS 策略收紧为 ipv4_only——
  /// 隧道里没有 IPv6 时仍然解析 AAAA，会让部分网站打不开。
  bool get hasIpv6;

  /// DNS 策略是否要收紧成 `ipv4_only`。
  ///
  /// 默认跟随 [hasIpv6]，因为「隧道没有 IPv6 本地地址却解析出 AAAA」会让内核
  /// 直接报 `missing IPv6 local address`（实测：youtube 打不开而 google 正常）。
  ///
  /// 但这个推理只对**自带隧道地址**的协议成立。Hysteria2 这类「流式代理」没有
  /// 隧道地址：目标域名由服务端去连接，客户端侧不存在 IPv6 本地地址的问题。
  /// 此时收紧成 ipv4_only 反而会让 IPv6-only 的站点直接失败，因此它覆写为 false。
  bool get needsIpv4OnlyDns => !hasIpv6;

  /// 生成内核配置时是否要打开 DEBUG 级日志。
  ///
  /// 内核的 WireGuard 握手里程碑走的是 DEBUG 级（`Verbosef` → `Logger.Debug`，
  /// 见 sing-box 的 `transport/wireguard`），因此**日志级别就是握手状态唯一的
  /// 开关**：停在默认的 `warn`，那几行里程碑根本不会产生，解析器再正确也永远
  /// 拿不到数据。只有需要读握手状态的协议在这里返回 true；其余协议保持 `warn`，
  /// 免得把日志缓冲刷成噪声——内核日志是排查问题的原材料，噪声会把它淹掉。
  ///
  /// 这是「按需」而不是全局调成 debug：两端共用同一个配置生成器，因此这个值
  /// 决定了 PC 与移动端完全一致的行为。
  bool get wantsDebugLogs => false;

  /// 协议特有的补充信息（不含「未使用字段」——那由 [unusedKeys] 统一追加）。
  List<({String label, String value})> get details;

  /// 配置里出现、但本客户端未映射到内核的键名。
  ///
  /// 各协议自己收集；界面通过 [displayDetails] 统一挂上「未使用字段」行，
  /// 避免 Hy2 写在 details、OVPN 静默丢掉、WG 各搞一套。
  List<String> get unusedKeys => const <String>[];

  /// 配置页实际展示的键值：协议 [details] + 若有则追加未使用字段。
  List<({String label, String value})> get displayDetails {
    final unused = unusedKeys;
    if (unused.isEmpty) return details;
    return <({String label, String value})>[
      ...details,
      (label: '未使用字段', value: unused.join('、')),
    ];
  }

  /// 面向用户的配置提示（与 [details] 的键值事实分开）。
  ///
  /// 导入确认表单与配置列表都应优先展示，不能只埋在普通字段里。
  List<ProfileNotice> get notices => const <ProfileNotice>[];

  /// 是否需要用户额外提供用户名/密码（例如 OpenVPN 的 auth-user-pass）。
  bool get requiresCredentials;

  /// 配置里声明的隧道 MTU；没声明或该协议没有这个概念时为 null。
  ///
  /// 单独提出来（而不是只放在 [details] 里给人看）是因为它要参与判断：
  /// MTU 配得比实际路径大，现象是「小请求正常、一传大东西就卡死」——极难自证，
  /// 而配置里就有这个数字，值得拿它做一次校验。
  int? get declaredMtu;
}
