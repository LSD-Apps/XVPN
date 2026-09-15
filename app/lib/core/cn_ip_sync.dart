/// `cn-ip.bin` 是否仍由当前的 geoip `.srs` 派生。
///
/// 「检查更新」只会替换 `.srs`，不会重算前缀索引。两边脱节时，内核按新网段
/// 分流，DNS 交叉校验与反方向纠正却拿着旧表判定——表现为「该学直连却不学」。
/// 这份检查把脱节变成分流规则页上的一句可见说明，而不是静默偏差。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'cn_ip_index.dart';

class CnIpSyncReport {
  const CnIpSyncReport({
    required this.ok,
    required this.detail,
    this.ipv4Count = 0,
    this.ipv6Count = 0,
  });

  final bool ok;
  final String detail;
  final int ipv4Count;
  final int ipv6Count;

  static const missing = CnIpSyncReport(
    ok: false,
    detail: '找不到 cn-ip.origin.json，无法确认前缀索引与规则集是否同源',
  );
}

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

Future<CnIpSyncReport> checkCnIpSync({
  Directory? ruleSetDir,
  CnIpIndex? index,
}) async {
  Map<String, Object?>? origin;
  try {
    origin = await _loadOrigin(ruleSetDir);
  } on Object {
    return CnIpSyncReport.missing;
  }
  if (origin == null) return CnIpSyncReport.missing;

  final sources = origin['sources'];
  if (sources is! List) return CnIpSyncReport.missing;

  final mismatches = <String>[];
  for (final item in sources) {
    if (item is! Map) continue;
    final name = item['file'];
    final expectedHash = item['fnv1a'];
    final expectedSize = item['size'];
    if (name is! String || expectedHash is! String) continue;
    final file = _resolveSource(ruleSetDir, name);
    if (file == null || !file.existsSync()) {
      mismatches.add('$name 缺失');
      continue;
    }
    final bytes = file.readAsBytesSync();
    if (expectedSize is int && bytes.length != expectedSize) {
      mismatches.add('$name 大小已变');
      continue;
    }
    final actual = fnv1a64Hex(bytes);
    if (actual != expectedHash.toLowerCase()) {
      mismatches.add('$name 内容已变');
    }
  }

  final ipv4 = origin['ipv4Count'] is int ? origin['ipv4Count'] as int : 0;
  final ipv6 = origin['ipv6Count'] is int ? origin['ipv6Count'] as int : 0;
  if (index != null) {
    if (index.ipv4Length != ipv4 || index.ipv6Length != ipv6) {
      mismatches.add('索引条目数与生成记录不一致');
    }
  }

  if (mismatches.isEmpty) {
    return CnIpSyncReport(
      ok: true,
      detail: '前缀索引与 geoip 规则集同源（IPv4 $ipv4 / IPv6 $ipv6）',
      ipv4Count: ipv4,
      ipv6Count: ipv6,
    );
  }
  return CnIpSyncReport(
    ok: false,
    detail:
        '国内 IP 前缀索引与规则集不同步（${mismatches.join('；')}）。'
        '分流会按新规则集走，交叉校验仍用旧表。'
        '从源码构建请重跑 scripts/build-cn-ip-index.ps1；安装包用户等下一次应用更新即可。',
    ipv4Count: ipv4,
    ipv6Count: ipv6,
  );
}

Future<Map<String, Object?>?> _loadOrigin(Directory? ruleSetDir) async {
  if (ruleSetDir != null) {
    final file = File('${ruleSetDir.path}${Platform.pathSeparator}cn-ip.origin.json');
    if (file.existsSync()) {
      try {
        return _decodeOrigin(file.readAsStringSync());
      } on Object {
        return null;
      }
    }
  }
  try {
    final raw = await rootBundle.loadString(CnIpIndex.originAssetPath);
    return _decodeOrigin(raw);
  } on Object {
    return null;
  }
}

Map<String, Object?>? _decodeOrigin(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, Object?>) return decoded;
  if (decoded is Map) return decoded.cast<String, Object?>();
  return null;
}

File? _resolveSource(Directory? ruleSetDir, String name) {
  if (ruleSetDir != null) {
    return File('${ruleSetDir.path}${Platform.pathSeparator}$name');
  }
  return null;
}
