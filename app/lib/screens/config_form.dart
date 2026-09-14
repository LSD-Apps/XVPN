import 'package:flutter/material.dart';

import '../protocols/hysteria2_conf.dart';
import '../protocols/openvpn_conf.dart';
import '../protocols/parsed_profile.dart';
import '../protocols/protocol_adapter.dart';
import '../protocols/vpn_protocol.dart';
import '../protocols/wireguard_conf.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/profile_notices.dart';

/// 表单字段的测试标识。
///
/// 表单里的输入框都长一个样，按类型或顺序去找会在字段增减时立刻失效；
/// 挂一个稳定的 key 之后，测试断言的是「哪个业务字段收到了这个值」，
/// 而不是「第几个输入框」。
Key configFieldKey(String name) => ValueKey<String>('config-field-$name');

/// 用户确认表单后要交给 [AppState.importConf] 的全部内容。
typedef ConfigFormResult = ({
  String text,
  String name,
  String? username,
  String? password,
});

/// 配置表单模型。
///
/// 刻意做成纯数据、不依赖 Flutter：这样「解析 → 预填 → 生成规范文本 →
/// 再解析」的往返可以直接单元测试，不需要起界面，也不会因为某个控件改样式
/// 就把往返测试带崩。
///
/// 字段集刻意保留了解析器已经读出来的关键参数（OpenVPN 的 cipher / data-ciphers /
/// auth / remote-cert-tls）。原因是确认表单会用它**重新生成**配置文本：如果这里
/// 不保留，用户只是打开确认页再点「添加」，就会悄悄丢掉这些参数——而 sing-box
/// 对加密套件名是大小写敏感的，丢掉可能直接让内核起不来。
class ConfigFormModel {
  ConfigFormModel._({required this.protocol, required this.name});

  /// 手动填写用的空模型：只填入协议自己的默认值，其余留空等用户填。
  factory ConfigFormModel.empty(VpnProtocol protocol) {
    final model = ConfigFormModel._(protocol: protocol, name: '');
    switch (protocol) {
      case VpnProtocol.wireGuard:
        model
          ..allowedIps = '0.0.0.0/0, ::/0'
          ..endpointPort = '51820';
      case VpnProtocol.openVpn:
        // 端口刻意不预填：UDP 与 TCP 的默认端口不同（1194 / 443），
        // 预填一个固定值再让用户改传输协议，就会把错的端口留在表单里。
        // 留空时由 toConfText 按最终选择的传输协议给出默认值。
        model.transport = 'udp';
      case VpnProtocol.hysteria2:
        model.port = '443';
      default:
        break;
    }
    return model;
  }

  /// 从一份解析结果预填。[name] 通常是用户选中的文件名。
  factory ConfigFormModel.fromParsed(ParsedProfile profile, {String name = ''}) {
    final model = ConfigFormModel._(protocol: profile.protocol, name: name);
    switch (profile) {
      case WireGuardProfile():
        final conf = profile.conf;
        final peer = conf.primaryPeer;
        model
          ..privateKey = conf.privateKey
          ..address = conf.addresses.isEmpty ? null : conf.addresses.join(', ')
          ..dns = conf.dns.isEmpty ? null : conf.dns.join(', ')
          ..mtu = conf.mtu?.toString()
          ..peerPublicKey = peer?.publicKey
          ..presharedKey = peer?.presharedKey
          ..endpointHost = conf.endpointHost
          ..endpointPort = conf.endpointPort?.toString()
          ..allowedIps = (peer == null || peer.allowedIps.isEmpty)
              ? '0.0.0.0/0, ::/0'
              : peer.allowedIps.join(', ')
          ..persistentKeepalive = peer?.persistentKeepalive?.toString()
          ..notices = profile.notices;
      case OpenVpnProfile():
        final conf = profile.conf;
        model
          ..remoteHost = conf.remoteHost
          ..remotePort = conf.remotePort?.toString()
          ..transport = conf.network
          ..ca = conf.ca
          ..cert = conf.cert
          ..clientKey = conf.key
          ..tlsAuth = conf.tlsAuth
          ..tlsCrypt = conf.tlsCrypt
          ..keyDirection = conf.keyDirection?.toString()
          ..cipher = conf.cipher
          ..dataCiphers = conf.dataCiphers.isEmpty
              ? null
              : conf.dataCiphers.join(':')
          ..dataCiphersFallback = conf.dataCiphersFallback
          ..auth = conf.auth
          ..remoteCertTls = conf.requiresServerCert
          ..requiresCredentials = conf.requiresCredentials
          ..username = conf.username
          ..password = conf.password
          ..tunMtu = conf.tunMtu?.toString()
          ..pingInterval = conf.pingInterval?.toString()
          ..pingRestart = conf.pingRestartDisabled
              ? '0'
              : conf.pingRestart?.toString()
          ..mssFix = conf.mssFix?.toString()
          ..notices = profile.notices;
      case Hysteria2Profile():
        final conf = profile.conf;
        model
          ..server = conf.server
          ..port = conf.port.toString()
          ..hysteriaAuth = conf.auth
          ..sni = conf.sni
          ..insecure = conf.insecure
          ..obfsPassword = conf.obfsPassword
          ..upMbps = conf.upMbps?.toString()
          ..downMbps = conf.downMbps?.toString()
          ..portHopping = conf.serverPorts.isEmpty
              ? null
              : conf.serverPorts.join(', ')
          ..hopInterval = conf.hopIntervalSeconds?.toString()
          ..pinSha256 = conf.pinSha256
          ..displayName = conf.displayName
          ..notices = profile.notices;
      default:
        break;
    }
    return model;
  }

