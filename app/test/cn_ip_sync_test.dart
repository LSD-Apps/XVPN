import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/cn_ip_index.dart';
import 'package:xvpn/core/cn_ip_sync.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xvpn-cn-ip-sync');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File writeSrs(String name, List<int> bytes) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  void writeOrigin({
    required List<File> sources,
    int ipv4Count = 2,
    int ipv6Count = 1,
  }) {
    final items = <String>[];
    for (final file in sources) {
      final bytes = file.readAsBytesSync();
      final hash = fnv1a64Hex(bytes);
      items.add(
        '{"file":"${file.uri.pathSegments.last}","size":${bytes.length},'
        '"fnv1a":"$hash"}',
      );
    }
    File('${dir.path}${Platform.pathSeparator}cn-ip.origin.json')
        .writeAsStringSync(
      '{"format":"CIP2","ipv4Count":$ipv4Count,"ipv6Count":$ipv6Count,'
      '"sources":[${items.join(',')}]}',
    );
  }

  test('同源时报告 ok', () async {
    final a = writeSrs('geoip-cn.srs', <int>[1, 2, 3, 4]);
    final b = writeSrs('geoip-cn-extra.srs', <int>[5, 6, 7]);
    writeOrigin(sources: <File>[a, b]);
    final report = await checkCnIpSync(ruleSetDir: dir);
    expect(report.ok, isTrue);
    expect(report.ipv4Count, 2);
    expect(report.ipv6Count, 1);
    expect(report.detail, contains('同源'));
  });

  test('.srs 内容变了就报不同步', () async {
    final a = writeSrs('geoip-cn.srs', <int>[1, 2, 3, 4]);
    writeOrigin(sources: <File>[a], ipv4Count: 1, ipv6Count: 0);
    a.writeAsBytesSync(<int>[9, 9, 9, 9]);
    final report = await checkCnIpSync(ruleSetDir: dir);
    expect(report.ok, isFalse);
    expect(report.detail, contains('内容已变'));
  });

  test('索引条目数对不上也报不同步', () async {
    final a = writeSrs('geoip-cn.srs', <int>[1, 2, 3]);
    writeOrigin(sources: <File>[a], ipv4Count: 99, ipv6Count: 0);
    final report = await checkCnIpSync(
      ruleSetDir: dir,
      index: CnIpIndex.empty,
    );
    expect(report.ok, isFalse);
    expect(report.detail, contains('条目数'));
  });

  test('origin 损坏时给出明确说明，而不是假装同步', () async {
    File('${dir.path}${Platform.pathSeparator}cn-ip.origin.json')
        .writeAsStringSync('[]');
    final report = await checkCnIpSync(ruleSetDir: dir);
    expect(report.ok, isFalse);
    expect(report.detail, contains('cn-ip.origin.json'));
  });

  test('出厂 origin.json 与 cn-ip.bin、两份 geoip .srs 同源', () async {
    final assets = Directory('assets/rulesets');
    final bin = File('${assets.path}${Platform.pathSeparator}cn-ip.bin');
    if (!bin.existsSync()) {
      markTestSkipped('没有出厂索引');
      return;
    }
    final index = CnIpIndex.parse(bin.readAsBytesSync());
    expect(index, isNotNull);
    expect(index!.hasIpv6, isTrue);
    final report = await checkCnIpSync(ruleSetDir: assets, index: index);
    expect(report.ok, isTrue, reason: report.detail);
    expect(index.ipv4Length, report.ipv4Count);
    expect(index.ipv6Length, report.ipv6Count);
  });
}
