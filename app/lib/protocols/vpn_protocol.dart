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
  /// 界面展示名。**这是协议名字的唯一来源。**
  ///
  /// 「界面不用改」这条承诺一半靠抽象、一半靠这个 getter：任何地方要写协议名，
  /// 都得从这里取，而不是打一遍字。此前不是这样——手写的清单有三处，其中
  /// `Hysteria2` 一处写成 `Hysteria 2`（多一个空格）、`config_form.dart` 里
  /// 又专门为它留了一条 switch 分支去覆盖回来。名字散着写，就会长出这种
  /// 「一处一个写法、还有一条分支专门修另一处的笔误」的结构。
  String get label => switch (this) {
    VpnProtocol.wireGuard => 'WireGuard',
    VpnProtocol.openVpn => 'OpenVPN',
    VpnProtocol.shadowsocks => 'Shadowsocks',
    VpnProtocol.vmess => 'VMess',
    VpnProtocol.vless => 'VLESS',
    VpnProtocol.trojan => 'Trojan',
    // 不带空格：仓库里的文档、表单标题与界面文案一直写 `Hysteria2`，
    // 官方项目名 `Hysteria 2` 里的那个空格在中文语境下也常被省略。
    VpnProtocol.hysteria2 => 'Hysteria2',
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

/// 「支持 …」那句界面文案里的协议清单。
///
/// 从 [importableProtocols] 派生，而不是在界面里手写一遍。
///
/// `vpn_protocol.dart` 开头的文档明确承诺「新增协议时**界面不需要改动**」，而
/// 手写的清单正是这条承诺的反例：这一版加进 VMess / VLESS / Trojan / Shadowsocks
/// 时，就得同步去改两处界面文案——漏掉任何一处，界面就会少说一个已经支持的协议，
/// 而用户会据此以为它不支持。派生之后，新协议只加枚举值即可自动出现在这里。
String get supportedProtocolsText =>
    importableProtocols.map((p) => p.label).join('、');

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
