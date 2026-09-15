/// 当前节点服务器落在不落在国内网段。
///
/// RULES「订阅与规则联动」要的不是另写一套分流，而是：选中某个节点时，
/// 让界面说清这条隧道本身在哪。智能分流仍然是「国内目标直连、其余进隧道」；
/// 若节点自己就在国内网段，境外流量等于绕进一台国内机器，用户应当看见。
library;

import 'cn_ip_index.dart';
import '../protocols/parsed_profile.dart';

/// 从 `host:port` / `[v6]:port` 里取出主机。
String? serverHostOf(String serverDisplay) {
  final raw = serverDisplay.trim();
  if (raw.isEmpty || raw == '—') return null;
  if (raw.startsWith('[')) {
    final close = raw.indexOf(']');
    if (close <= 1) return null;
    return raw.substring(1, close);
  }
  final colon = raw.lastIndexOf(':');
  if (colon <= 0) return raw;
  final port = raw.substring(colon + 1);
  if (int.tryParse(port) == null) return raw;
  return raw.substring(0, colon);
}

AddressRegion classifyNodeRegion(CnIpIndex index, ParsedProfile parsed) {
  final host = serverHostOf(parsed.serverDisplay);
  if (host == null) return AddressRegion.unknown;
  if (CnIpIndex.parseIpv4(host) != null || CnIpIndex.parseIpv6(host) != null) {
    return classifyRegion(index, <String>[host]);
  }
  // 主机名要等 DNS 才知道网段；连接前不能假装已经判定。
  return AddressRegion.unknown;
}

String nodeRegionLabel(AddressRegion region) => switch (region) {
      AddressRegion.domestic => '节点在国内网段',
      AddressRegion.overseas => '节点在境外网段',
      AddressRegion.unknown => '节点地区未判定',
    };

String? nodeRegionHint(AddressRegion region) {
  if (region != AddressRegion.domestic) return null;
  return '当前节点落在国内网段。智能分流仍把境外目标送进这条隧道——'
      '若这不是你想要的，换一个境外节点，或改用全局直连排障。';
}
