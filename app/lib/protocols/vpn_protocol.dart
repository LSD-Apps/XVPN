/// 支持的 VPN 协议。
///
/// 新协议接入的完整步骤（三步，互不影响）：
///   1. 在这里加一个枚举值，并在扩展里补上展示信息与文件扩展名；
///   2. 新建 `<协议>_adapter.dart` 实现 [VpnProtocolAdapter]（解析 + 生成内核片段）；
///   3. 把适配器注册进 `VpnProtocolFactory.adapters`。
/// 界面、导入流程、配置生成都不需要改动——它们只认这里定义的抽象。
library;

enum VpnProtocol {
  wireGuard,
  openVpn,

  // 以下为规划中的协议。sing-box 原生支持它们，接入成本主要在于
  // 「把各家客户端导出的配置解析成统一字段」这一步。
  shadowsocks,
  vmess,
  vless,
  trojan,
  hysteria2,
}

extension VpnProtocolInfo on VpnProtocol {
  /// 界面展示名。
  String get label => switch (this) {
        VpnProtocol.wireGuard => 'WireGuard',
        VpnProtocol.openVpn => 'OpenVPN',
        VpnProtocol.shadowsocks => 'Shadowsocks',
        VpnProtocol.vmess => 'VMess',
        VpnProtocol.vless => 'VLESS',
        VpnProtocol.trojan => 'Trojan',
        VpnProtocol.hysteria2 => 'Hysteria 2',
      };

  /// 可接受的文件扩展名（小写，不含点）。
  List<String> get fileExtensions => switch (this) {
        VpnProtocol.wireGuard => <String>['conf'],
        VpnProtocol.openVpn => <String>['ovpn', 'conf'],
        VpnProtocol.shadowsocks => <String>['json', 'txt'],
        VpnProtocol.vmess => <String>['json'],
        VpnProtocol.vless => <String>['json'],
        VpnProtocol.trojan => <String>['json', 'yaml', 'yml'],
        VpnProtocol.hysteria2 => <String>['json', 'yaml', 'yml'],
      };

  /// 是否已实现导入。未实现的协议在界面上不提供入口，避免给出无法兑现的承诺。
  bool get isImportable => switch (this) {
        VpnProtocol.wireGuard || VpnProtocol.openVpn => true,
        _ => false,
      };

  /// 该协议是否需要用户名/密码，导入时需要额外向用户索取。
  bool get needsCredentials => switch (this) {
        VpnProtocol.openVpn ||
        VpnProtocol.shadowsocks ||
        VpnProtocol.trojan ||
        VpnProtocol.hysteria2 =>
          true,
        _ => false,
      };
}

/// 已实现导入的协议。
List<VpnProtocol> get importableProtocols =>
    VpnProtocol.values.where((p) => p.isImportable).toList(growable: false);

/// 规划中的协议。
List<VpnProtocol> get plannedProtocols =>
    VpnProtocol.values.where((p) => !p.isImportable).toList(growable: false);

/// 所有可被识别的扩展名，用于文件选择器过滤。
List<String> get allSupportedExtensions {
  final set = <String>{};
  for (final p in importableProtocols) {
    set.addAll(p.fileExtensions);
  }
  return set.toList(growable: false);
}
