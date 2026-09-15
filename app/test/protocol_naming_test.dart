import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';
import 'package:xvpn/screens/config_form.dart';

/// 锁定 `vpn_protocol.dart` 开头那条承诺：**新增协议时界面不需要改动**。
///
/// 这条承诺很容易在不知不觉中破掉——只要有人在界面里再手打一遍协议名。此前就有
/// 两处：连接页那句「支持 …」的清单，以及 [ConfigFormModel.defaultName] 里逐个
/// 协议写死的 switch 分支。它们的表现不是崩溃，而是**界面少说或多说**：
///   * 新增协议后文案没跟上，用户据此以为它不支持；
///   * 改协议展示名后，某一条分支还留着旧写法（`Hysteria2` 与 `Hysteria 2`
///     就是这么分叉的，而 `defaultName` 里还专门留了一条分支把空格盖回去）。
///
/// 因此在 `label` 之外再补一层断言：任何要写协议名的地方都得从它派生。
void main() {
  test('每个协议都有非空且互不相同的展示名', () {
    final labels = <String>[];
    for (final protocol in VpnProtocol.values) {
      final label = protocol.label;
      expect(label.trim(), isNotEmpty, reason: '${protocol.name} 的展示名为空');
      labels.add(label);
    }
    expect(
      labels.toSet().length,
      labels.length,
      reason: '两个协议共用一个展示名，用户在界面上分不出它们',
    );
  });

  test('「支持 …」清单覆盖全部可导入协议', () {
    final text = supportedProtocolsText;
    expect(text.trim(), isNotEmpty);
    for (final protocol in importableProtocols) {
      expect(
        text,
        contains(protocol.label),
        reason: '界面文案漏了 ${protocol.label}——用户会以为这个协议不支持',
      );
    }
  });

  test('手填配置的默认名只由 label 派生', () {
    for (final protocol in VpnProtocol.values) {
      expect(
        ConfigFormModel.defaultName(protocol),
        '${protocol.label} 配置',
        reason: '默认名必须由 label 派生，否则改展示名时这里会留下旧写法',
      );
    }
  });
}
