/// OpenVPN .ovpn 解析器。
///
/// 目标是覆盖「客户端导出的、可直接使用」的那一类配置：`remote` + `proto` +
/// 内联证书（`<ca>` / `<cert>` / `<key>` / `<tls-auth>` / `<tls-crypt>`）。
/// 只做纯文本处理，可完整单元测试。
library;

import 'parsed_profile.dart';
import 'protocol_tuning.dart';
import 'vpn_protocol.dart';

class OpenVpnConf {
  const OpenVpnConf({
    required this.remoteHost,
    required this.remotePort,
    required this.network,
    required this.cipher,
    required this.dataCiphers,
    required this.dataCiphersFallback,
    required this.auth,
    required this.ca,
    required this.cert,
    required this.key,
    required this.tlsAuth,
    required this.tlsCrypt,
    required this.keyDirection,
    required this.requiresServerCert,
    required this.verifyX509Name,
    required this.usesStaticKey,
    required this.requiresCredentials,
    required this.username,
    required this.password,
    required this.tunMtu,
    required this.pingInterval,
    required this.pingRestart,
    required this.pingRestartDisabled,
    required this.mssFix,
    required this.remoteCount,
    required this.ignoredDirectives,
  });

  final String? remoteHost;
  final int? remotePort;

  /// `udp` 或 `tcp`。OpenVPN 的 `udp4` / `tcp-client` 等写法会被归一化。
  final String network;

  /// 老式的 `cipher` 指令（OpenVPN 2.3 及以前）。
  final String? cipher;

  /// `data-ciphers`（OpenVPN 2.4+ 的协商列表）。
  final List<String> dataCiphers;

  /// `data-ciphers-fallback`：服务端只支持老套件时的兜底。
  ///
  /// 必须与 [dataCiphers] **分开**下发：把兜底套件并进协商列表，
  /// 会让客户端主动提议一个服务端不会选的套件，严格服务端会直接拒绝协商。
  final String? dataCiphersFallback;

  final String? auth;

  /// 内联的根证书（PEM）。
  final String? ca;

  /// 内联的客户端证书与私钥（PEM）。
  final String? cert;
  final String? key;

  /// `<tls-auth>` 与 `<tls-crypt>` 的内联内容，二者互斥。
  final String? tlsAuth;
  final String? tlsCrypt;
  final int? keyDirection;

  /// 配置声明了 `remote-cert-tls server`，要求校验服务端证书身份。
  ///
  /// 主流向导生成的客户端配置几乎都会带这一条。不映射到内核就等于
  /// 悄悄放弃了服务端身份校验——一个「看起来能连、实际不安全」的降级。
  final bool requiresServerCert;

  /// `verify-x509-name` 指定的服务端证书名（不含可选 type 参数）。未声明为 null。
  ///
  /// 它是**名字断言**，比 [requiresServerCert] 的「只要是服务端证书」更强。
  /// 内核的 `openvpn-client` 端点没有表达它的字段，因此这一条目前**没有被执行**
  /// ——界面会就此给出提示，而不是让用户以为自己钉住的名字正在生效。
  final String? verifyX509Name;

  /// 配置使用静态密钥模式（`secret` 指令或 `<secret>` 内联块）。
  ///
  /// 这是与 TLS 并列的另一种 OpenVPN 模式（手册里的 "Static Key mode"），
  /// 而 sing-box 的 `openvpn-client` 端点只实现 TLS 模式：这类配置即便解析通过，
  /// 握手也必然失败。识别出来是为了能说清楚，而不是让用户对着一个连不上的隧道猜。
  final bool usesStaticKey;

  /// 配置声明了 `auth-user-pass`，需要用户额外提供账号密码。
  final bool requiresCredentials;
  final String? username;
  final String? password;

  /// `tun-mtu`。未声明时为 null，适配器回退到协议默认 1500。
  final int? tunMtu;

  /// `ping` / `keepalive` 的间隔（秒）。
  final int? pingInterval;

  /// `ping-restart` / `keepalive` 的超时（秒）。为 0 时见 [pingRestartDisabled]。
  final int? pingRestart;

  /// `ping-restart 0`：禁用重启计时。
  final bool pingRestartDisabled;

  /// `mssfix` 目标值。裸 `mssfix`（无参数）用 [defaultMssFix]。
  final int? mssFix;

