import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/version.dart';

/// 版本号一致性。
///
/// 这个用例的由来是一个真实缺陷：设置页侧栏底部硬编码显示 `v0.1.0`，
/// 而 `pubspec.yaml` 里是 `1.0.0+1`。用户看到的版本与安装包的真实版本
/// 不是一回事——反馈问题时这会直接误导排查。
///
/// 现在版本号只有一处可注入来源（`version.dart`），而这里确保它不会与
/// `pubspec.yaml` 脱节：改了 pubspec 却忘了改回落值（或反过来），测试会失败。
void main() {
  /// 从 pubspec.yaml 里读 `version:` 的主版本号（去掉 `+build` 部分）。
  String pubspecVersion() {
    final file = File('pubspec.yaml');
    expect(file.existsSync(), isTrue, reason: '测试的工作目录应是 app/');
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('version:')) continue;
      final raw = trimmed.substring('version:'.length).trim();
      // `1.0.0+1` → `1.0.0`：界面只展示语义版本，不带 build 号。
      return raw.split('+').first;
    }
    fail('pubspec.yaml 里没有 version: 字段');
  }

  test('回落版本号与 pubspec.yaml 一致', () {
    expect(
      fallbackVersion,
      pubspecVersion(),
      reason: 'version.dart 的 fallbackVersion 必须与 pubspec.yaml 的 version 一致；'
          '两处版本号不一致正是这个测试要防的问题',
    );
  });

  test('未注入时用回落值', () {
    // 测试环境不带 --dart-define，因此 buildVersion 应为空。
    expect(buildVersion, isEmpty, reason: '测试进程不应带 XVPN_VERSION 定义');
    expect(appVersion, fallbackVersion);
  });

  test('版本号格式是语义化版本', () {
    expect(
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(appVersion),
      isTrue,
      reason: 'appVersion 应为 x.y.z 形式，实际是「$appVersion」',
    );
  });

  test('构建参数里带上了版本定义', () {
    expect(versionDefine, '--dart-define=XVPN_VERSION=$fallbackVersion');
  });
}
