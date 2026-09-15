import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 应用内**仍**随包分发的法律文本，其副本不能与仓库源文件脱节。
///
/// `app/assets/legal/` 里现在只剩 `LEGAL.md`，它是 `docs/LEGAL.md` 的副本
/// （应用内「法律与使用声明」读取）。Flutter 的 asset 只能声明在包目录内。
/// 副本一旦过期，应用内读到的就与仓库实际声明不一致——这是合规问题，因此用
/// 正文断言守住。
///
/// 许可与第三方声明（`LICENSE` / `NOTICE.md` / `THIRD-PARTY-NOTICES.md`）**不再**
/// 有副本：它们随仓库与各平台发布包分发，应用内不再打包也不再有界面读取
/// （见 `test/licenses_test.dart`）。因此这里不该再为它们保留相等断言——那会让
/// 一次「把文本塞回安装包」的回退悄悄通过。
///
/// 比较前把 CRLF 收成 LF：Windows 上 git 的 `core.autocrlf` 会让工作区一份
/// 是 CRLF、一份仍是 LF，逐字节比较会把换行差异报成「声明文本不一致」。
/// 真正要守住的是声明正文，不是某台机器上的换行符。
///
/// 为什么是「检入副本 + 相等断言」而不是「只在 CI 里复制」：asset bundle 在
/// `flutter test` / 本地 `flutter build` 时就已确定，`rootBundle` 读不到包目录
/// 之外的文件；若副本不入库，任何没有先跑 CI 复制步骤的本地测试与构建都会
/// 拿不到声明。相等断言让「只复制、忘了更新」这种过期在测试里立刻失败。
/// release.yml 的 prepare 任务会再做一次同样的兜底。
void main() {
  test('assets/legal/LEGAL.md 与 docs/LEGAL.md 正文一致', () {
    final source = File('../docs/LEGAL.md');
    final copy = File('assets/legal/LEGAL.md');
    expect(source.existsSync(), isTrue, reason: '缺少 docs/LEGAL.md');
    expect(copy.existsSync(), isTrue, reason: '缺少应用内法律声明副本');
    expect(
      _legalText(copy),
      _legalText(source),
      reason: 'LEGAL.md 副本与 docs/LEGAL.md 不一致',
    );
  });

  test('assets/legal 下不再有许可与第三方声明文本', () {
    // 这一条与 `test/licenses_test.dart` 的取舍是同一件事的两面：那边断言
    // 「应用不再列举许可」，这边断言「许可文本没有被打回包里」。400 KB 的
    // 聚合许可是当时那套浏览界面的附属物，界面拆掉之后它们只会白占包体。
    final dir = Directory('assets/legal');
    expect(dir.existsSync(), isTrue, reason: '缺少 assets/legal/');
    final names = dir
        .listSync()
        .whereType<File>()
        .map((File f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(
      names,
      <String>['LEGAL.md'],
      reason: 'assets/legal 里只应留 LEGAL.md；许可与第三方声明不再随包分发',
    );
  });
}

/// 读文件并去掉 `\r`，只比较声明正文。
String _legalText(File file) => file.readAsStringSync().replaceAll('\r\n', '\n');
