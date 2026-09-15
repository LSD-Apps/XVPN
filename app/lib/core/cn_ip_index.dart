/// geoip-cn 前缀索引：判断一个地址是否落在规则集覆盖的网段内。
///
/// 智能化分流需要这个判断来做 **DNS 交叉校验**。举例说明为什么必须区分：
///
/// ```
/// 域名 A：直连 DNS 给出 192.0.2.173（索引内），隧道 DNS 给出 198.51.100.7（索引外）
///         → 两组答案地理上不同，说明域名有两套部署，直连与代理都"通"。
/// 域名 B：直连 DNS 给出 127.0.0.1（答案不可信），隧道 DNS 给出 198.51.100.8
///         → 直连注定失败，必须强制走隧道。
/// ```
///
/// 只看「两组答案是否相同」无法区分这两种情况，因为它们都不相同；
/// 加上「直连那组是不是真的在索引内」才能定性。
///
/// 数据来自构建期生成的 `assets/rulesets/cn-ip.bin`。CIP1 只有 IPv4；CIP2
/// 在其后追加 IPv6 段——geoip-cn.srs 里本来就有两千多条 IPv6，旧生成器把它们
/// 丢掉了，纯 IPv6 答案因此永远是「无法判断」。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// 只读的中国 IP 前缀表。
class CnIpIndex {
  CnIpIndex._(
    this._addresses,
    this._prefixLengths, [
    this._v6Networks = const <int>[],
    this._v6PrefixLengths = const <int>[],
  ]);

  /// 升序排列的 IPv4 网络地址。
  final Uint32List _addresses;
  final Uint8List _prefixLengths;

  /// IPv6：每条 16 字节网络地址，按字节序升序。
  /// 展平存放：index i 的地址是 [_v6Networks] 的 `[i*16, i*16+16)`。
  final List<int> _v6Networks;
  final List<int> _v6PrefixLengths;

  static const String assetPath = 'assets/rulesets/cn-ip.bin';
  static const String originAssetPath = 'assets/rulesets/cn-ip.origin.json';

  static const List<int> _magicV1 = <int>[0x43, 0x49, 0x50, 0x31]; // CIP1
  static const List<int> _magicV2 = <int>[0x43, 0x49, 0x50, 0x32]; // CIP2

  int get length => _addresses.length + ipv6Length;

  int get ipv4Length => _addresses.length;

  int get ipv6Length => _v6PrefixLengths.length;

  bool get isEmpty => length == 0;

  bool get hasIpv6 => ipv6Length > 0;

  static final CnIpIndex empty = CnIpIndex._(Uint32List(0), Uint8List(0));