  VpnProtocol protocol;
  String name;

  // ------------------------------------------------------------- WireGuard
  String? privateKey;
  String? address;
  String? dns;
  String? mtu;
  String? peerPublicKey;
  String? presharedKey;
  String? endpointHost;
  String? endpointPort;
  String? allowedIps;
  String? persistentKeepalive;

  // --------------------------------------------------------------- OpenVPN
  String? remoteHost;
  String? remotePort;
  String? transport;
  String? ca;
  String? cert;
  String? clientKey;
  String? tlsAuth;
  String? tlsCrypt;
  String? keyDirection;
  String? cipher;
  String? dataCiphers;
  String? dataCiphersFallback;
  String? auth;
  String? username;
  String? password;
  bool remoteCertTls = false;
  bool requiresCredentials = false;
  String? tunMtu;
  String? pingInterval;
  String? pingRestart;
  String? mssFix;

  // ------------------------------------------------------------- Hysteria2
  String? server;
  String? port;
  String? hysteriaAuth;
  String? sni;
  bool insecure = false;
  String? obfsPassword;
  String? upMbps;
  String? downMbps;
  String? portHopping;
  String? hopInterval;
  String? pinSha256;
  String? displayName;

  /// 从已解析配置预填时附带的提示（例如 Amnezia 字段、缺带宽）。
  ///
  /// 不参与 toConfText；仅供确认导入对话框展示。
  List<ProfileNotice> notices = const <ProfileNotice>[];

  /// 手填模式下的默认名称。
  static String defaultName(VpnProtocol protocol) => switch (protocol) {
    VpnProtocol.wireGuard => 'WireGuard 配置',
    VpnProtocol.openVpn => 'OpenVPN 配置',
    VpnProtocol.hysteria2 => 'Hysteria2 配置',
    _ => '${protocol.label} 配置',
  };

  /// 生成规范配置文本。
  ///
  /// 生成的是各协议**客户端本身也认**的格式（wg-quick .conf / .ovpn /
  /// hysteria2:// 链接），因此解析路径只有一条，不会为「表单填的」和
  /// 「文件里读的」各维护一套。
  ///
  /// 必填项缺失时抛出 [VpnConfigException]，消息与解析器保持同一套口吻，
  /// 界面拿到的错误来自同一个来源。
  String toConfText() => switch (protocol) {
    VpnProtocol.wireGuard => _wireGuardText(),
    VpnProtocol.openVpn => _openVpnText(),
    VpnProtocol.hysteria2 => _hysteria2Text(),
    _ => throw VpnConfigException('暂不支持编辑 ${protocol.label} 配置'),
  };

  /// OpenVPN 的账号密码。
  ///
  /// 只有用户名与密码**都**填了才返回：只填一个就把它当成凭据发下去，
  /// [AppState] 会认为「已有凭据」，连接时会拿着半份凭据失败，
  /// 而用户看到的却是「不需要再填」。返回 null 时导入后仍会弹补填表单。
  ({String username, String password})? toCredentialPair() {
    if (protocol != VpnProtocol.openVpn) return null;
    final user = username?.trim() ?? '';
    final pass = password ?? '';
    if (user.isEmpty || pass.isEmpty) return null;
    return (username: user, password: pass);
  }

  // ------------------------------------------------------------ 生成：WG

  String _wireGuardText() {
    final key = _clean(privateKey);
    if (key == null) {
      throw VpnConfigException('缺少 [Interface] PrivateKey，这不是一个完整的 WireGuard 配置');
    }
    final addr = _csv(address);
    if (addr.isEmpty) {
      throw VpnConfigException('缺少 [Interface] Address，无法确定隧道地址');
    }
    final publicKey = _clean(peerPublicKey);
    if (publicKey == null) {
      throw VpnConfigException('缺少 [Peer] PublicKey');
    }
    final host = _clean(endpointHost);
    if (host == null) {
      throw VpnConfigException('缺少 [Peer] Endpoint，无法定位服务器');
    }
    final port = _requirePort(endpointPort, fallback: 51820);
    final allowed = _csv(allowedIps);

    final buffer = StringBuffer()
      ..writeln('[Interface]')
      ..writeln('PrivateKey = $key')
      ..writeln('Address = $addr');
    final dnsValue = _clean(dns);
    if (dnsValue != null) buffer.writeln('DNS = ${_csv(dnsValue)}');
    final mtuValue = _clean(mtu);
    if (mtuValue != null) buffer.writeln('MTU = $mtuValue');
    buffer
      ..writeln()
      ..writeln('[Peer]')
      ..writeln('PublicKey = $publicKey');
    final psk = _clean(presharedKey);
    if (psk != null) buffer.writeln('PresharedKey = $psk');
    buffer.writeln('Endpoint = ${_endpoint(host, port)}');
    buffer.writeln(
      'AllowedIPs = ${allowed.isEmpty ? '0.0.0.0/0, ::/0' : allowed}',
    );
    final keepalive = _clean(persistentKeepalive);
    if (keepalive != null) {
      final seconds = int.tryParse(keepalive);
      if (seconds == null || seconds < 0) {
        throw VpnConfigException('保活秒数无法解析：$keepalive');
      }
      if (seconds > 0) buffer.writeln('PersistentKeepalive = $seconds');
    }
    return buffer.toString().trim();
  }

