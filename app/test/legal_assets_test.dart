import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 许可资产副本不能与仓库根文件脱节。
///
/// `app/assets/legal/` 是仓库根 `LICENSE` / `NOTICE.md` / `THIRD-PARTY-NOTICES.md`
/// 的副本：Flutter 的 asset 只能声明在包目录内，无法直接引用仓库根。副本一旦
/// 过期，应用内「开源许可」与随包分发的内容就会与仓库实际许可不一致——这是
/// 合规问题，不是文档问题，因此用逐字节断言守住。
///
/// 为什么是「检入副本 + 相等断言」而不是「只在 CI 里复制」：asset bundle 在
/// `flutter test` / 本地 `flutter build` 时就已确定，`rootBundle` 读不到包目录
/// 之外的文件；若副本不入库，任何没有先跑 CI 复制步骤的本地测试与构建都会
/// 拿不到许可。相等断言让「只复制、忘了更新」这种过期在测试里立刻失败。
/// release.yml 的 prepare 任务会再做一次「复制根文件 + 断言 git 无差异」的兜底。
void main() {
  const files = <String>['LICENSE', 'NOTICE.md', 'THIRD-PARTY-NOTICES.md'];

  test('assets/legal 下的副本与仓库根同名文件逐字节一致', () {
    for (final name in files) {
      final root = File('../$name');
      final copy = File('assets/legal/$name');
      expect(root.existsSync(), isTrue, reason: '仓库根缺少 $name');
      expect(copy.existsSync(), isTrue, reason: '缺少许可副本 assets/legal/$name');
      expect(
        copy.readAsBytesSync(),
        equals(root.readAsBytesSync()),
        reason: '$name 的副本与仓库根不一致：请重新运行 scripts 里的同步步骤再提交',
      );
    }
  });
}