  /// 配置里 `remote` 指令的个数。大于 1 时仅第一个会用于连接。
  final int remoteCount;

  /// 读到但本客户端未映射到内核的指令名（已去重、排序由展示层决定）。
  final List<String> ignoredDirectives;

  /// 用户以为会影响连通性、但本客户端明确不支持的指令。
  ///
  /// 出现在 [ignoredDirectives] 里时会升成 [ProfileNotice]，其余未识别指令
  /// 只进「未使用字段」清单，避免每条冷门指令都弹提示。
  static const Set<String> impactfulIgnoredDirectives = <String>{
    'comp-lzo',
    'comp-lz4',
    'compress',
    'fragment',
    'mssfix-extra',
    'dhcp-option',
    'block-outside-dns',
    'register-dns',
    'http-proxy',
    'socks-proxy',
    'explicit-exit-notify',
  };

  /// 裸 `mssfix` 时的默认 clamp 值（与 OpenVPN 历史默认一致）。
  static const int defaultMssFix = 1450;

  /// 客户端是否自带了完整凭据（内联证书齐全）。
  bool get hasInlineCredentials =>
      cert != null && cert!.isNotEmpty && key != null && key!.isNotEmpty;

  /// 是否使用 tls-crypt（比 tls-auth 更强的控制通道加密）。
  bool get usesTlsCrypt => tlsCrypt != null && tlsCrypt!.isNotEmpty;