  // ------------------------------------------------------- 生成：OpenVPN

  String _openVpnText() {
    final host = _clean(remoteHost);
    if (host == null) {
      throw VpnConfigException('缺少 remote 指令，无法定位 OpenVPN 服务器');
    }
    final proto = (_clean(transport) ?? 'udp').toLowerCase().startsWith('tcp')
        ? 'tcp'
        : 'udp';
    final port = _requirePort(remotePort, fallback: proto == 'tcp' ? 443 : 1194);

    final certText = _clean(cert);
    final keyText = _clean(clientKey);
    if (certText != null && keyText == null) {
      throw VpnConfigException('配置里有客户端证书 <cert>，但缺少对应的私钥 <key>');
    }
    if (keyText != null && certText == null) {
      throw VpnConfigException('配置里有客户端私钥 <key>，但缺少对应的证书 <cert>');
    }

    final buffer = StringBuffer()
      ..writeln('client')
      ..writeln('dev tun')
      ..writeln('proto $proto')
      ..writeln('remote $host $port');

    final cipherValue = _clean(cipher);
    if (cipherValue != null) buffer.writeln('cipher $cipherValue');
    final ciphers = _csvColon(dataCiphers);
    if (ciphers.isNotEmpty) buffer.writeln('data-ciphers $ciphers');
    final fallback = _clean(dataCiphersFallback);
    if (fallback != null) buffer.writeln('data-ciphers-fallback $fallback');
    final authValue = _clean(auth);
    if (authValue != null) buffer.writeln('auth ${authValue.toUpperCase()}');
    if (remoteCertTls) buffer.writeln('remote-cert-tls server');
    if (requiresCredentials) buffer.writeln('auth-user-pass');

    _writeInline(buffer, 'ca', ca);
    _writeInline(buffer, 'cert', certText);
    _writeInline(buffer, 'key', keyText);
    // tls-auth 与 tls-crypt 互斥：同时提供时以更强的 tls-crypt 为准。
    if (_clean(tlsCrypt) != null) {
      _writeInline(buffer, 'tls-crypt', tlsCrypt);
    } else {
      _writeInline(buffer, 'tls-auth', tlsAuth);
    }

    final direction = _clean(keyDirection);
    if (direction != null) {
      final n = int.tryParse(direction);
      if (n == null || (n != 0 && n != 1)) {
        throw VpnConfigException('key-direction 只能是 0 或 1，实际是「$direction」');
      }
      buffer.writeln('key-direction $n');
    }

    // tun-mtu / keepalive / mssfix：确认导入时不能把解析结果丢掉。
    final mtuValue = _clean(tunMtu);
    if (mtuValue != null) buffer.writeln('tun-mtu $mtuValue');
    final ping = _clean(pingInterval);
    final restart = _clean(pingRestart);
    if (ping != null && restart != null && restart != '0') {
      buffer.writeln('keepalive $ping $restart');
    } else {
      if (ping != null) buffer.writeln('ping $ping');
      if (restart != null) buffer.writeln('ping-restart $restart');
    }
    final mss = _clean(mssFix);
    if (mss != null) buffer.writeln('mssfix $mss');

    return buffer.toString().trim();
  }

  // ---------------------------------------------------- 生成：Hysteria2

  /// 生成 `hysteria2://` 分享链接。
  ///
  /// 选链接而不是 YAML，是因为它一份文本就能表达全部字段，且解析器已经
  /// 完整支持；YAML 那份的嵌套结构反而要在这里重新排版一遍。
  String _hysteria2Text() {
    final host = _clean(server);
    if (host == null) {
      throw VpnConfigException('缺少服务器地址（server）');
    }
    final port = _requirePort(this.port, fallback: 443);
    final authValue = _clean(hysteriaAuth);
    if (authValue == null) {
      throw VpnConfigException(
        '缺少认证凭据。Hysteria2 的服务端必须配置认证（密码或 用户:密码），'
        '请确认从面板复制的是完整链接',
      );
    }

    final params = <String, String>{};
    final sniValue = _clean(sni);
    if (sniValue != null) params['sni'] = sniValue;
    if (insecure) params['insecure'] = '1';
    final obfs = _clean(obfsPassword);
    if (obfs != null) {
      params['obfs'] = 'salamander';
      params['obfs-password'] = obfs;
    }
    final up = _clean(upMbps);
    if (up != null) params['up'] = up;
    final down = _clean(downMbps);
    if (down != null) params['down'] = down;
    final hopping = _csv(portHopping);
    if (hopping.isNotEmpty) {
      params['mport'] = hopping.replaceAll(', ', ',').replaceAll(': ', ':');
    }
    final interval = _clean(hopInterval);
    if (interval != null) params['hop-interval'] = interval;
    final pin = _clean(pinSha256);
    if (pin != null) params['pinSHA256'] = pin;

    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    final authority = '${Uri.encodeComponent(authValue)}@${_urlHost(host)}:$port';
    final remark = _clean(displayName);
    final fragment = remark == null ? '' : '#${Uri.encodeComponent(remark)}';
    return 'hysteria2://$authority/?$query$fragment';
  }

