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

  // 流式代理：片段进 outbounds。识别靠分享链接前缀 / JSON type，不靠扩展名。
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

  /// 约定的文件扩展名（小写，不含点）。
  ///
  /// **一个扩展名只归一个协议**。文件选择器的过滤列表与操作系统的文件关联都
  /// 取自这里，重复的扩展名会让「打开方式」指向另一套协议——用户双击一份配置，
  /// 得到的却是按别的协议解析出来的、看不懂的错误。因此 OpenVPN 让出 `.conf`，
  /// 只保留 `.ovpn`（OpenVPN 2.x 默认导出的正是 `.conf`，这是刻意的收紧）。
  ///
  /// 这是**声明的约定**，不是解析器的能力边界：协议判定始终按**内容**进行
  /// （见 [VpnProtocolAdapter.canParse]），扩展名不匹配的文件照样能导入。
  List<String> get fileExtensions => switch (this) {
    VpnProtocol.wireGuard => <String>['conf'],
    VpnProtocol.openVpn => <String>['ovpn'],
    VpnProtocol.shadowsocks => <String>['json', 'txt'],
    // 分享链接按内容识别，不独占扩展名：`.json` 已归 Shadowsocks 的约定，
    // `.yaml` 已归 Hysteria2。双击打开仍走内容判定。
    VpnProtocol.vmess => const <String>[],
    VpnProtocol.vless => const <String>[],
    VpnProtocol.trojan => const <String>[],
    // Hysteria2 约定用官方客户端配置的文件名（config.yaml）。分享链接与
    // sing-box JSON 出站解析器仍然接受（见 hysteria2_conf.dart），它们只是
    // 不作为**约定的文件名**对外宣传。
    VpnProtocol.hysteria2 => <String>['yaml', 'yml'],
  };

  /// 是否已实现导入。未实现的协议在界面上不提供入口，避免给出无法兑现的承诺。
  bool get isImportable => true;
}

/// 已实现导入的协议。
List<VpnProtocol> get importableProtocols =>
    VpnProtocol.values.where((p) => p.isImportable).toList(growable: false);

/// 所有可被识别的扩展名，用于文件选择器过滤。
///
/// 由各协议的 [VpnProtocolInfo.fileExtensions] 合并去重而来；上面已保证每个
/// 扩展名只属于一个协议，这里的去重只是兜底。
List<String> get allSupportedExtensions {
  final set = <String>{};
  for (final p in importableProtocols) {
    set.addAll(p.fileExtensions);
  }
  return set.toList(growable: false);
}
