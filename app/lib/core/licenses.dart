import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 应用内「开源许可」界面所展示的、本项目自身的许可与第三方声明。
///
/// 为什么需要单独注册：Flutter 的 `LicenseRegistry` 默认只聚合 **Dart/Flutter
/// 依赖与引擎**的许可（构建期生成的 `NOTICES.Z`），它**不包含**：
///   * 本项目的 GPL-3.0-or-later 正文（`LICENSE`）；
///   * 第三方组件声明（`NOTICE.md`）；
///   * 内核静态内嵌的 Go 依赖聚合声明（`THIRD-PARTY-NOTICES.md`）。
///
/// 三者一直随包分发在 Android 的 native assets 与桌面端压缩包里，但用户此前
/// 在应用内读不到——「分发」不等于「可见」。这里把它们注册成许可页条目，
/// 入口在设置页（见 `screens/settings_screen.dart`）。
///
/// 这些条目来自 `assets/legal/`，那是仓库根同名文件的副本：Flutter 的 asset
/// 只能声明在包目录内，无法直接引用仓库根。副本的时效性由
/// `test/legal_assets_test.dart`（逐字节相等）与 CI 的 prepare 任务共同守住。
void registerBundledLicenses() {
  if (_registered) return;
  _registered = true;
  for (final entry in bundledLicenseAssets) {
    LicenseRegistry.addLicense(() async* {
      final built = await _buildEntry(entry.asset, entry.packages);
      if (built != null) yield built;
    });
  }
}

/// 构建全部本项目许可条目（不注册）。
///
/// 测试用它验证 asset 可读、文本正确；也让「注册」与「读取」两条路径共用同一
/// 段构造逻辑，避免测试通过而真实界面走另一条实现。
Future<List<LicenseEntry>> loadBundledLicenseEntries() async {
  final entries = <LicenseEntry>[];
  for (final entry in bundledLicenseAssets) {
    final built = await _buildEntry(entry.asset, entry.packages);
    if (built != null) entries.add(built);
  }
  return entries;
}

Future<LicenseEntry?> _buildEntry(String asset, List<String> packages) async {
  final text = await _loadLicenseText(asset);
  // 读不到就跳过，而不是让异常冒泡：许可页应当「少一条」，而不是整页打不开。
  // 非应用入口（例如没有声明该 asset 的嵌入式用法）下 rootBundle 会抛异常，
  // 这里必须优雅降级。
  if (text == null) return null;
  return LicenseEntryWithLineBreaks(packages, text);
}

/// 是否已注册过。注册是全局且幂等的，避免多次构建/测试重复累积条目。
bool _registered = false;

/// 注册条目：asset 路径 + 归属的包名（许可页按包名分组展示）。
///
/// 包名用 `XVPN` 前缀而不是纯中文：许可页会把包名**排序**后列出，`X`（0x58）
/// 排在小写字母（Flutter 依赖的包名）之前，用户打开许可页第一眼就能看到本项目
/// 条目，而不必滚过几十条依赖。
const List<({String asset, List<String> packages})> bundledLicenseAssets = [
  (
    asset: 'assets/legal/LICENSE',
    packages: ['XVPN · 本项目许可（GPL-3.0-or-later）'],
  ),
  (asset: 'assets/legal/NOTICE.md', packages: ['XVPN · 第三方组件与许可']),
  (
    asset: 'assets/legal/THIRD-PARTY-NOTICES.md',
    packages: ['XVPN · 内核静态依赖（sing-box 及其 Go 依赖）'],
  ),
];

Future<String?> _loadLicenseText(String asset) async {
  try {
    return await rootBundle.loadString(asset);
  } on Object {
    return null;
  }
}
