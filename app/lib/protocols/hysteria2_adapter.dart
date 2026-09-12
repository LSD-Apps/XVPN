import 'hysteria2_conf.dart';
import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'vpn_protocol.dart';

/// Hysteria2 适配器。
///
/// 内核侧由 sing-box 的 `hysteria2` 出站实现（构建时带 `with_quic` 标签；
/// 随仓库分发的 Windows 内核与安卓 libbox 都已带上，原因见
/// `scripts/build-libbox.ps1` 的构建标签列表）。
///
/// 本适配器与 WireGuard/OpenVPN 有一个结构差别：Hysteria2 是**流式代理**，
/// 没有隧道地址，生成出来的片段属于 `outbounds` 而不是 `endpoints`。
/// 放错位置内核会直接拒绝启动（实测 `unknown endpoint type: hysteria2`）。
class Hysteria2Adapter implements VpnProtocolAdapter {
  @override
  VpnProtocol get protocol => VpnProtocol.hysteria2;

  @override
  FragmentPlacement get placement => FragmentPlacement.outbound;

  /// 按内容识别三种来源形式。
  ///
  /// 注意识别条件要**足够窄**：本适配器在注册表里排在最后，
  /// 而「一份 YAML 里有 server:」这种条件过于宽松，会把别的配置也吞进来。
  @override
  bool canParse(String text, String fileName) {
    final trimmed = text.trimLeft();
    final lower = trimmed.toLowerCase();

    // 1) 分享链接。按「第一条有意义的行」判断：面板导出与用户存的文件
    //    往往在链接前面写着几行 `#` 说明，直接对整段文本 startsWith 会漏掉，
    //    而漏掉的后果是那份文件根本导入不进来。
    final firstLine = Hysteria2Conf.firstMeaningfulLine(trimmed).toLowerCase();
    if (firstLine.startsWith('hysteria2://') ||
        firstLine.startsWith('hy2://')) {
      return true;
    }

    // 2) sing-box 出站 JSON：类型名与 server 必须同时出现。
    if (trimmed.startsWith('{')) {
      return lower.contains('"hysteria2"') && lower.contains('"server"');
    }

    // 3) 官方客户端 YAML / 面板导出的 YAML：
    //    `server:` 行 + 至少一个 Hysteria2 专有键。
    //    刻意不把 `tls:` 单独当判据——带 tls 段的 YAML 满世界都是。
    final hasServer = RegExp(
      r'^[ \t]*server[ \t]*:',
      multiLine: true,
    ).hasMatch(trimmed);
    if (!hasServer) return false;
    return RegExp(
      r'^[ \t]*(auth|auth_str|authStr|password|obfs|obfs-password|'
      r'obfsPassword|up|down|up_mbps|down_mbps|hopInterval|hop_interval|'
      r'pinSHA256|sni|server_ports|mport)[ \t]*:',
      multiLine: true,
    ).hasMatch(trimmed);
  }

  @override
  ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  }) {
    // Hysteria2 的凭据就在配置里（password / auth），不需要额外弹表单。
    return Hysteria2Profile(Hysteria2Conf.parse(text));
  }

  @override
  Map<String, Object?> buildEndpoint(
    ParsedProfile profile,
    OutboundContext context,
  ) {
    if (profile is! Hysteria2Profile) {
      throw VpnConfigException('内部错误：配置与协议不匹配');
    }
    final conf = profile.conf;

    // TLS 段必须下发，而且 server_name 与 insecure 至少要有其一。
    //
    // 两条都是实测结论，不是照文档写的：
    //   * 完全不写 tls → `initialize outbound[0]: TLS required`，内核起不来；
    //   * 写了 tls 但没有 server_name、也没开 insecure →
    //     `missing server_name or insecure=true`。
    // 因此没声明 SNI 时用服务器名兜底：Hysteria2 服务端默认签的就是服务器域名的
    // 证书，这个兜底在绝大多数部署下正好是对的。
    final tls = <String, Object?>{
      'enabled': true,
      'server_name': conf.sni ?? conf.server,
      if (conf.insecure) 'insecure': true,
      if (conf.alpn.isNotEmpty) 'alpn': conf.alpn,
      if (conf.pinSha256 != null)
        'certificate_public_key_sha256': <String>[conf.pinSha256!],
    };

    return <String, Object?>{
      'type': 'hysteria2',
      'tag': context.tag,
      'server': conf.server,
      'server_port': conf.port,
      // 端口跳跃区间必须是 `a:b` 形式。实测写单端口 `"443"` 会报
      // `bad port range: 443` 并拒绝启动，所以解析阶段就归一化过。
      if (conf.serverPorts.isNotEmpty) 'server_ports': conf.serverPorts,
      // 内核要求带单位的时长（`30` 会报 `missing unit in duration "30"`）。
      if (conf.hopIntervalSeconds != null)
        'hop_interval': '${conf.hopIntervalSeconds}s',
      'password': conf.auth,
      if (conf.obfsPassword != null)
        'obfs': <String, Object?>{
          'type': 'salamander',
          'password': conf.obfsPassword,
        },
      // 服务端上下行带宽：声明后内核不再自动探测，直接按这个值跑拥塞控制。
      if (conf.upMbps != null) 'up_mbps': conf.upMbps,
      if (conf.downMbps != null) 'down_mbps': conf.downMbps,
      // 服务端域名必须用直连解析器解析。
      //
      // 与 WireGuard 端点同理：隧道建立在解析之后，走隧道解析会形成死锁，
      // 表现为「国外站点全部不通、国内站点却正常」。
      'domain_resolver': <String, Object?>{'server': context.resolverTag},
      'tls': tls,
    };
  }

  /// TUN 入站的 MTU。
  ///
  /// 与 WireGuard / OpenVPN 不同，这里**不存在**「TUN MTU 必须等于隧道 MTU」
  /// 的约束：Hysteria2 是流式代理，内层没有 IP 隧道，数据由 QUIC 自己分段并做
  /// 路径 MTU 探测。因此取以太网标准值 1500 即可——反倒是内核默认的 9000
  /// 只会让本机协议栈凑出更大的 TCP 段，再被 QUIC 拆开，白多一次拷贝。
  @override
  int tunMtu(ParsedProfile profile) => defaultTunMtu;

  static const int defaultTunMtu = 1500;
}