  static OpenVpnConf parse(String text, {String? username, String? password}) {
    String? remoteHost;
    int? remotePort;
    // 协议来源有两处，**必须分开存**：`remote host [port] [proto]` 里的是这个
    // remote 专用的，`proto` 指令是全局默认。合成一个变量会让结果取决于两行
    // 谁先出现——同一份配置换个行序就换了协议，这不是严谨。
    String? remoteLineProto;
    String? globalProto;
    String? cipher;
    final dataCiphers = <String>[];
    String? dataCiphersFallback;
    String? auth;
    String? ca;
    String? cert;
    String? key;
    String? tlsAuth;
    String? tlsCrypt;
    int? keyDirection;
    var requiresServerCert = false;
    String? verifyX509Name;
    var requiresCredentials = false;
    int? tunMtu;
    int? pingInterval;
    int? pingRestart;
    var pingRestartDisabled = false;
    int? mssFix;
    var remoteCount = 0;
    final ignored = <String>[];

    // 内联块：<tag> ... </tag>
    final inlineBlocks = <String, String>{};
    final inlinePattern = RegExp(r'<(\w[\w-]*)>\s*([\s\S]*?)\s*</\1>');
    for (final match in inlinePattern.allMatches(text)) {
      inlineBlocks[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
    }
    // 指令部分：去掉内联块，避免证书内容被误当成指令。
    final directives = text.replaceAll(inlinePattern, '\n');

    for (final rawLine in directives.split(RegExp(r'\r?\n'))) {
      final line = _stripComment(rawLine).trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+'));
      final name = parts.first.toLowerCase();
      final value = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      switch (name) {
        case 'remote':
          // 多 remote 时只采用第一个；其余计入 remoteCount 供提示。
          remoteCount += 1;
          if (remoteCount == 1 && parts.length >= 2) {
            remoteHost = parts[1];
            if (parts.length >= 3) remotePort = int.tryParse(parts[2]);
            if (parts.length >= 4) remoteLineProto = parts[3].toLowerCase();
          }
        case 'proto':
          globalProto = value.toLowerCase();
        case 'cipher':
          cipher = value;
        case 'data-ciphers':
          dataCiphers
            ..clear()
            ..addAll(
              value.split(':').map((e) => e.trim()).where((e) => e.isNotEmpty),
            );
        case 'data-ciphers-fallback':
          dataCiphersFallback = value;
        case 'auth':
          auth = value.toUpperCase();
        case 'key-direction':
          keyDirection = int.tryParse(value);
        case 'remote-cert-tls':
          // `remote-cert-tls server` 要求服务端证书具备 server 用途。
          // 这是客户端配置里最重要的身份校验开关之一，必须映射到内核。
          if (value.toLowerCase().split(RegExp(r'\s+')).contains('server')) {
            requiresServerCert = true;
          }
        case 'verify-x509-name':
          // `verify-x509-name <name> [subject|name|name-prefix]`：要求对端证书的
          // X.509 名字等于 name（默认按完整 subject 比对）。
          //
          // 这是一条**名字断言**。内核端点没有对应字段，只能退而求其次地要求
          // 「是服务端证书」；把这个退让如实说出来（见 notices），比让用户以为
          // 名字已经在被校验要诚实。
          verifyX509Name = parts.length >= 2 ? parts[1] : null;
          requiresServerCert = true;
        case 'auth-user-pass':
          // 可能不带参数（交互输入），也可能指向一个文件。
          // 两种情况都需要用户提供凭据：移动端读不到那个文件。
          requiresCredentials = true;
        case 'tun-mtu':
          tunMtu = int.tryParse(value);
        case 'keepalive':
          // keepalive <ping> <restart> ≡ ping + ping-restart
          if (parts.length >= 3) {
            pingInterval = int.tryParse(parts[1]);
            final restart = int.tryParse(parts[2]);
            if (restart == 0) {
              pingRestartDisabled = true;
              pingRestart = null;
            } else {
              pingRestart = restart;
              pingRestartDisabled = false;
            }
          }
        case 'ping':
          pingInterval = int.tryParse(value);
        case 'ping-restart':
          final restart = int.tryParse(value);
          if (restart == 0) {
            pingRestartDisabled = true;
            pingRestart = null;
          } else if (restart != null) {
            pingRestart = restart;
            pingRestartDisabled = false;
          }
        case 'mssfix':
          // 裸 mssfix → 历史默认 1450；带数值则原样采用。
          if (value.trim().isEmpty) {
            mssFix = defaultMssFix;
          } else {
            mssFix = int.tryParse(value);
          }
        case 'client':
        case 'dev':
        case 'nobind':
        case 'persist-key':
        case 'persist-tun':
        case 'resolv-retry':
        case 'verb':
        case 'tls-client':
        case 'pull':
        case 'redirect-gateway':
          // 这些由内核或本 App 自行处理，无需翻译。
          break;
        default:
          ignored.add(name);
      }
    }

    ca = inlineBlocks['ca'];
    cert = inlineBlocks['cert'];
    key = inlineBlocks['key'];
    tlsAuth = inlineBlocks['tls-auth'];
    tlsCrypt = inlineBlocks['tls-crypt'];

    // 静态密钥模式：`secret file` 指令，或内联的 `<secret>` 块。
    // 内联块的内容会被内联正则整段剥掉，指令那一侧什么也留不下，因此**两处都要看**
    // ——只看指令列表会漏掉 `<secret>` 那种写法。
    final usesStaticKey =
        inlineBlocks.containsKey('secret') || ignored.contains('secret');

    // remote 行自带的 proto 更具体，优先于全局 `proto` 默认值。
    //
    // 依据是 OpenVPN 手册对 `--remote host [port] [proto]` 的措辞：「proto
    // indicates the protocol to use when connecting **with the remote**」——它是
    // 针对那一条 remote 的；而 `--proto p` 是「The default protocol is udp when
    // --proto is not specified」。更具体的赢，且与两行的先后顺序无关。
    final network = _normalizeNetwork(remoteLineProto ?? globalProto, 'udp');

    final conf = OpenVpnConf(
      remoteHost: remoteHost,
      remotePort: remotePort ?? defaultRemotePort,
      network: network,
      cipher: cipher,
      dataCiphers: List<String>.unmodifiable(dataCiphers),
      dataCiphersFallback: dataCiphersFallback,
      auth: auth,
      ca: ca,
      cert: cert,
      key: key,
      tlsAuth: tlsAuth,
      tlsCrypt: tlsCrypt,
      keyDirection: keyDirection,
      requiresServerCert: requiresServerCert,
      verifyX509Name: verifyX509Name,
      usesStaticKey: usesStaticKey,
      requiresCredentials: requiresCredentials,
      username: username,
      password: password,
      tunMtu: tunMtu,
      pingInterval: pingInterval,
      pingRestart: pingRestart,
      pingRestartDisabled: pingRestartDisabled,
      mssFix: mssFix,
      remoteCount: remoteCount,
      ignoredDirectives: List<String>.unmodifiable(
        (ignored.toSet().toList()..sort()),
      ),
    );
    conf.validate();
    return conf;
  }

  /// 校验。缺失关键信息时给出可读的中文说明。
  void validate() {
    if (remoteHost == null || remoteHost!.isEmpty) {
      throw VpnConfigException('缺少 remote 指令，无法定位 OpenVPN 服务器');
    }
    if (remotePort == null) {
      throw VpnConfigException('remote 端口无法解析：$remoteHost');
    }
    if (cert != null && key == null) {
      throw VpnConfigException('配置里有客户端证书 <cert>，但缺少对应的私钥 <key>');
    }
    if (key != null && cert == null) {
      throw VpnConfigException('配置里有客户端私钥 <key>，但缺少对应的证书 <cert>');
    }
    // 这里**刻意不因为缺少账号密码而抛错**。
    //
    // 曾经是在这里抛「这份配置需要账号密码（auth-user-pass），请在导入时填写」，
    // 但那条路径有个严重后果：凭据一旦取不回来（换了 Windows 账户、DPAPI 解不开、
    // 用户当时跳过了填写），重新解析就会失败，而恢复流程对解析失败的处理是
    // **跳过这份配置**——用户看到的是「我导入的配置不见了」。
    //
    // 现在改成：配置照常解析成功，[requiresCredentials] 为 true 而 username /
    // password 为空，由上层负责提示用户补填（见 AppState 的连接前检查）。
    // 这样最坏情况只是「连不上并告诉你为什么」，而不是「配置丢了」。
  }

  /// udp4 / udp6 / tcp4 / tcp-client 等写法统一成 udp 或 tcp。
  static String _normalizeNetwork(String? proto, String fallback) {
    if (proto == null || proto.isEmpty) return fallback;
    if (proto.startsWith('tcp')) return 'tcp';
    if (proto.startsWith('udp')) return 'udp';
    return fallback;
  }

  /// `remote` 行省略端口时用的默认值。**与协议无关。**
  ///
  /// 依据：OpenVPN 手册里 `--port` 是「TCP/UDP port number for both local and
  /// remote」，且明写「The current default of 1194 represents the official IANA
  /// port number assignment for OpenVPN」；`--remote host [port]` 省略端口时用的
  /// 就是它。也就是说 1194 对 UDP 与 TCP 一视同仁。
  ///
  /// 此前 TCP 在这里取 443 —— 那是把「TCP 部署常选 443」当成默认值，规范里没有
  /// 这回事。代价是**静默连错端口**：`proto tcp` + `remote host`（省略端口）会去连
  /// `host:443`，而配置作者省略端口恰恰是因为服务端就在默认端口上；失败时界面只会
  /// 说「没能连上服务器」，没有任何线索指向端口被改过。
  static const int defaultRemotePort = 1194;

  static String _stripComment(String line) {
    final hash = line.indexOf('#');
    final semi = line.indexOf(';');
    var cut = line.length;
    if (hash != -1) cut = hash;
    if (semi != -1 && semi < cut) cut = semi;
    return line.substring(0, cut);
  }
}

/// OpenVPN 配置的协议无关视图。
class OpenVpnProfile extends ParsedProfile {
  const OpenVpnProfile(this.conf);

