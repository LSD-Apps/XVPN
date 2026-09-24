import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/updater.dart';

/// 发布附件名的**三处同步**（CI、本机打包脚本、更新器）必须真的同步。
///
/// 这条契约在仓库里被反复写进注释——「附件名是契约，改动必须三处同步」——但此前
/// 没有任何东西**断言**它。这类漂移的代价很高，而且不会在构建期暴露：
///
///   * 更新器按契约名找不到附件时，用户看到的是「最新版本没有适用于本平台的
///     安装包」——一个看起来像「上游没发布」的提示，而不是「代码写错了」；
///   * CI 少挂一个附件时，发布是**绿的**，只是新版本没人能自动升级；
///   * 两侧都改了但改得不一样时，只有真机点一次「检查更新」才会发现。
///
/// 因此这里断言的是**文档化的清单与真的产出**两件事：只查注释会漏掉「文档写了、
/// 步骤里没做」，只查步骤又会漏掉「更新器期望的名字没人产出」。
void main() {
  final File workflow = File('../.github/workflows/release.yml');
  final File localScript = File('../scripts/build-release.ps1');
  final File releaseDoc = File('../docs/RELEASE.md');

  /// 取出文本里形如 `XVPN-<ver>-xxx` 的附件后缀。
  ///
  /// CI 的头部注释、本机脚本的头部注释与 RELEASE.md 的表格都用 `<ver>` 作占位符，
  /// 因此三处都能用同一把尺子量。`SHA256SUMS.txt` 没有 `XVPN-<ver>-` 前缀，
  /// 单独断言。
  Set<String> documentedSuffixes(File file, {int? lines}) {
    final String text = lines == null
        ? file.readAsStringSync()
        : file.readAsLinesSync().take(lines).join('\n');
    return <String>{
      for (final RegExpMatch match
          in RegExp(r'XVPN-<ver>-([A-Za-z0-9._-]+)').allMatches(text))
        match.group(1)!,
    };
  }

  /// 更新器期望的本平台附件后缀（由 [expectedAssetName] 推出，是唯一事实来源）。
  Set<String> updaterSuffixes() => <String>{
    for (final UpdatePlatform platform in UpdatePlatform.values)
      expectedAssetName(platform, '<ver>').replaceFirst('XVPN-<ver>-', ''),
  };

  test('CI 文档化的附件清单与更新器的期望一致（外加自签名证书）', () {
    final String header = workflow.readAsLinesSync().take(40).join('\n');
    expect(
      documentedSuffixes(workflow, lines: 40),
      updaterSuffixes().union(<String>{'windows-msix.cer'}),
      reason:
          'release.yml 头部注释里的附件清单与 updater.dart 的 expectedAssetName 不一致。'
          '更新器是按精确文件名找附件的，名字对不上时用户只会看到「没有适用于本平台的安装包」。',
    );
    expect(
      header,
      contains('SHA256SUMS.txt'),
      reason: '更新器要求发布里必须有 SHA256SUMS.txt，清单里要写出来。',
    );
  });

  test('本机打包脚本文档化的附件清单覆盖它真正能构建的两端', () {
    // Linux 的产物只能在 Linux 上编译（本机脚本顶部说明了这一点），因此这里的
    // 清单是「Windows + Android」，不要求与 CI 完全相同。
    expect(
      documentedSuffixes(localScript, lines: 45),
      <String>{'windows-x64.msix', 'windows-msix.cer', 'android-arm64.zip'},
      reason: 'scripts/build-release.ps1 头部注释的附件清单已过期：本机脚本必须与 CI 产出同一组附件。',
    );
    expect(
      localScript.readAsLinesSync().take(45).join('\n'),
      contains('SHA256SUMS.txt'),
      reason: '本机脚本也要生成校验和。',
    );
  });

  test('发布说明（docs/RELEASE.md）的附件表与更新器的期望一致', () {
    // 只看每张表格的**第一格**：表格正文里还会提到 zip 内部那个 APK 的名字，
    // 而它不是发布附件。
    final Set<String> table = <String>{
      for (final String line in releaseDoc.readAsLinesSync())
        if (RegExp(r'^\| `XVPN-<ver>-[A-Za-z0-9._-]+`').firstMatch(line) != null)
          RegExp(r'^\| `XVPN-<ver>-([A-Za-z0-9._-]+)`')
              .firstMatch(line)!
              .group(1)!,
    };
    expect(
      table,
      updaterSuffixes().union(<String>{'windows-msix.cer'}),
      reason: 'docs/RELEASE.md 的「附件命名契约」表已经与代码不符。',
    );
    expect(
      releaseDoc.readAsStringSync(),
      contains('| `SHA256SUMS.txt`'),
      reason: '校验和文件也是发布附件，表格里要有它。',
    );
  });

  test('CI 真的产出并上传这些附件', () {
    final String text = workflow.readAsStringSync();
    for (final String path in <String>[
      // Windows 只有 MSIX 一种形态。
      'dist/XVPN-*-windows-x64.msix',
      // Android 只有 zip（APK 在 zip 内部）。
      'dist/XVPN-*-android-arm64.zip',
      'dist/XVPN-*-linux-x64.zip',
    ]) {
      expect(
        text,
        contains(path),
        reason: 'release.yml 没有把 $path 作为产物上传；文档写了但流水线没做时，'
            '发布仍然是绿的，只是没人能自动升级。',
      );
    }
    expect(
      text,
      isNot(contains('dist/XVPN-*-windows-x64.zip')),
      reason: 'Windows 不再发布绿色版 zip：它一旦被上传，更新器就可能选到过期的包。',
    );
  });

  test('裸 APK 不进发布页（安卓只发内含 APK 的 zip）', () {
    final String text = workflow.readAsStringSync();
    expect(
      text,
      isNot(contains('dist/XVPN-*-android-arm64.apk')),
      reason: '安卓的 APK 只能待在 zip 里面：发布页不直接分发裸 APK。',
    );
    expect(
      text,
      isNot(contains('dist/*.apk')),
      reason: 'gh release upload 不能再带上裸 APK。',
    );
    // SHA256SUMS 的通配列表里同样不能有 *.apk，否则「校验和文件里有它」会被
    // 当成「这个包该发」。
    final RegExpMatch? match =
        RegExp(r'files=\(([^)]*)\)').firstMatch(text);
    expect(match, isNotNull, reason: 'release.yml 里找不到 SHA256SUMS 的文件列表');
    expect(
      match!.group(1),
      isNot(contains('.apk')),
      reason: 'SHA256SUMS.txt 不应把裸 APK 算作产物。',
    );
  });

  test('CI 的 Windows 任务要求发行签名证书（Windows 只发 MSIX）', () {
    final String text = workflow.readAsStringSync();
    expect(
      text,
      contains('MSIX_PFX_BASE64'),
      reason: '证书缺失时必须直接失败，而不是回退到「每次构建现造一张自签名证书」'
          '——那样每个版本由不同证书签名，已装旧版的用户只能卸载重装。',
    );
    expect(
      text,
      contains('缺少 MSIX 发行签名证书'),
      reason: '守卫必须在缺证书时真的抛错，而不是打一条警告继续发。',
    );
  });

  test('本机脚本不产出裸 APK，也不产出 Windows 绿色版 zip', () {
    final String text = localScript.readAsStringSync();
    expect(
      text,
      isNot(contains(r'XVPN-$ver-windows-x64.zip')),
      reason: '本机脚本与 CI 必须产出同一组附件。',
    );
    expect(
      text,
      contains(r'XVPN-$ver-windows-x64.msix'),
      reason: 'Windows 只发 MSIX。',
    );
    expect(
      text,
      isNot(contains(r'$apkOut = Join-Path $distDir')),
      reason: '裸 APK 不进 dist（安卓只发内含 APK 的 zip）。',
    );
    expect(
      text,
      contains('安卓只发内含 APK 的 zip'),
      reason: 'dist 里遗留的裸 APK 会被算进 SHA256SUMS，脚本必须挡住它。',
    );
  });
}
