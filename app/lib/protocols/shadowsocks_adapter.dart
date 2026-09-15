import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'shadowsocks_conf.dart';
import 'vpn_protocol.dart';

/// Shadowsocks 适配器。
///
/// 与 Hysteria2 同类：流式代理，片段进 `outbounds`，没有隧道地址。
/// 放进 `endpoints` 内核会直接拒绝启动。
class ShadowsocksAdapter implements VpnProtocolAdapter {
  @override
  VpnProtocol get protocol => VpnProtocol.shadowsocks;

  @override
  FragmentPlacement get placement => FragmentPlacement.outbound;

  @override
  bool canParse(String text, String fileName) {
    final trimmed = text.trimLeft();
    final firstLine = ShadowsocksConf.firstMeaningfulLine(trimmed).toLowerCase();
    if (firstLine.startsWith('ss://')) return true;
    if (trimmed.startsWith('{')) {
      final lower = trimmed.toLowerCase();
      return lower.contains('"shadowsocks"') && lower.contains('"server"');
    }
    return false;
  }

  @override
  ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  }) {
    return ShadowsocksProfile(ShadowsocksConf.parse(text));
  }

  @override
  Map<String, Object?> buildEndpoint(
    ParsedProfile profile,
    OutboundContext context,
  ) {
    if (profile is! ShadowsocksProfile) {
      throw VpnConfigException('内部错误：配置与协议不匹配');
    }
    final conf = profile.conf;
    return <String, Object?>{
      'type': 'shadowsocks',
      'tag': context.tag,
      'server': conf.server,
      'server_port': conf.port,
      'method': conf.method,
      'password': conf.password,
      if (conf.plugin != null) 'plugin': conf.plugin,
      if (conf.pluginOpts != null) 'plugin_opts': conf.pluginOpts,
      // 服务端域名必须用直连解析器：隧道还没建起来，走隧道解析会死锁。
      'domain_resolver': <String, Object?>{'server': context.resolverTag},
    };
  }

  /// 流式代理没有「TUN MTU 必须等于隧道 MTU」的约束，取以太网标准值。
  @override
  int tunMtu(ParsedProfile profile) => defaultTunMtu;

  static const int defaultTunMtu = 1500;
}