  // -------------------------------------------------------------- 小工具

  static String? _clean(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 把逗号 / 空白分隔的列表归一化成 `a, b`。
  ///
  /// 用户在表单里可能用换行或空格分隔，直接原样写进 `Address =` 会因为
  /// 混入换行而把一条指令拆成两行，解析随即失败。
  static String _csv(String? raw) => (raw ?? '')
      .split(RegExp(r'[,\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(', ');

  static String _csvColon(String? raw) => (raw ?? '')
      .split(RegExp(r'[:\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(':');

  static int _requirePort(String? raw, {required int fallback}) {
    final value = _clean(raw);
    if (value == null) return fallback;
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      throw VpnConfigException('端口 $value 超出 1–65535 的范围');
    }
    return port;
  }

  static String _endpoint(String host, int port) {
    final value = host.trim();
    final needsBrackets = value.contains(':') && !value.startsWith('[');
    return needsBrackets ? '[$value]:$port' : '$value:$port';
  }

  static String _urlHost(String host) {
    final value = host.trim();
    if (value.startsWith('[') || !value.contains(':')) return value;
    return '[$value]';
  }

  static void _writeInline(StringBuffer buffer, String tag, String? value) {
    final content = _clean(value);
    if (content == null) return;
    buffer
      ..writeln('<$tag>')
      ..writeln(content)
      ..writeln('</$tag>');
  }
}

/// 弹出配置表单（确认或手填）。返回 null 表示用户取消。
Future<ConfigFormResult?> showConfigForm(
  BuildContext context, {
  required ConfigFormModel model,
  required bool fromFile,
  required String storageNote,
}) {
  return showDialog<ConfigFormResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => _ConfigFormDialog(
      initial: model,
      fromFile: fromFile,
      storageNote: storageNote,
    ),
  );
}

class _ConfigFormDialog extends StatefulWidget {
  const _ConfigFormDialog({
    required this.initial,
    required this.fromFile,
    required this.storageNote,
  });

  final ConfigFormModel initial;

  /// 是否由「选择配置文件 / 拖拽 / 分享」进入。确认页与手填页的文案不同。
  final bool fromFile;

  /// 账号密码会怎么存，直接取自当前平台的 [AppState.protector] 说明。
  final String storageNote;

  @override
  State<_ConfigFormDialog> createState() => _ConfigFormDialogState();
}

class _ConfigFormDialogState extends State<_ConfigFormDialog> {
  /// 宽屏用居中卡片，窄屏用整屏表单。
  ///
  /// 阈值取 720：低于它时 620 的卡片两侧只剩很窄的空白，卡片反而比全屏更难用。
  static const double _wideBreakpoint = 720;

  late VpnProtocol _protocol = widget.initial.protocol;
  late final TextEditingController _name = TextEditingController(
    text: widget.initial.name,
  );
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  late String _transport =
      widget.initial.protocol == VpnProtocol.openVpn
      ? (widget.initial.transport ?? 'udp')
      : 'udp';
  late bool _insecure =
      widget.initial.protocol == VpnProtocol.hysteria2 &&
      widget.initial.insecure;
  late bool _remoteCertTls =
      widget.initial.protocol == VpnProtocol.openVpn &&
      widget.initial.remoteCertTls;
  late bool _requiresCredentials =
      widget.initial.protocol == VpnProtocol.openVpn &&
      widget.initial.requiresCredentials;

  String? _error;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _name.dispose();
    super.dispose();
  }

  /// 懒建控制器。首次访问时用初始模型 / 协议默认值预填。
  TextEditingController _ctl(String key) => _controllers.putIfAbsent(
    key,
    () => TextEditingController(text: _seed(key) ?? ''),
  );

  /// 某个字段的初始文本。
  ///
  /// 预填值优先取初始模型（从文件解析出来的那份），缺省时回落到该协议的
  /// 默认值——手填模式在协议之间来回切换时，新协议的默认值才会出现。
  /// 初始模型里只有一个协议的字段是有值的，所以 `??` 不会把预填值盖掉。
  String? _seed(String key) {
    final initial = widget.initial;
    final defaults = ConfigFormModel.empty(_protocol);
    return switch (key) {
      'wg.privateKey' => initial.privateKey,
      'wg.address' => initial.address,
      'wg.dns' => initial.dns,
      'wg.mtu' => initial.mtu,
      'wg.peerPublicKey' => initial.peerPublicKey,
      'wg.presharedKey' => initial.presharedKey,
      'wg.endpointHost' => initial.endpointHost,
      'wg.endpointPort' => initial.endpointPort ?? defaults.endpointPort,
      'wg.allowedIps' => initial.allowedIps ?? defaults.allowedIps,
      'wg.keepalive' => initial.persistentKeepalive,
      'ovpn.remoteHost' => initial.remoteHost,
      'ovpn.remotePort' => initial.remotePort ?? defaults.remotePort,
      'ovpn.username' => initial.username,
      'ovpn.password' => initial.password,
      'ovpn.ca' => initial.ca,
      'ovpn.cert' => initial.cert,
      'ovpn.key' => initial.clientKey,
      'ovpn.tlsAuth' => initial.tlsAuth,
      'ovpn.tlsCrypt' => initial.tlsCrypt,
      'ovpn.keyDirection' => initial.keyDirection,
      'ovpn.cipher' => initial.cipher,
      'ovpn.dataCiphers' => initial.dataCiphers,
      'ovpn.dataCiphersFallback' => initial.dataCiphersFallback,
      'ovpn.auth' => initial.auth,
      'ovpn.tunMtu' => initial.tunMtu,
      'ovpn.pingInterval' => initial.pingInterval,
      'ovpn.pingRestart' => initial.pingRestart,
      'ovpn.mssFix' => initial.mssFix,
      'hy2.server' => initial.server,
      'hy2.port' => initial.port ?? defaults.port,
      'hy2.auth' => initial.hysteriaAuth,
      'hy2.sni' => initial.sni,
      'hy2.obfsPassword' => initial.obfsPassword,
      'hy2.up' => initial.upMbps,
      'hy2.down' => initial.downMbps,
      'hy2.portHopping' => initial.portHopping,
      'hy2.hopInterval' => initial.hopInterval,
      'hy2.pin' => initial.pinSha256,
      'hy2.displayName' => initial.displayName,
      _ => null,
    };
  }

  String? _text(String key) {
    final value = _ctl(key).text.trim();
    return value.isEmpty ? null : value;
  }

  /// 与 [_text] 相同的非空判断，但保留原文（密码、多行证书的前后空白无所谓，
  /// 密码里的空格却可能是有意义的）。
  String? _rawText(String key) {
    final value = _ctl(key).text;
    return value.trim().isEmpty ? null : value;
  }

  ConfigFormModel _collect() {
    final trimmedName = _name.text.trim();
    final model = ConfigFormModel.empty(_protocol)
      ..name = trimmedName.isEmpty
          ? ConfigFormModel.defaultName(_protocol)
          : trimmedName;
    switch (_protocol) {
      case VpnProtocol.wireGuard:
        model
          ..privateKey = _text('wg.privateKey')
          ..address = _text('wg.address')
          ..dns = _text('wg.dns')
          ..mtu = _text('wg.mtu')
          ..peerPublicKey = _text('wg.peerPublicKey')
          ..presharedKey = _text('wg.presharedKey')
          ..endpointHost = _text('wg.endpointHost')
          ..endpointPort = _text('wg.endpointPort')
          ..allowedIps = _text('wg.allowedIps')
          ..persistentKeepalive = _text('wg.keepalive');
      case VpnProtocol.openVpn:
        model
          ..remoteHost = _text('ovpn.remoteHost')
          ..remotePort = _text('ovpn.remotePort')
          ..transport = _transport
          ..username = _text('ovpn.username')
          ..password = _rawText('ovpn.password')
          ..cipher = _text('ovpn.cipher')
          ..dataCiphers = _text('ovpn.dataCiphers')
          ..dataCiphersFallback = _text('ovpn.dataCiphersFallback')
          ..auth = _text('ovpn.auth')
          ..ca = _rawText('ovpn.ca')
          ..cert = _rawText('ovpn.cert')
          ..clientKey = _rawText('ovpn.key')
          ..tlsAuth = _rawText('ovpn.tlsAuth')
          ..tlsCrypt = _rawText('ovpn.tlsCrypt')
          ..keyDirection = _text('ovpn.keyDirection')
          ..remoteCertTls = _remoteCertTls
          ..requiresCredentials = _requiresCredentials
          ..tunMtu = _text('ovpn.tunMtu')
          ..pingInterval = _text('ovpn.pingInterval')
          ..pingRestart = _text('ovpn.pingRestart')
          ..mssFix = _text('ovpn.mssFix');
      case VpnProtocol.hysteria2:
        model
          ..server = _text('hy2.server')
          ..port = _text('hy2.port')
          ..hysteriaAuth = _rawText('hy2.auth')
          ..sni = _text('hy2.sni')
          ..insecure = _insecure
          ..obfsPassword = _rawText('hy2.obfsPassword')
          ..upMbps = _text('hy2.up')
          ..downMbps = _text('hy2.down')
          ..portHopping = _text('hy2.portHopping')
          ..hopInterval = _text('hy2.hopInterval')
          ..pinSha256 = _text('hy2.pin')
          ..displayName = _text('hy2.displayName');
      default:
        break;
    }
    return model;
  }

  void _switchProtocol(int index) {
    final next = importableProtocols[index];
    if (next == _protocol) return;
    setState(() {
      _protocol = next;
      _error = null;
      // 切到另一个协议时它的布尔开关还没有语义，重置成默认值。
      _insecure = false;
      _remoteCertTls = false;
      _requiresCredentials = false;
    });
  }

  void _submit() {
    final model = _collect();
    final ConfigFormResult result;
    try {
      final text = model.toConfText();
      final credentials = model.toCredentialPair();
      // 用同一条解析路径校验：错误文案与文件导入完全一致，
      // 也保证「表单能生成」等于「导入流程能解析」，不会出现只在界面上成立的配置。
      VpnProtocolFactory.parse(
        text,
        model.name,
        username: credentials?.username,
        password: credentials?.password,
      );
      result = (
        text: text,
        name: model.name,
        username: credentials?.username,
        password: credentials?.password,
      );
    } on VpnConfigException catch (e) {
      setState(() => _error = e.message);
      return;
    } on Object catch (e) {
      setState(() => _error = '无法生成配置：$e');
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final wide = media.width >= _wideBreakpoint;

    final fields = switch (_protocol) {
      VpnProtocol.wireGuard => _wireGuardFields(),
      VpnProtocol.openVpn => _openVpnFields(),
      VpnProtocol.hysteria2 => _hysteria2Fields(),
      _ => const <Widget>[],
    };

    final body = _body(fields);
    final content = Column(
      mainAxisSize: wide ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(),
        if (widget.initial.notices.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          ProfileNoticesView(
            notices: widget.initial.notices,
            layout: ProfileNoticesLayout.cards,
          ),
        ],
        const SizedBox(height: 14),
        if (widget.fromFile) ...<Widget>[
          _protocolTag(),
          const SizedBox(height: 12),
        ] else ...<Widget>[
          _protocolSelector(),
          const SizedBox(height: 14),
        ],
        if (wide)
          Flexible(fit: FlexFit.loose, child: body)
        else
          Expanded(child: body),
        const SizedBox(height: 12),
        if (_error != null) ...<Widget>[
          _errorBlock(_error!),
          const SizedBox(height: 12),
        ],
        _buttons(),
      ],
    );

    return Dialog(
      backgroundColor: XV.panel,
      // 窄屏整屏铺开：620 的卡片在手机上两侧留白太少，正文反而更窄。
      insetPadding: wide
          ? const EdgeInsets.symmetric(horizontal: 40, vertical: 40)
          : EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(wide ? XV.rCard : 0),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: content,
        ),
      ),
    );
  }

