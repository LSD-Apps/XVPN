/// 应用版本。
///
/// 版本号此前有两处，且**互不一致**：`pubspec.yaml` 写 `1.0.0+1`，
/// 而设置页侧栏底部硬编码显示 `v0.1.0`。用户看到的版本与安装包的真实版本
/// 不是一回事，反馈问题时会直接误导排查。
///
/// 这里改成**构建期注入**：构建时用 `--dart-define=XVPN_VERSION=...` 传入，
/// 未传时回落到 [fallback]（开发期直接 `flutter run` 的场景）。
///
/// 之所以不用 `package_info_plus` 之类在运行时读平台包信息：那会为一个字符串
/// 引入一个平台插件（两端各要改原生工程），而本项目刻意保持依赖精简。
library;

/// 构建期注入的版本号。
///
/// 与 `pubspec.yaml` 的 `version:` 保持一致；发布脚本两者一起传。
const String buildVersion = String.fromEnvironment('XVPN_VERSION');

/// 未注入时的回落值。
///
/// 与 `pubspec.yaml` 同步维护。[version_test.dart] 会断言它不会与 pubspec
/// 脱节——两处版本号不一致正是这次要修的问题，必须由测试守住。
const String fallbackVersion = '1.1.0';

/// 用于界面展示的版本号（不含 build 号）。
String get appVersion => buildVersion.isEmpty ? fallbackVersion : buildVersion;

/// 构建命令里要带的参数，供发布脚本与文档统一引用。
String get versionDefine => '--dart-define=XVPN_VERSION=$fallbackVersion';