  final OpenVpnConf conf;

  @override
  VpnProtocol get protocol => VpnProtocol.openVpn;

  @override
  String get serverDisplay => '${conf.remoteHost}:${conf.remotePort}';

  /// OpenVPN 的隧道地址由服务端下发，配置里通常没有，因此不展示具体地址。
  @override
  String get addressDisplay => '由服务端下发';

  @override
  String get dnsDisplay => '内置策略';

  /// OpenVPN 的 DNS 由服务端通过 push 下发，配置里没有可用的解析器地址。
  @override
  List<String> get declaredDns => const <String>[];

  /// 服务端下发 IPv6 配置，这里无法预判，保守地按「没有」处理，
  /// 把 DNS 策略收紧为 ipv4_only，避免出现连不通的等待。
  @override
  bool get hasIpv6 => false;

  /// 与 [hasIpv6] 一致：隧道地址未知时按最保守的方式解析，
  /// 免得内核为 AAAA 记录去建一条本地没有地址的 IPv6 连接。
  @override
  bool get needsIpv4OnlyDns => true;

  /// OpenVPN 没有需要从 DEBUG 日志里读的握手状态，保持 warn。
  @override
  bool get wantsDebugLogs => false;

  @override
  bool get requiresCredentials => conf.requiresCredentials;