  Widget _header() {
    final title = widget.fromFile ? '确认并添加配置' : '手动添加配置';
    final fileName = widget.initial.name.trim();
    final subtitle = widget.fromFile
        ? '已从「${fileName.isEmpty ? '所选文件' : fileName}」读取解析结果。'
              '核对或修改后再添加，不会直接导入。'
        : '选择协议并填写服务器信息即可。分流规则与 DNS 策略已经内置，'
              '不需要填写路由表。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: XV.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: XvText.caption),
      ],
    );
  }

  Widget _protocolSelector() {
    final labels = importableProtocols
        .map((protocol) => protocol.label)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel('协议'),
        const SizedBox(height: 5),
        XvSegmented(
          labels: labels,
          index: importableProtocols.indexOf(_protocol),
          expand: true,
          onChanged: _switchProtocol,
        ),
      ],
    );
  }

  Widget _protocolTag() {
    return Row(
      children: <Widget>[
        _fieldLabel('协议'),
        const SizedBox(width: 10),
        Text(
          _protocol.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: XV.text,
          ),
        ),
      ],
    );
  }

  Widget _body(List<Widget> fields) {
    final children = <Widget>[
      _input('配置名称', _name, field: 'name', hint: '显示在配置列表里的名字'),
      ...fields,
    ];
    // 复用 [XvScrollableColumn] 而不是裸的 [SingleChildScrollView]：它内部已经
    // 给滚动内容右侧留出了滚动条的宽度。
    //
    // 桌面端 Flutter 的滚动条是**浮在内容之上**的（不占布局宽度），裸用
    // SingleChildScrollView 时，滚动条会正好压在字段右边缘上——手动添加配置
    // 有十几个字段，这一点在矮窗口里尤其明显。该 widget 的注释里记录了同一处
    // 现象与它的取值理由，这里不再重复一套。
    return XvScrollableColumn(
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 12),
          children[i],
        ],
      ],
    );
  }

  // --------------------------------------------------------- WireGuard 字段

  List<Widget> _wireGuardFields() => <Widget>[
    _section('服务器'),
    _input(
      '服务器地址',
      _ctl('wg.endpointHost'),
      field: 'wg.endpointHost',
      hint: 'vpn.example.com',
    ),
    _input(
      '服务器端口',
      _ctl('wg.endpointPort'),
      field: 'wg.endpointPort',
      hint: '51820',
      numeric: true,
    ),
    _section('隧道'),
    _input(
      '隧道地址',
      _ctl('wg.address'),
      field: 'wg.address',
      hint: '10.7.0.2/32, fd00::2/128',
      mono: true,
    ),
    _input('DNS（可选）', _ctl('wg.dns'), field: 'wg.dns', hint: '1.1.1.1'),
    _input(
      'MTU（可选）',
      _ctl('wg.mtu'),
      field: 'wg.mtu',
      hint: '1420',
      numeric: true,
    ),
    _section('密钥'),
    _input(
      '对端公钥 PublicKey',
      _ctl('wg.peerPublicKey'),
      field: 'wg.peerPublicKey',
      mono: true,
    ),
    _input(
      '客户端私钥 PrivateKey',
      _ctl('wg.privateKey'),
      field: 'wg.privateKey',
      secret: true,
      mono: true,
    ),
    _input(
      '预共享密钥 PresharedKey（可选）',
      _ctl('wg.presharedKey'),
      field: 'wg.presharedKey',
      secret: true,
      mono: true,
    ),
    _section('其它'),
    _input(
      '允许的 IP（可选）',
      _ctl('wg.allowedIps'),
      field: 'wg.allowedIps',
      hint: '0.0.0.0/0, ::/0',
      mono: true,
    ),
    _input(
      '保活秒数（可选）',
      _ctl('wg.keepalive'),
      field: 'wg.keepalive',
      hint: '25',
      numeric: true,
    ),
  ];

  // ----------------------------------------------------------- OpenVPN 字段

  List<Widget> _openVpnFields() => <Widget>[
    _section('服务器'),
    _input(
      '服务器地址',
      _ctl('ovpn.remoteHost'),
      field: 'ovpn.remoteHost',
      hint: 'vpn.example.com',
    ),
    _input(
      '服务器端口',
      _ctl('ovpn.remotePort'),
      field: 'ovpn.remotePort',
      hint: _transport == 'tcp' ? '443' : '1194',
      numeric: true,
    ),
    _transportSelector(),
    _section('账号密码（可选）'),
    _input('用户名', _ctl('ovpn.username'), field: 'ovpn.username'),
    _input(
      '密码',
      _ctl('ovpn.password'),
      field: 'ovpn.password',
      secret: true,
    ),
    _note('用户名与密码由服务端分配，不在配置文件里。不填也可以先添加，之后在「配置」页补填。'),
    _section('证书与加密（高级）'),
    _area(
      'CA 证书 <ca>',
      _ctl('ovpn.ca'),
      field: 'ovpn.ca',
      hint: '-----BEGIN CERTIFICATE-----',
    ),
    _area('客户端证书 <cert>', _ctl('ovpn.cert'), field: 'ovpn.cert'),
    _area('客户端私钥 <key>', _ctl('ovpn.key'), field: 'ovpn.key'),
    _area('tls-auth <tls-auth>（可选）', _ctl('ovpn.tlsAuth'), field: 'ovpn.tlsAuth'),
    _area(
      'tls-crypt <tls-crypt>（可选）',
      _ctl('ovpn.tlsCrypt'),
      field: 'ovpn.tlsCrypt',
    ),
    _input(
      'key-direction（可选）',
      _ctl('ovpn.keyDirection'),
      field: 'ovpn.keyDirection',
      hint: '0 或 1',
      numeric: true,
    ),
    _input(
      'cipher（可选）',
      _ctl('ovpn.cipher'),
      field: 'ovpn.cipher',
      hint: 'AES-256-CBC',
    ),
    _input(
      'data-ciphers（可选）',
      _ctl('ovpn.dataCiphers'),
      field: 'ovpn.dataCiphers',
      hint: 'AES-256-GCM:AES-128-GCM',
    ),
    _input(
      'data-ciphers-fallback（可选）',
      _ctl('ovpn.dataCiphersFallback'),
      field: 'ovpn.dataCiphersFallback',
      hint: 'AES-256-CBC',
    ),
    _input(
      'auth 摘要（可选）',
      _ctl('ovpn.auth'),
      field: 'ovpn.auth',
      hint: 'SHA256',
    ),
    _section('隧道参数（可选）'),
    _input(
      'tun-mtu（可选）',
      _ctl('ovpn.tunMtu'),
      field: 'ovpn.tunMtu',
      hint: '1500',
      numeric: true,
    ),
    _input(
      'ping / keepalive 间隔秒（可选）',
      _ctl('ovpn.pingInterval'),
      field: 'ovpn.pingInterval',
      hint: '10',
      numeric: true,
    ),
    _input(
      'ping-restart 秒（可选，0 = 禁用）',
      _ctl('ovpn.pingRestart'),
      field: 'ovpn.pingRestart',
      hint: '60',
      numeric: true,
    ),
    _input(
      'mssfix（可选）',
      _ctl('ovpn.mssFix'),
      field: 'ovpn.mssFix',
      hint: '1450',
      numeric: true,
    ),
    _toggle(
      '要求服务端证书（remote-cert-tls server）',
      _remoteCertTls,
      (value) => setState(() => _remoteCertTls = value),
    ),
    _toggle(
      '这份配置需要账号密码（auth-user-pass）',
      _requiresCredentials,
      (value) => setState(() => _requiresCredentials = value),
    ),
    _note(
      '账号密码将按「${widget.storageNote}」保存。'
      '证书留空表示这份配置不需要（例如用用户名密码认证的服务端）。',
    ),
  ];

  Widget _transportSelector() {
    final index = _transport.toLowerCase().startsWith('tcp') ? 1 : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fieldLabel('传输协议'),
        const SizedBox(height: 5),
        XvSegmented(
          labels: const <String>['UDP', 'TCP'],
          index: index,
          expand: true,
          onChanged: (i) => setState(() => _transport = i == 0 ? 'udp' : 'tcp'),
        ),
      ],
    );
  }

  // --------------------------------------------------------- Hysteria2 字段

  List<Widget> _hysteria2Fields() => <Widget>[
    _section('服务器'),
    _input(
      '服务器地址',
      _ctl('hy2.server'),
      field: 'hy2.server',
      hint: 'vpn.example.com',
    ),
    _input(
      '服务器端口',
      _ctl('hy2.port'),
      field: 'hy2.port',
      hint: '443',
      numeric: true,
    ),
    _input(
      '认证（密码 / 用户名:密码）',
      _ctl('hy2.auth'),
      field: 'hy2.auth',
      secret: true,
      mono: true,
    ),
    _input(
      'SNI（可选）',
      _ctl('hy2.sni'),
      field: 'hy2.sni',
      hint: 'vpn.example.com',
    ),
    _toggle(
      '跳过证书校验（insecure）',
      _insecure,
      (value) => setState(() => _insecure = value),
    ),
    _section('混淆与端口跳跃（可选）'),
    _input(
      'salamander 混淆密码',
      _ctl('hy2.obfsPassword'),
      field: 'hy2.obfsPassword',
      secret: true,
    ),
    _input(
      '端口跳跃区间',
      _ctl('hy2.portHopping'),
      field: 'hy2.portHopping',
      hint: '8443-9443',
      mono: true,
    ),
    _input(
      '端口跳跃间隔（秒）',
      _ctl('hy2.hopInterval'),
      field: 'hy2.hopInterval',
      hint: '30',
      numeric: true,
    ),
    _section('带宽与其它（可选）'),
    _input(
      '上行 Mbps',
      _ctl('hy2.up'),
      field: 'hy2.up',
      hint: '100',
      numeric: true,
    ),
    _input(
      '下行 Mbps',
      _ctl('hy2.down'),
      field: 'hy2.down',
      hint: '100',
      numeric: true,
    ),
    _input(
      '证书指纹 pinSHA256',
      _ctl('hy2.pin'),
      field: 'hy2.pin',
      mono: true,
    ),
    _input('备注名', _ctl('hy2.displayName'), field: 'hy2.displayName'),
  ];

  // ------------------------------------------------------------- 通用控件

  Widget _buttons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        XvButton(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 8),
        XvButton(
          label: '添加',
          kind: XvButtonKind.primary,
          onPressed: _submit,
        ),
      ],
    );
  }

  Widget _errorBlock(String message) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.error_outline, size: 14, color: XV.redSoft),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 11.5, color: XV.redSoft, height: 1.5),
          ),
        ),
      ],
    );
  }

  Widget _fieldLabel(String text) =>
      Text(text, style: TextStyle(fontSize: 11.5, color: XV.muted2));

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 2),
    child: Text(text, style: XvText.sectionLabel),
  );

  Widget _note(String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(Icons.info_outline, size: 13, color: XV.muted2),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: TextStyle(fontSize: 11, color: XV.muted2, height: 1.5),
        ),
      ),
    ],
  );

  Widget _input(
    String label,
    TextEditingController controller, {
    required String field,
    String? hint,
    bool secret = false,
    bool numeric = false,
    bool mono = false,
  }) {
    return _LabeledInput(
      label: label,
      field: field,
      controller: controller,
      hint: hint,
      secret: secret,
      numeric: numeric,
      mono: mono,
    );
  }

  Widget _area(
    String label,
    TextEditingController controller, {
    required String field,
    String? hint,
  }) {
    return _LabeledArea(
      label: label,
      field: field,
      controller: controller,
      hint: hint,
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: XV.muted, height: 1.5),
          ),
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: XvSwitch(value: value, onChanged: onChanged),
        ),
      ],
    );
  }
}

