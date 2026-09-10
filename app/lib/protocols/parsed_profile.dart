import 'vpn_protocol.dart';

/// 导入失败的统一异常。message 直接面向用户，因此必须是可读的中文说明。
class VpnConfigException implements Exception {
  VpnConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一份已导入配置的协议无关视图。
///
/// 界面与配置生成只依赖这个抽象，因此新增协议时二者都不需要改动；
/// 协议特有的字段通过 [details] 以「标签 + 值」的形式暴露出来。
abstract class ParsedProfile {
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

  /// 协议特有的补充信息，用于「配置文件」页展示。
  List<({String label, String value})> get details;

  /// 是否需要用户额外提供用户名/密码（例如 OpenVPN 的 auth-user-pass）。
  bool get requiresCredentials;
}