  static bool _magicIs(Uint8List bytes, List<int> magic) {
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  /// 从字节流解析。格式不对时返回 null。
  static CnIpIndex? parse(Uint8List bytes) {
    if (bytes.length < 8) return null;
    if (_magicIs(bytes, _magicV1)) return _parseV4Table(bytes, version2: false);
    if (_magicIs(bytes, _magicV2)) return _parseV4Table(bytes, version2: true);
    return null;
  }

  static CnIpIndex? _parseV4Table(Uint8List bytes, {required bool version2}) {
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final v4Count = view.getUint32(4, Endian.little);
    final v4Bytes = v4Count * 8;
    if (v4Count == 0 || 8 + v4Bytes > bytes.length) return null;
    final addresses = Uint32List(v4Count);
    final lengths = Uint8List(v4Count);
    for (var i = 0; i < v4Count; i++) {
      final base = 8 + i * 8;
      addresses[i] = view.getUint32(base, Endian.little);
      lengths[i] = bytes[base + 4];
    }
    if (!version2) {
      return CnIpIndex._(addresses, lengths);
    }
    final v6Header = 8 + v4Bytes;
    if (v6Header + 4 > bytes.length) return null;
    final v6Count = view.getUint32(v6Header, Endian.little);
    final v6Bytes = v6Count * 20;
    if (v6Header + 4 + v6Bytes > bytes.length) return null;
    final v6Networks = List<int>.filled(v6Count * 16, 0);
    final v6Lengths = List<int>.filled(v6Count, 0);
    for (var i = 0; i < v6Count; i++) {
      final base = v6Header + 4 + i * 20;
      for (var b = 0; b < 16; b++) {
        v6Networks[i * 16 + b] = bytes[base + b];
      }
      v6Lengths[i] = bytes[base + 16];
    }
    return CnIpIndex._(addresses, lengths, v6Networks, v6Lengths);
  }

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

  bool contains(String address) {
    if (isEmpty) return false;
    final v4 = parseIpv4(address);
    if (v4 != null) return _containsV4(v4);
    final v6 = parseIpv6(address);
    if (v6 != null) return _containsV6(v6);
    return false;
  }

  bool _containsV4(int parsed) {
    if (_addresses.isEmpty) return false;
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
    return _containsV4At(candidate, parsed);
  }

  bool _containsV4At(int index, int address) {
    final network = _addresses[index];
    final length = _prefixLengths[index];
    if (length <= 0) return true;
    final mask = length >= 32
        ? 0xFFFFFFFF
        : ((0xFFFFFFFF << (32 - length)) & 0xFFFFFFFF);
    return (address & mask) == network;
  }

  bool _containsV6(Uint8List addr) {
    final count = ipv6Length;
    if (count == 0) return false;
    var low = 0;
    var high = count - 1;
    var candidate = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_v6Compare(mid, addr) <= 0) {
        candidate = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (candidate < 0) return false;
    return _v6PrefixContains(candidate, addr);
  }

  int _v6Compare(int index, Uint8List addr) {
    final base = index * 16;
    for (var i = 0; i < 16; i++) {
      final d = _v6Networks[base + i] - addr[i];
      if (d != 0) return d;
    }
    return 0;
  }

  bool _v6PrefixContains(int index, Uint8List addr) {
    final length = _v6PrefixLengths[index];
    if (length <= 0) return true;
    final base = index * 16;
    var bits = length;
    var i = 0;
    while (bits >= 8) {
      if (_v6Networks[base + i] != addr[i]) return false;
      i++;
      bits -= 8;
    }
    if (bits == 0) return true;
    final mask = (0xFF << (8 - bits)) & 0xFF;
    return (_v6Networks[base + i] & mask) == (addr[i] & mask);
  }

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

  /// 把文本形式的 IPv6 解析成 16 字节。不认识的写法返回 null。
  static Uint8List? parseIpv6(String address) {
    var s = address.trim();
    if (s.startsWith('[') && s.endsWith(']')) {
      s = s.substring(1, s.length - 1);
    }
    final zone = s.indexOf('%');
    if (zone != -1) s = s.substring(0, zone);
    if (s.isEmpty || !s.contains(':')) return null;

    Uint8List? v4Tail;
    if (s.contains('.')) {
      final lastColon = s.lastIndexOf(':');
      if (lastColon < 0) return null;
      final v4 = parseIpv4(s.substring(lastColon + 1));
      if (v4 == null) return null;
      v4Tail = Uint8List(4);
      v4Tail[0] = (v4 >> 24) & 0xFF;
      v4Tail[1] = (v4 >> 16) & 0xFF;
      v4Tail[2] = (v4 >> 8) & 0xFF;
      v4Tail[3] = v4 & 0xFF;
      s = s.substring(0, lastColon);
    }

    final doubleColon = s.indexOf('::');
    if (doubleColon != -1 && s.indexOf('::', doubleColon + 2) != -1) {
      return null;
    }

    List<int>? parseParts(String raw) {
      if (raw.isEmpty) return <int>[];
      final out = <int>[];
      for (final part in raw.split(':')) {
        if (part.isEmpty) return null;
        final value = int.tryParse(part, radix: 16);
        if (value == null || value < 0 || value > 0xFFFF) return null;
        out.add(value);
      }
      return out;
    }

    late final List<int> parts;
    if (doubleColon != -1) {
      final left = parseParts(s.substring(0, doubleColon));
      final right = parseParts(s.substring(doubleColon + 2));
      if (left == null || right == null) return null;
      final needed = 8 - (v4Tail == null ? 0 : 2);
      if (left.length + right.length > needed) return null;
      parts = <int>[
        ...left,
        ...List<int>.filled(needed - left.length - right.length, 0),
        ...right,
      ];
    } else {
      final parsed = parseParts(s);
      if (parsed == null) return null;
      parts = parsed;
      final needed = 8 - (v4Tail == null ? 0 : 2);
      if (parts.length != needed) return null;
    }

    final out = Uint8List(16);
    for (var i = 0; i < parts.length; i++) {
      out[i * 2] = (parts[i] >> 8) & 0xFF;
      out[i * 2 + 1] = parts[i] & 0xFF;
    }
    if (v4Tail != null) {
      out[12] = v4Tail[0];
      out[13] = v4Tail[1];
      out[14] = v4Tail[2];
      out[15] = v4Tail[3];
    }
    return out;
  }
}

enum AddressRegion {
  domestic,
  overseas,
  unknown,
}

/// 判断一组地址的地理归属。
///
/// 只要有一个落在索引内就按索引内处理。全是 IPv6 而索引没有 IPv6 段时保持
/// [AddressRegion.unknown]——那是旧 CIP1 的盲区，不能当成境外。
AddressRegion classifyRegion(CnIpIndex index, List<String> addresses) {
  if (addresses.isEmpty) return AddressRegion.unknown;
  if (index.isEmpty) return AddressRegion.unknown;
  var anyClassifiable = false;
  for (final address in addresses) {
    final v4 = CnIpIndex.parseIpv4(address) != null;
    final v6 = !v4 && CnIpIndex.parseIpv6(address) != null;
    if (!v4 && !v6) continue;
    if (v6 && !index.hasIpv6) continue;
    anyClassifiable = true;
    if (index.contains(address)) return AddressRegion.domestic;
  }
  return anyClassifiable ? AddressRegion.overseas : AddressRegion.unknown;
}
