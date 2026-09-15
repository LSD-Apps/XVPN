// 从 sing-box 反编译出的 geoip JSON 生成「中国 IP 前缀索引」。
//
//   dart run tool/build_cn_ip_index.dart geoip-cn.json geoip-cn-extra.json
//       assets/rulesets/cn-ip.bin --srs ../assets/rulesets/geoip-cn.srs
//       ../assets/rulesets/geoip-cn-extra.srs
//
// 输出 CIP2：IPv4 段 + IPv6 段。旧 CIP1 只有 IPv4，生成器曾经把 srs 里的
// IPv6 前缀整表丢掉，纯 IPv6 的 DNS 答案因此无法做地理判定。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  final parsed = _parseArgs(args);
  if (parsed == null) {
    stderr.writeln(
      '用法: dart run tool/build_cn_ip_index.dart '
      '<输入.json> [更多.json ...] <out.bin> [--srs file.srs ...]',
    );
    exitCode = 2;
    return;
  }

  final rawCidrs = <String>[];
  for (final path in parsed.jsonPaths) {
    final source = File(path);
    if (!source.existsSync()) {
      stderr.writeln('找不到输入文件：${source.path}');
      exitCode = 2;
      return;
    }
    final before = rawCidrs.length;
    final decoded = jsonDecode(source.readAsStringSync());
    if (decoded is! Map) {
      stderr.writeln('输入不是 sing-box 规则集 JSON：${source.path}');
      exitCode = 2;
      return;
    }
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
    stdout.writeln('${source.path}：${rawCidrs.length - before} 条 ip_cidr');
  }
  if (rawCidrs.isEmpty) {
    stderr.writeln('所有输入里都没有任何 ip_cidr 条目');
    exitCode = 2;
    return;
  }

  final v4 = <_V4Cidr>[];
  final v6 = <_V6Cidr>[];
  var skippedInvalid = 0;
  for (final raw in rawCidrs) {
    final four = _V4Cidr.tryParse(raw);
    if (four != null) {
      v4.add(four);
      continue;
    }
    final six = _V6Cidr.tryParse(raw);
    if (six != null) {
      v6.add(six);
      continue;
    }
    skippedInvalid++;
  }

  final minimalV4 = _minimizeV4(v4);
  final minimalV6 = _minimizeV6(v6);

  final bytes = _encodeCip2(minimalV4, minimalV6);
  final out = File(parsed.outPath);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(bytes, flush: true);

  if (parsed.srsPaths.isNotEmpty) {
    final origin = <String, Object?>{
      'format': 'CIP2',
      'ipv4Count': minimalV4.length,
      'ipv6Count': minimalV6.length,
      'sources': <Object?>[
        for (final path in parsed.srsPaths) _sourceMeta(path),
      ],
    };
    final originFile = File(
      '${out.parent.path}${Platform.pathSeparator}cn-ip.origin.json',
    );
    originFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(origin));
    stdout.writeln('来源清单：${originFile.path}');
  }

  stdout.writeln('输入条目：${rawCidrs.length}');
  if (skippedInvalid > 0) stdout.writeln('跳过无法解析：$skippedInvalid');
  stdout.writeln('IPv4 去冗余后：${minimalV4.length}');
  stdout.writeln('IPv6 去冗余后：${minimalV6.length}');
  stdout.writeln('输出：${out.path}（${bytes.length} 字节，'
      '${(bytes.length / 1024).toStringAsFixed(1)} KB）');
}

({List<String> jsonPaths, String outPath, List<String> srsPaths})? _parseArgs(
  List<String> args,
) {
  if (args.length < 2) return null;
  final srsIndex = args.indexOf('--srs');
  final positional = srsIndex == -1 ? args : args.sublist(0, srsIndex);
  if (positional.length < 2) return null;
  final srsPaths = srsIndex == -1 ? const <String>[] : args.sublist(srsIndex + 1);
  return (
    jsonPaths: positional.sublist(0, positional.length - 1),
    outPath: positional.last,
    srsPaths: srsPaths,
  );
}

Map<String, Object?> _sourceMeta(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('找不到要记录哈希的规则集：$path');
  }
  final bytes = file.readAsBytesSync();
  return <String, Object?>{
    'file': file.uri.pathSegments.isEmpty
        ? file.path
        : file.uri.pathSegments.last,
    'size': bytes.length,
    'fnv1a': fnv1a64Hex(bytes),
  };
}

/// FNV-1a 64。用来发现「.srs 更新了但 cn-ip.bin 没刷新」，不是密码学。
int fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 0x100000001b3).toUnsigned(64);
  }
  return hash;
}

String fnv1a64Hex(List<int> bytes) {
  final n = fnv1a64(bytes);
  final hex = n.toRadixString(16);
  if (!hex.startsWith('-')) return hex.padLeft(16, '0');
  return (BigInt.from(n) + (BigInt.one << 64))
      .toRadixString(16)
      .padLeft(16, '0');
}

List<_V4Cidr> _minimizeV4(List<_V4Cidr> parsed) {
  parsed.sort((_V4Cidr a, _V4Cidr b) {
    final byLength = a.prefixLength.compareTo(b.prefixLength);
    return byLength != 0 ? byLength : a.network.compareTo(b.network);
  });
  final minimal = <_V4Cidr>[];
  for (final cidr in parsed) {
    var covered = false;
    for (final kept in minimal) {
      if (kept.contains(cidr.network)) {
        covered = true;
        break;
      }
    }
    if (!covered) minimal.add(cidr);
  }
  minimal.sort((_V4Cidr a, _V4Cidr b) => a.network.compareTo(b.network));
  return minimal;
}

