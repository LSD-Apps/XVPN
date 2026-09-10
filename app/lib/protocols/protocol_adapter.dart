import 'openvpn_adapter.dart';
import 'parsed_profile.dart';
import 'vpn_protocol.dart';
import 'wireguard_adapter.dart';

/// 生成内核端点片段时的上下文。
class OutboundContext {
  const OutboundContext({required this.tag, required this.resolverTag});

  /// 出站/端点标签。路由规则与 `route.final` 都引用它。
  final String tag;

  /// 用于解析「服务端域名」的 DNS 服务器标签。
  ///
  /// 服务端域名必须用直连解析器解析：隧道还没建立时无法经隧道解析，
  /// 解析不出来就建不了隧道，会形成死锁。
  final String resolverTag;
}

/// 单个协议的适配器：负责「解析该协议的配置」与「生成内核端点片段」。
///
/// 新增协议只需要实现这个接口并注册进 [VpnProtocolFactory.adapters]。
abstract class VpnProtocolAdapter {
  /// 本适配器对应的协议。
  VpnProtocol get protocol;

  /// 判断这份文本是否属于本协议。
  ///
  /// 要求按**内容**判断而不是只看扩展名：`.conf` 既可能是 WireGuard，
  /// 也可能是 OpenVPN（OpenVPN 客户端常把配置存成 .conf）。
  bool canParse(String text, String fileName);

  /// 解析配置。失败时抛出 [VpnConfigException]，消息面向用户。
  ///
  /// [username] / [password] 用于需要额外凭据的协议（如 OpenVPN 的
  /// auth-user-pass）；不需要凭据的协议可以忽略。
  ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  });

  /// 生成 sing-box 的端点/出站片段。
  Map<String, Object?> buildEndpoint(ParsedProfile profile, OutboundContext context);
}

/// 协议工厂：按内容自动识别协议，并分发到对应适配器。
class VpnProtocolFactory {
  VpnProtocolFactory._();

  /// 已注册的适配器。新增协议时在这里加一项即可。
  static final List<VpnProtocolAdapter> adapters = <VpnProtocolAdapter>[
    WireGuardAdapter(),
    OpenVpnAdapter(),
  ];

  static VpnProtocolAdapter adapterForProtocol(VpnProtocol protocol) {
    for (final adapter in adapters) {
      if (adapter.protocol == protocol) return adapter;
    }
    throw VpnConfigException('暂不支持 ${protocol.label} 配置的导入');
  }

  /// 按内容（必要时参考文件名）识别协议。
  static VpnProtocolAdapter? detect(String text, String fileName) {
    // 先按内容判断；内容无法区分时再用扩展名兜底。
    for (final adapter in adapters) {
      if (adapter.canParse(text, fileName)) return adapter;
    }
    return null;
  }

  /// 解析任意已支持的配置文本。
  static ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  }) {
    if (text.trim().isEmpty) {
      throw VpnConfigException('文件内容为空');
    }
    final adapter = detect(text, fileName);
    if (adapter == null) {
      throw VpnConfigException(
        '无法识别这份配置的协议。目前支持 ${importableProtocols.map((p) => p.label).join(' / ')}，'
        '请确认导入的是这些客户端导出的配置文件。',
      );
    }
    return adapter.parse(text, fileName, username: username, password: password);
  }

  /// 某个文件名是否可能是受支持的配置。
  static bool looksSupported(String fileName) {
    final lower = fileName.toLowerCase();
    for (final ext in allSupportedExtensions) {
      if (lower.endsWith('.$ext')) return true;
    }
    return false;
  }
}
