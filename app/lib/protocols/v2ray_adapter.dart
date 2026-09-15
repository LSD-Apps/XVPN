import 'parsed_profile.dart';
import 'protocol_adapter.dart';
import 'v2ray_conf.dart';
import 'vpn_protocol.dart';

/// VMess / VLESS / Trojan 共用适配器骨架。
///
/// 差异只在 [kind]：解析入口、出站 `type`、凭据字段都由 [V2RayConf] 处理。
abstract class V2RayAdapter implements VpnProtocolAdapter {
  V2RayKind get kind;

  @override
  VpnProtocol get protocol => kind.protocol;

  @override
  FragmentPlacement get placement => FragmentPlacement.outbound;

  @override
  bool canParse(String text, String fileName) => V2RayConf.looksLike(text, kind);

  @override
  ParsedProfile parse(
    String text,
    String fileName, {
    String? username,
    String? password,
  }) {
    return V2RayProfile(V2RayConf.parse(text, kind));
  }

  @override
  Map<String, Object?> buildEndpoint(
    ParsedProfile profile,
    OutboundContext context,
  ) {
    if (profile is! V2RayProfile || profile.conf.kind != kind) {
      throw VpnConfigException('内部错误：配置与协议不匹配');
    }
    return profile.conf.toOutbound(
      tag: context.tag,
      resolverTag: context.resolverTag,
    );
  }

  @override
  int tunMtu(ParsedProfile profile) => defaultTunMtu;

  static const int defaultTunMtu = 1500;
}

class VmessAdapter extends V2RayAdapter {
  @override
  V2RayKind get kind => V2RayKind.vmess;
}

class VlessAdapter extends V2RayAdapter {
  @override
  V2RayKind get kind => V2RayKind.vless;
}

class TrojanAdapter extends V2RayAdapter {
  @override
  V2RayKind get kind => V2RayKind.trojan;
}
