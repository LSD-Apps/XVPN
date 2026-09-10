// 开发者工具：校验一份配置文件能否被正确解析。
//
//   dart run tool/check_conf.dart <配置文件>
//
// 协议由 VpnProtocolFactory 按内容自动识别，因此 WireGuard 的 .conf 与
// OpenVPN 的 .ovpn 都能直接丢进来。
//
// 只输出非敏感字段：私钥、预共享密钥、内联证书一律不打印内容，
// 仅报告是否存在。用于在用户反馈「导入失败」时快速定位问题。
import 'dart:io';

import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/check_conf.dart <配置文件>');
    exit(2);
  }
  final path = args.first;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('文件不存在: $path');
    exit(2);
  }

  final text = file.readAsStringSync();
  stdout.writeln('文件    : $path  (${text.length} 字符)');
  stdout.writeln('支持格式: ${importableProtocols.map((p) => '${p.label}(${p.fileExtensions.map((e) => ".$e").join("/")})').join('、')}');

  final ParsedProfile parsed;
  try {
    parsed = VpnProtocolFactory.parse(text, path);
  } on VpnConfigException catch (e) {
    stdout.writeln('解析结果: 失败');
    stdout.writeln('原因    : ${e.message}');
    exit(1);
  }

  stdout.writeln('解析结果: 成功');
  stdout.writeln('识别协议: ${parsed.protocol.label}');
  stdout.writeln('服务器  : ${parsed.serverDisplay}');
  stdout.writeln('隧道地址: ${parsed.addressDisplay}');
  stdout.writeln('DNS     : ${parsed.dnsDisplay}');
  stdout.writeln('IPv6    : ${parsed.hasIpv6 ? "隧道具备 IPv6" : "无（DNS 将收紧为仅 IPv4）"}');
  stdout.writeln('需凭据  : ${parsed.requiresCredentials ? "是（auth-user-pass）" : "否"}');
  if (parsed.details.isNotEmpty) {
    stdout.writeln('补充信息:');
    for (final d in parsed.details) {
      stdout.writeln('  ${d.label}: ${d.value}');
    }
  }
  stdout.writeln('');
  stdout.writeln('结论: 该配置可用于建立隧道；路由与 DNS 将由内置规则库接管，');
  stdout.writeln('      文件里声明的 AllowedIPs / redirect-gateway 不会作为分流依据。');
}