List<_V6Cidr> _minimizeV6(List<_V6Cidr> parsed) {
  parsed.sort((_V6Cidr a, _V6Cidr b) {
    final byLength = a.prefixLength.compareTo(b.prefixLength);
    if (byLength != 0) return byLength;
    return _compareBytes(a.network, b.network);
  });
  final minimal = <_V6Cidr>[];
  for (final cidr in parsed) {
    var covered = false;
    for (final kept in minimal) {
      if (kept.contains(cidr.network)) {
        covered = true;
        break;
      }
    }
    if (!covered) minimal.add(cidr);
  }
  minimal.sort((_V6Cidr a, _V6Cidr b) => _compareBytes(a.network, b.network));
  return minimal;
}

int _compareBytes(Uint8List a, Uint8List b) {
  for (var i = 0; i < 16; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return 0;
}

Uint8List _encodeCip2(List<_V4Cidr> v4, List<_V6Cidr> v6) {
  final bytes = Uint8List(8 + v4.length * 8 + 4 + v6.length * 20);
  final view = ByteData.view(bytes.buffer);
  bytes[0] = 0x43;
  bytes[1] = 0x49;
  bytes[2] = 0x50;
  bytes[3] = 0x32;
  view.setUint32(4, v4.length, Endian.little);
  for (var i = 0; i < v4.length; i++) {
    final base = 8 + i * 8;
    view.setUint32(base, v4[i].network, Endian.little);
    bytes[base + 4] = v4[i].prefixLength;
  }
  final v6Header = 8 + v4.length * 8;
  view.setUint32(v6Header, v6.length, Endian.little);
  for (var i = 0; i < v6.length; i++) {
    final base = v6Header + 4 + i * 20;
    bytes.setRange(base, base + 16, v6[i].network);
    bytes[base + 16] = v6[i].prefixLength;
  }
  return bytes;
}

class _V4Cidr {
  _V4Cidr(this.network, this.prefixLength);

  final int network;
  final int prefixLength;

  int get last {
    if (prefixLength == 0) return 0xFFFFFFFF;
    final mask = (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
    return (network | (~mask & 0xFFFFFFFF)) & 0xFFFFFFFF;
  }

  bool contains(int address) => address >= network && address <= last;

  static _V4Cidr? tryParse(String raw) {
    final slash = raw.indexOf('/');
    if (slash <= 0) return null;
    final hostPart = raw.substring(0, slash);
    if (hostPart.contains(':')) return null;
    final length = int.tryParse(raw.substring(slash + 1));
    if (length == null || length < 0 || length > 32) return null;
    final octets = hostPart.split('.');
    if (octets.length != 4) return null;
    var address = 0;
    for (final octet in octets) {
      final value = int.tryParse(octet);
      if (value == null || value < 0 || value > 255) return null;
      address = (address << 8) | value;
    }
    final mask = length == 0 ? 0 : (0xFFFFFFFF << (32 - length)) & 0xFFFFFFFF;
    return _V4Cidr(address & mask, length);
  }
}

class _V6Cidr {
  _V6Cidr(this.network, this.prefixLength);

  final Uint8List network;
  final int prefixLength;

  bool contains(Uint8List addr) {
    var bits = prefixLength;
    var i = 0;
    while (bits >= 8) {
      if (network[i] != addr[i]) return false;
      i++;
      bits -= 8;
    }
    if (bits == 0) return true;
    final mask = (0xFF << (8 - bits)) & 0xFF;
    return (network[i] & mask) == (addr[i] & mask);
  }

  static _V6Cidr? tryParse(String raw) {
    final slash = raw.indexOf('/');
    if (slash <= 0) return null;
    final hostPart = raw.substring(0, slash);
    if (!hostPart.contains(':')) return null;
    final length = int.tryParse(raw.substring(slash + 1));
    if (length == null || length < 0 || length > 128) return null;
    final parsed = _parseIpv6(hostPart);
    if (parsed == null) return null;
    _applyPrefix(parsed, length);
    return _V6Cidr(parsed, length);
  }
}

void _applyPrefix(Uint8List addr, int prefixLength) {
  var bits = prefixLength;
  for (var i = 0; i < 16; i++) {
    if (bits >= 8) {
      bits -= 8;
      continue;
    }
    if (bits > 0) {
      addr[i] &= (0xFF << (8 - bits)) & 0xFF;
      bits = 0;
    } else {
      addr[i] = 0;
    }
  }
}

Uint8List? _parseIpv6(String s) {
  if (s.startsWith('[') && s.endsWith(']')) {
    s = s.substring(1, s.length - 1);
  }
  if (!s.contains(':')) return null;
  final doubleColon = s.indexOf('::');
  if (doubleColon != -1 && s.indexOf('::', doubleColon + 2) != -1) return null;

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
    if (left.length + right.length > 8) return null;
    parts = <int>[
      ...left,
      ...List<int>.filled(8 - left.length - right.length, 0),
      ...right,
    ];
  } else {
    final parsed = parseParts(s);
    if (parsed == null) return null;
    parts = parsed;
    if (parts.length != 8) return null;
  }
  final out = Uint8List(16);
  for (var i = 0; i < 8; i++) {
    out[i * 2] = (parts[i] >> 8) & 0xFF;
    out[i * 2 + 1] = parts[i] & 0xFF;
  }
  return out;
}
