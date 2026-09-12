/// 中国 IP 前缀索引：判断一个地址是否属于国内网段。
///
/// 智能化分流需要这个判断来做 **DNS 交叉校验**。举例说明为什么必须区分：
///
/// ```
/// 域名 A：国内 DNS 给出 192.0.2.173（国内），隧道 DNS 给出 198.51.100.7（境外）
///         → 两组答案地理上不同，说明域名有国内外两套部署，直连与代理都"通"。
/// 域名 B：国内 DNS 给出 127.0.0.1（被投毒），隧道 DNS 给出 198.51.100.8
///         → 直连注定失败，必须强制走隧道。
/// ```
///
/// 只看「两组答案是否相同」无法区分这两种情况，因为它们都不相同；
/// 加上「国内那组是不是真的在国内」才能定性。
///
/// 数据来自构建期生成的 `assets/rulesets/cn-ip.bin`，由
/// `tool/build_cn_ip_index.dart` 从 `geoip-cn.srs` 摊平而来
/// （见该文件的注释：Dart 标准库没有 zlib，无法在运行时解压 `.srs`）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// 只读的中国 IP 前缀表。
class CnIpIndex {
  CnIpIndex._(this._addresses, this._prefixLengths);

  /// 升序排列的网络地址。
  final Uint32List _addresses;

  /// 与 [_addresses] 一一对应的掩码长度。
  final Uint8List _prefixLengths;

  static const String assetPath = 'assets/rulesets/cn-ip.bin';

  static const List<int> _magic = <int>[0x43, 0x49, 0x50, 0x31]; // "CIP1"

  int get length => _addresses.length;

  bool get isEmpty => _addresses.isEmpty;

  /// 空表。加载失败时使用——此时所有判断都返回 false，
  /// 表现为「交叉校验拿不到结论」，而不是「把国内地址误判成境外」。
  static final CnIpIndex empty = CnIpIndex._(Uint32List(0), Uint8List(0));

  /// 从字节流解析。格式不对时返回 null。
  static CnIpIndex? parse(Uint8List bytes) {
    if (bytes.length < 8) return null;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final count = view.getUint32(4, Endian.little);
    if (count == 0 || 8 + count * 8 > bytes.length) return null;

    final addresses = Uint32List(count);
    final lengths = Uint8List(count);
    for (var i = 0; i < count; i++) {
      final base = 8 + i * 8;
      addresses[i] = view.getUint32(base, Endian.little);
      lengths[i] = bytes[base + 4];
    }
    return CnIpIndex._(addresses, lengths);
  }

  /// 生产环境加载：先试可执行文件旁边的资源目录（Windows），再试 Flutter 资源（Android）。
  ///
  /// 与规则库走同一套路径逻辑，因此不需要为这个文件单独维护一份分发配置。
  static Future<CnIpIndex> load({Directory? assetsDir}) async {
    final fromDisk = _loadFromDisk(assetsDir);
    if (fromDisk != null) return fromDisk;
    try {
      final data = await rootBundle.load(assetPath);
      return parse(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          ) ??
          empty;
    } on Object {
      return empty;
    }
  }

  static CnIpIndex? _loadFromDisk(Directory? assetsDir) {
    for (final dir in <Directory?>[assetsDir, _defaultAssetsDir()]) {
      if (dir == null) continue;
      try {
        final file = File('${dir.path}${Platform.pathSeparator}cn-ip.bin');
        if (!file.existsSync()) continue;
        final index = parse(file.readAsBytesSync());
        if (index != null) return index;
      } on Object {
        // 换下一个候选路径。
      }
    }
    return null;
  }

  static Directory? _defaultAssetsDir() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      return Directory(
        '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}'
        'flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}rulesets',
      );
    } on Object {
      return null;
    }
  }

  /// 地址是否落在国内网段内。
  ///
  /// 二分查找 + 邻近校验：表里同一起点上最多只有一个条目，但一个地址可能落在
  /// 「起点更靠前」的那一条里，所以命中前一条时要再验证一次上界。
  bool contains(String address) {
    if (_addresses.isEmpty) return false;
    final parsed = parseIpv4(address);
    if (parsed == null) return false;

    var low = 0;
    var high = _addresses.length - 1;
    var candidate = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_addresses[mid] <= parsed) {
        candidate = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (candidate < 0) return false;
    return _containsAt(candidate, parsed);
  }

  bool _containsAt(int index, int address) {
    final network = _addresses[index];
    final length = _prefixLengths[index];
    if (length <= 0) return true;
    // 用移位而不是乘法：掩码上限 32 位，Dart 的 int 是 64 位，不会溢出。
    final mask = length >= 32
        ? 0xFFFFFFFF
        : ((0xFFFFFFFF << (32 - length)) & 0xFFFFFFFF);
    return (address & mask) == network;
  }

  /// 把点分十进制解析成 32 位整数。非 IPv4 返回 null。
  ///
  /// 公开是为了让上层复用同一套解析规则（例如给界面格式化地址）。
  static int? parseIpv4(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('.');
    if (parts.length != 4) return null;
    var result = 0;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      result = (result << 8) | value;
    }
    return result;
  }
}

/// 地址的地理归属判定。
///
/// 之所以做成一个显式的三态而不是 `bool`：拿不到索引与「确定在境外」
/// 是两件不同的事，后者才能支撑「直连注定失败」这种结论。
enum AddressRegion {
  /// 属于国内网段。
  domestic,

  /// 确定不属于国内网段。
  overseas,

  /// 无法判断（索引缺失、地址不是 IPv4、解析失败）。
  unknown,
}

/// 判断一组地址的地理归属。
///
/// 只要有一个落在国内就按国内处理：国内站点的多线解析经常同时返回
/// 联通/电信/移动的多个国内地址，也有返回「国内 + 境外 CDN」的混合情况，
/// 后者按国内处理更符合「直连也许能通」的实际。
AddressRegion classifyRegion(CnIpIndex index, List<String> addresses) {
  if (addresses.isEmpty) return AddressRegion.unknown;
  if (index.isEmpty) return AddressRegion.unknown;
  var anyIpv4 = false;
  for (final address in addresses) {
    if (CnIpIndex.parseIpv4(address) == null) continue;
    anyIpv4 = true;
    if (index.contains(address)) return AddressRegion.domestic;
  }
  return anyIpv4 ? AddressRegion.overseas : AddressRegion.unknown;
}
