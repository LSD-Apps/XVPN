// 从 sing-box 反编译出的 geoip-cn JSON 生成「中国 IP 前缀索引」。
//
// 为什么需要这份资产，又为什么在构建期生成：
//
//   * 智能化分流要做 **DNS 交叉校验**——同一个域名分别用直连解析器与隧道内
//     解析器解析，比较两组地址。要判断「这组地址是否属于目标规则集」，就需要
//     一份对应的 IP 段表；否则只能看出「两组答案不一样」，无法区分
//     「CDN 就近解析」和「解析结果不可信」。
//   * geoip-cn.srs 是 zlib 压缩的私有二进制格式，而 Dart 标准库没有 inflate。
//     为了不引入依赖，也不在运行时做无谓的解析，这里在构建期把它摊平成
//     一张紧凑的、可直接二分查找的表。
//
// 用法（依赖随包分发的 sing-box.exe 做反编译）：
//
//   sing-box rule-set decompile assets/rulesets/geoip-cn.srs -o geoip-cn.json
//   dart run tool/build_cn_ip_index.dart geoip-cn.json assets/rulesets/cn-ip.bin
//
// 输出格式（小端）：
//
//   offset  size  内容
//   0       4     magic "CIP1"
//   4       4     条目数 N
//   8       4×N   条目，每条 8 字节：uint32 网络地址 + uint8 掩码 + 3 字节保留
//
// 条目按网络地址升序排列。查找时二分即可；因为同一地址上最多只有一个条目
// （生成阶段已经去掉了被更短前缀覆盖的冗余条目），所以不需要处理重叠。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      '用法: dart run tool/build_cn_ip_index.dart <geoip-cn.json> <out.bin>',
    );
    exitCode = 2;
    return;
  }

  final source = File(args[0]);
  if (!source.existsSync()) {
    stderr.writeln('找不到输入文件：${source.path}');
    exitCode = 2;
    return;
  }

  final decoded = jsonDecode(source.readAsStringSync());
  if (decoded is! Map) {
    stderr.writeln('输入不是 sing-box 规则集 JSON');
    exitCode = 2;
    return;
  }

  final rawCidrs = <String>[];
  final rules = decoded['rules'];
  if (rules is List) {
    for (final rule in rules) {
      if (rule is! Map) continue;
      final list = rule['ip_cidr'];
      if (list is! List) continue;
      for (final item in list) {
        if (item is String) rawCidrs.add(item);
      }
    }
  }
  if (rawCidrs.isEmpty) {
    stderr.writeln('JSON 里没有任何 ip_cidr 条目');
    exitCode = 2;
    return;
  }

  final parsed = <_Cidr>[];
  var skippedIpv6 = 0;
  var skippedInvalid = 0;
  for (final raw in rawCidrs) {
    final cidr = _Cidr.tryParse(raw);
    if (cidr == null) {
      skippedInvalid++;
    } else if (cidr.isIpv6) {
      skippedIpv6++;
    } else {
      parsed.add(cidr);
    }
  }

  // 按掩码从短到长排序，再用「区间是否已被覆盖」去掉冗余条目。
  //
  // 这一步不是锦上添花：geoip-cn 里有大量 /22、/24 落在同一批 /16 之内，
  // 全部保留会让表膨胀一倍多，而查找结果完全一样。
  parsed.sort((_Cidr a, _Cidr b) {
    final byLength = a.prefixLength.compareTo(b.prefixLength);
    return byLength != 0 ? byLength : a.network.compareTo(b.network);
  });

  final minimal = <_Cidr>[];
  for (final cidr in parsed) {
    var covered = false;
    for (final kept in minimal) {
      if (kept.contains(cidr.network)) {
        covered = true;
        break;
      }
      // minimal 按网络地址无序，但 contains 会做边界判断，这里不做提前退出：
      // 条目数量在千级，暴力检查的代价远低于维护有序结构的复杂度。
    }
    if (!covered) minimal.add(cidr);
  }

  minimal.sort((_Cidr a, _Cidr b) => a.network.compareTo(b.network));

  final bytes = Uint8List(8 + minimal.length * 8);
  final view = ByteData.view(bytes.buffer);
  bytes[0] = 0x43; // C
  bytes[1] = 0x49; // I
  bytes[2] = 0x50; // P
  bytes[3] = 0x31; // 1
  view.setUint32(4, minimal.length, Endian.little);
  for (var i = 0; i < minimal.length; i++) {
    final base = 8 + i * 8;
    view.setUint32(base, minimal[i].network, Endian.little);
    bytes[base + 4] = minimal[i].prefixLength;
    // 后 3 字节保留，便于将来扩展（例如加国家码）而不改 magic。
  }

  final out = File(args[1]);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(bytes, flush: true);

  stdout.writeln('输入条目：${rawCidrs.length}');
  if (skippedIpv6 > 0) stdout.writeln('跳过 IPv6：$skippedIpv6');
  if (skippedInvalid > 0) stdout.writeln('跳过无法解析：$skippedInvalid');
  stdout.writeln('去冗余前：${parsed.length}');
  stdout.writeln('去冗余后：${minimal.length}');
  stdout.writeln('输出：${out.path}（${bytes.length} 字节，'
      '${(bytes.length / 1024).toStringAsFixed(1)} KB）');
}

class _Cidr {
  _Cidr(this.network, this.prefixLength, this.isIpv6);

  /// IPv4 时是 32 位网络地址；IPv6 未使用。
  final int network;
  final int prefixLength;
  final bool isIpv6;

  /// 广播/结束地址（含）。仅 IPv4。
  int get last {
    if (prefixLength == 0) return 0xFFFFFFFF;
    final mask = (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
    return (network | (~mask & 0xFFFFFFFF)) & 0xFFFFFFFF;
  }

  bool contains(int address) => address >= network && address <= last;

  static _Cidr? tryParse(String raw) {
    final slash = raw.indexOf('/');
    if (slash <= 0) return null;
    final hostPart = raw.substring(0, slash);
    final lengthPart = raw.substring(slash + 1);
    final length = int.tryParse(lengthPart);
    if (length == null) return null;
    if (hostPart.contains(':') || length > 32) {
      // IPv6 条目统一标记后由调用方统计；这里不解析其数值。
      return _Cidr(0, length, true);
    }
    final octets = hostPart.split('.');
    if (octets.length != 4) return null;
    var address = 0;
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) return null;
      address = (address << 8) | value;
    }
    if (length < 0) return null;
    final mask = length == 0 ? 0 : (0xFFFFFFFF << (32 - length)) & 0xFFFFFFFF;
    return _Cidr(address & mask, length, false);
  }
}
