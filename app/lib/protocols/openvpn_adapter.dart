import 'openvpn_conf.dart';
import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'vpn_protocol.dart';

/// OpenVPN 适配器。
///
/// 内核侧由 sing-box 的 openvpn 端点实现（构建时带 `with_openvpn` 标签），
/// 因此不需要额外引入 OpenVPN 二进制，分流与 DNS 策略与其它协议完全一致。
class OpenVpnAdapter implements VpnProtocolAdapter {
  @override
  VpnProtocol get protocol => VpnProtocol.openVpn;

  /// 按内容识别 OpenVPN 配置。
  ///
  /// 注意 `.conf` 扩展名双方都可能用，所以必须有可靠的指令特征：
  /// 内联证书块，或 `remote` 与 client/dev/proto 的组合。
  @override
  bool canParse(String text, String fileName) {
    final lower = text.toLowerCase();
    if (lower.contains('<ca>') || lower.contains('<cert>') || lower.contains('<tls-auth>')) {
      return true;
    }
    final hasRemote = RegExp(r'^[ \t]*remote[ \t]+\S+', multiLine: true).hasMatch(lower);
    if (!hasRemote) return false;
    final hasClientMarker =
        RegExp(r'^[ \t]*(client|dev[ \t]+tun|proto[ \t]+(udp|tcp))', multiLine: true)
            .hasMatch(lower);
    return hasClientMarker;
  }

  @override
  ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  }) {
    return OpenVpnProfile(
      OpenVpnConf.parse(text, username: username, password: password),
    );
  }

  @override
  Map<String, Object?> buildEndpoint(ParsedProfile profile, OutboundContext context) {
    if (profile is! OpenVpnProfile) {
      throw VpnConfigException('内部错误：配置与协议不匹配');
    }
    final conf = profile.conf;

    // 控制通道保护。以下字段名与取值全部由 sing-box 1.14 的校验器实测确定：
    //   * endpoint 类型名是 `openvpn-client`，不是 `openvpn`；
    //   * `tls-auth` / `tls-crypt` 走 `tls.control_wrap`，其 type 用下划线
    //     （`tls_auth` / `tls_crypt`）；
    //   * `direction` 取 `server` / `client`，且只对 tls_auth 有效；
    //   * TLS 模式下不支持顶层的 `static_key` 与 `cipher`，加密套件统一用
    //     `data_ciphers` 表达。
    final Map<String, Object?> controlWrap = <String, Object?>{};
    if (conf.usesTlsCrypt) {
      controlWrap['type'] = 'tls_crypt';
      controlWrap['key'] = <String>[conf.tlsCrypt!];
    } else if (conf.tlsAuth != null && conf.tlsAuth!.isNotEmpty) {
      controlWrap['type'] = 'tls_auth';
      controlWrap['key'] = <String>[conf.tlsAuth!];
      // openvpn 的 key-direction：1 = 客户端，0 = 服务端。
      // 未显式声明时不传，保持双向模式。
      final direction = switch (conf.keyDirection) {
        1 => 'client',
        0 => 'server',
        _ => null,
      };
      if (direction != null) controlWrap['direction'] = direction;
    }

    // 加密套件：优先 data-ciphers（OpenVPN 2.4+ 的推荐写法）；
    // 只有老式 cipher 时把它并进去，避免它被 TLS 模式拒绝。
    final dataCiphers = conf.dataCiphers.isNotEmpty
        ? conf.dataCiphers
        : <String>[if (conf.cipher != null) conf.cipher!];

    final tls = <String, Object?>{
      if (conf.ca != null && conf.ca!.isNotEmpty)
        'certificate': <String>[conf.ca!],
      if (conf.cert != null && conf.cert!.isNotEmpty)
        'client_certificate': <String>[conf.cert!],
      if (conf.key != null && conf.key!.isNotEmpty)
        'client_key': <String>[conf.key!],
      if (controlWrap.isNotEmpty) 'control_wrap': controlWrap,
      // 服务端域名同样使用直连解析器，理由与 WireGuard 端点一致。
      'server_name': conf.remoteHost,
    };

    return <String, Object?>{
      'type': 'openvpn-client',
      'tag': context.tag,
      'server': conf.remoteHost,
      'server_port': conf.remotePort,
      'network': conf.network,
      if (conf.username != null) 'username': conf.username,
      if (conf.password != null) 'password': conf.password,
      if (dataCiphers.isNotEmpty) 'data_ciphers': dataCiphers,
      if (conf.auth != null) 'auth': conf.auth,
      'tls': tls,
    };
  }
}