  /// 配置声明的 `tun-mtu`（原始值）。超出合理区间时校验层会回退，
  /// 这里仍返回原始值，方便界面区分「用户写了什么」与「实际用了什么」。
  @override
  int? get declaredMtu => conf.tunMtu;

  @override
  List<({String label, String value})> get details =>
      <({String label, String value})>[
        (label: '传输', value: conf.network.toUpperCase()),
        if (conf.cipher != null) (label: '加密', value: conf.cipher!),
        if (conf.dataCiphers.isNotEmpty)
          (label: '数据加密', value: conf.dataCiphers.join(', ')),
        if (conf.auth != null) (label: '认证', value: conf.auth!),
        (
          label: '控制通道',
          value: conf.usesTlsCrypt
              ? 'tls-crypt'
              : (conf.tlsAuth != null ? 'tls-auth' : '无'),
        ),
        (label: '客户端证书', value: conf.hasInlineCredentials ? '已内联' : '无'),
        if (conf.requiresServerCert)
          (
            label: '服务端身份',
            value: conf.verifyX509Name == null
                ? '要求服务端证书'
                : '要求服务端证书（名字断言未执行：${conf.verifyX509Name}）',
          ),
        (
          label: 'MTU',
          value:
              '${sanitizeMtu(conf.tunMtu) ?? 1500}'
              '${sanitizeMtu(conf.tunMtu) == null && conf.tunMtu != null ? '（配置里的 ${conf.tunMtu} 超出合理范围，已回退）' : ''}',
        ),
        if (conf.pingInterval != null ||
            conf.pingRestart != null ||
            conf.pingRestartDisabled)
          (
            label: '保活',
            value: [
              if (conf.pingInterval != null) 'ping ${conf.pingInterval}s',
              if (conf.pingRestartDisabled)
                'ping-restart 已禁用'
              else if (conf.pingRestart != null)
                'restart ${conf.pingRestart}s',
            ].join(' · '),
          ),
        if (conf.mssFix != null) (label: 'MSS', value: '${conf.mssFix}'),
      ];

  @override
  List<String> get unusedKeys => conf.ignoredDirectives;

  @override
  List<ProfileNotice> get notices {
    final items = <ProfileNotice>[];
    if (conf.usesStaticKey) {
      // 放在最前，因为这一条决定了「能不能连上」。
      items.add(
        ProfileNotice.warn(
          '这是静态密钥模式（secret）的配置。本客户端只实现 TLS 模式，'
          '这份配置无法建立连接',
        ),
      );
    }
    if (conf.verifyX509Name != null) {
      // 不写成 warn：连接本身不受影响，受影响的是「用户以为钉死了服务端身份，
      // 而实际只校验收到了服务端证书」。这类「以为有、其实没有」的保护必须说
      // 出来，否则用户会基于一个不存在的保证做判断。
      items.add(
        ProfileNotice.info(
          '配置要求校验服务端证书名（verify-x509-name ${conf.verifyX509Name}）。'
          '本客户端只校验「是服务端证书」，不比对名字',
        ),
      );
    }
    if (conf.remoteCount > 1) {
      items.add(
        ProfileNotice.info(
          '配置含 ${conf.remoteCount} 个 remote，仅使用第一个'
          '（$serverDisplay）',
        ),
      );
    }
    final impact = conf.ignoredDirectives
        .where(OpenVpnConf.impactfulIgnoredDirectives.contains)
        .toList(growable: false);
    if (impact.isNotEmpty) {
      items.add(
        ProfileNotice.info(
          '以下指令未生效：${impact.join('、')}（本客户端不支持）',
        ),
      );
    }
    if (conf.network == 'udp' &&
        conf.pingInterval == null &&
        conf.pingRestart == null &&
        !conf.pingRestartDisabled) {
      items.add(
        const ProfileNotice.info(
          '未声明 ping/keepalive。UDP 模式下 NAT 映射可能超时，'
          '可按服务端建议添加 keepalive',
        ),
      );
    }
    return items;
  }
}
