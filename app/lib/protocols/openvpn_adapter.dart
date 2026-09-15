import 'openvpn_conf.dart';
import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'protocol_tuning.dart';
import 'vpn_protocol.dart';

/// OpenVPN 适配器。
///
/// 内核侧由 sing-box 的 openvpn 端点实现（构建时带 `with_openvpn` 标签），
/// 因此不需要额外引入 OpenVPN 二进制，分流与 DNS 策略与其它协议完全一致。
class OpenVpnAdapter implements VpnProtocolAdapter {
  @override
  VpnProtocol get protocol => VpnProtocol.openVpn;

  /// OpenVPN 自带隧道地址（服务端通过 PUSH_REPLY 下发），是 endpoint 类协议。
  @override
  FragmentPlacement get placement => FragmentPlacement.endpoint;

  /// 按内容识别 OpenVPN 配置。
  ///
  /// 注意 `.conf` 扩展名双方都可能用，所以必须有可靠的指令特征：
  /// 内联证书块，或 `remote` 与 client/dev/proto 的组合。
  @override
  bool canParse(String text, String fileName) {
    final lower = text.toLowerCase();
    if (lower.contains('<ca>') ||
        lower.contains('<cert>') ||
        lower.contains('<tls-auth>')) {
      return true;
    }
    final hasRemote = RegExp(
      r'^[ \t]*remote[ \t]+\S+',
      multiLine: true,
    ).hasMatch(lower);
    if (!hasRemote) return false;
    final hasClientMarker = RegExp(
      r'^[ \t]*(client|dev[ \t]+tun|proto[ \t]+(udp|tcp))',
      multiLine: true,
    ).hasMatch(lower);
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
  Map<String, Object?> buildEndpoint(
    ParsedProfile profile,
    OutboundContext context,
  ) {
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

    // ---- 加密套件 ------------------------------------------------------
    //
    // 这里做两件都是被实测错误逼出来的事：
    //
    //  1. **归一化成规范名**。sing-box 要求 data_ciphers /
    //     data_ciphers_fallback 里的名字必须是 OpenVPN 官方的大写规范名，
    //     写成小写会直接 FATAL：
    //     「ClientOptions.DataChannel.Ciphers[0] must use a canonical
    //       OpenVPN cipher name」——内核整体起不来，用户只看到「连不上」。
    //     认不出的名字一律剔除：剔除只让协商范围变小，原样传会让内核挂掉。
    //
    //  2. **把 fallback 单独下发**。OpenVPN 2.4 及以上用 `data-ciphers`
    //     协商，`data-ciphers-fallback` 是给「服务端只支持老套件」时的兜底。
    //     老实现把 `cipher` 直接并进 data_ciphers，于是客户端会主动提议一个
    //     服务端根本不会选的套件；更糟的是严格服务端会因此拒绝协商。
    final primary = canonicalizeCipherList(
      conf.dataCiphers.isNotEmpty
          ? conf.dataCiphers
          : <String>[if (conf.cipher != null) conf.cipher!],
    );
    final dataCiphers = preferFastCiphersFirst(primary.ciphers);

    // 显式声明的 fallback 优先；否则用老式 `cipher` 指令的值。
    String? fallback;
    final declaredFallback = conf.dataCiphersFallback;
    if (declaredFallback != null && declaredFallback.isNotEmpty) {
      fallback = canonicalizeCipher(declaredFallback);
    } else if (conf.cipher != null && conf.cipher!.isNotEmpty) {
      final canonical = canonicalizeCipher(conf.cipher!);
      // 只有当它没有被 data-ciphers 覆盖时才值得作为兜底下发。
      if (canonical != null && !dataCiphers.contains(canonical)) {
        fallback = canonical;
      }
    }

    // 摘要名同样是规范名敏感的：`sha256` 会让内核 FATAL。
    final auth = conf.auth == null ? null : canonicalizeAuth(conf.auth!);

    final tls = <String, Object?>{
      if (conf.ca != null && conf.ca!.isNotEmpty)
        'certificate': <String>[conf.ca!],
      if (conf.cert != null && conf.cert!.isNotEmpty)
        'client_certificate': <String>[conf.cert!],
      if (conf.key != null && conf.key!.isNotEmpty)
        'client_key': <String>[conf.key!],
      if (controlWrap.isNotEmpty) 'control_wrap': controlWrap,
      // `server_name` **只在配置明确要求校验服务端证书名时才写**。
      //
      // 这条是拿真实节点验出来的，不是推的：sing-box 的 `openvpn-client` 会把
      // `tls.server_name` 拿去做 **verify-x509-name 式的名字校验**。此前这里无条件
      // 写 `conf.remoteHost`，于是 `remote` 写成 IP 的配置（服务商直接给 IP 端点
      // 是常态）必然连不上——对端证书是签给域名的，实测报：
      //   endpoint/openvpn-client[vpn]: client terminated:
      //     (peer certificate verification failed |
      //      peer certificate fails verify-x509-name check)
      // 现象是「界面显示已连接、什么都没通」，而 OpenVPN 官方客户端连同一份配置
      // 是好的。
      //
      // OpenVPN 自身在没有 `verify-x509-name` 时**不校验主机名**，只校验证书链与
      // `remote-cert-tls server` 要求的服务端用途。这里照做：声明了
      // `verify-x509-name` 就把名字钉上去，没声明就不写——主机名校验交还给本来就在
      // 的那两道关（证书链 + 服务端用途）。
      //
      // 顺带说明 SNI 不受影响：OpenVPN 默认也不发 SNI（要发得用 `--tls-hostname`），
      // 实测不带 server_name 时握手正常、隧道能建立。
      if (conf.verifyX509Name != null) 'server_name': conf.verifyX509Name!,
      // `remote-cert-tls server` 的等价物。
      //
      // 这条指令在客户端配置里几乎必然存在（所有主流向导生成的配置都带），
      // 含义是「只接受服务端证书」。映射到 sing-box 就是
      // `remote_certificate_tls: server`。不映射等于悄悄丢掉了服务端身份校验。
      if (conf.requiresServerCert) 'remote_certificate_tls': 'server',
    };

    final mtu = resolveMtu(conf);

    return <String, Object?>{
      'type': 'openvpn-client',
      'tag': context.tag,
      'server': conf.remoteHost,
      'server_port': conf.remotePort,
      'network': conf.network,
      'mtu': mtu,
      if (conf.username != null) 'username': conf.username,
      if (conf.password != null) 'password': conf.password,
      if (dataCiphers.isNotEmpty) 'data_ciphers': dataCiphers,
      'data_ciphers_fallback': ?fallback,
      'auth': ?auth,
      'tls': tls,
      // 保活：时长必须带单位，写成裸整数会被内核拒绝。
      if (conf.pingInterval != null && conf.pingInterval! > 0)
        'ping_interval': '${conf.pingInterval}s',
      if (conf.pingRestartDisabled)
        'ping_restart_disabled': true
      else if (conf.pingRestart != null && conf.pingRestart! > 0)
        'ping_restart': '${conf.pingRestart}s',
      if (conf.mssFix != null && conf.mssFix! > 0) 'mss_fix': conf.mssFix,
    };
  }

  /// 端点 MTU：优先配置的 `tun-mtu`（经合理性校验），否则协议默认 1500。
  static int resolveMtu(OpenVpnConf conf) =>
      sanitizeMtu(conf.tunMtu) ?? defaultTunMtu;

  /// TUN 入站的 MTU 与端点保持一致，避免系统栈组出装不进隧道的包。
  @override
  int tunMtu(ParsedProfile profile) {
    if (profile is! OpenVpnProfile) return defaultTunMtu;
    return resolveMtu(profile.conf);
  }

  /// OpenVPN 的 `tun-mtu` 默认值。
  static const int defaultTunMtu = 1500;
}