/// 单行输入框。描边与 [showCredentialDialog] 保持一致。
class _LabeledInput extends StatefulWidget {
  const _LabeledInput({
    required this.label,
    required this.field,
    required this.controller,
    this.hint,
    this.secret = false,
    this.numeric = false,
    this.mono = false,
  });

  final String label;
  final String field;
  final TextEditingController controller;
  final String? hint;
  final bool secret;
  final bool numeric;
  final bool mono;

  @override
  State<_LabeledInput> createState() => _LabeledInputState();
}

class _LabeledInputState extends State<_LabeledInput> {
  late bool _obscured = widget.secret;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.label,
          style: TextStyle(fontSize: 11.5, color: XV.muted2),
        ),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: XV.field,
            border: Border.all(color: XV.line),
            borderRadius: BorderRadius.circular(XV.rCtl),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: configFieldKey(widget.field),
                  controller: widget.controller,
                  obscureText: _obscured,
                  keyboardType: widget.numeric
                      ? TextInputType.number
                      : TextInputType.text,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: XV.text,
                    fontFamilyFallback: widget.mono
                        ? XV.monoFallback
                        : XV.cjkFallback,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    hintText: widget.hint,
                    hintStyle: TextStyle(
                      fontSize: 12.5,
                      color: XV.muted2,
                      fontFamilyFallback: XV.monoFallback,
                    ),
                  ),
                ),
              ),
              if (widget.secret)
                IconButton(
                  tooltip: _obscured ? '显示密码' : '隐藏密码',
                  icon: Icon(
                    _obscured
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                    color: XV.muted,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  visualDensity: VisualDensity.compact,
                  splashRadius: 18,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 多行文本框，用于内联 PEM 证书。
///
/// 证书以多行表单字段呈现，而不是提供一个把整份配置灌进来的捷径：那种捷径
/// 会把其余字段也一起糊进去，用户看不出表单里到底有什么、哪些值会被提交。
class _LabeledArea extends StatelessWidget {
  const _LabeledArea({
    required this.label,
    required this.field,
    required this.controller,
    this.hint,
  });

  final String label;
  final String field;
  final TextEditingController controller;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: TextStyle(fontSize: 11.5, color: XV.muted2)),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: XV.field,
            border: Border.all(color: XV.line),
            borderRadius: BorderRadius.circular(XV.rCtl),
          ),
          child: TextField(
            key: configFieldKey(field),
            controller: controller,
            minLines: 3,
            maxLines: 6,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: XV.text,
              fontFamilyFallback: XV.monoFallback,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 12,
                color: XV.muted2,
                fontFamilyFallback: XV.monoFallback,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
