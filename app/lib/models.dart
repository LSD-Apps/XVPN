import 'protocols/parsed_profile.dart';
import 'protocols/vpn_protocol.dart';

/// 隧道状态机。
enum VpnStatus { disconnected, connecting, connected }

/// 一条连接被判定的结果。UI 用它渲染「代理 / 直连」标签。
enum RouteKind { proxy, direct }

/// 分流模式。默认智能分流即「国内直连、国外走代理」。
enum SplitMode { smart, globalProxy, globalDirect }

extension SplitModeX on SplitMode {
  String get label => switch (this) {
        SplitMode.smart => '智能分流',
        SplitMode.globalProxy => '全局代理',
        SplitMode.globalDirect => '全局直连',
      };

  String get description => switch (this) {
        SplitMode.smart => '国内域名与 IP 直连，其余走隧道',
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
class SplitRecord {
  const SplitRecord({
    required this.time,
    required this.target,
    required this.kind,
    required this.rule,
    required this.outbound,
  });

  final DateTime time;
  final String target;
  final RouteKind kind;

  /// 命中的规则名，例如 geosite-cn / geoip-cn / 默认规则。
  final String rule;
  final String outbound;

  String get timeDisplay {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
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
