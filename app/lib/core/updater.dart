import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../version.dart';
import 'links.dart';
import 'sha256.dart';

// ---------------------------------------------------------------- 仓库与地址

/// 从 [kRepoUrl] 解析出的 GitHub owner / repo。
///
/// 更新器需要的是 `api.github.com/repos/<owner>/<repo>/releases/latest`，而
/// 仓库地址已经有唯一来源（[kRepoUrl]）。这里解析而不是另写一份常量：
/// 地址将来迁移时只改一处，最坏情况是这里解析失败并如实报错，而不是悄悄
/// 去查一个已经不存在的仓库。
({String owner, String repo})? parseGitHubRepo(String repoUrl) {
  final Uri? uri = Uri.tryParse(repoUrl);
  if (uri == null) return null;
  final segments = uri.pathSegments.where((String s) => s.isNotEmpty).toList();
  if (segments.length < 2) return null;
  return (owner: segments[0], repo: segments[1]);
}

/// 最新 Release 的 GitHub API 地址。
Uri latestReleaseApiUri({String repoUrl = kRepoUrl}) {
  final repo = parseGitHubRepo(repoUrl);
  if (repo == null) {
    throw ArgumentError('无法从 $repoUrl 解析出 GitHub owner/repo');
  }
  return Uri.https(
    'api.github.com',
    '/repos/${repo.owner}/${repo.repo}/releases/latest',
  );
}

// ---------------------------------------------------------------- 平台

/// 更新器实际区分安装方式的平台。
///
/// 与 [TargetPlatform] 分开是有意的：`macos` / `ios` 等平台尚未提供安装包，
/// 把它们映射成 null，调用方据此给出「当前平台不支持自动更新」的一句实话，
/// 而不是去猜一个附件名。
enum UpdatePlatform { windows, linux, android }

UpdatePlatform? updatePlatformFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.windows => UpdatePlatform.windows,
      TargetPlatform.linux => UpdatePlatform.linux,
      TargetPlatform.android => UpdatePlatform.android,
      _ => null,
    };

String updatePlatformLabel(UpdatePlatform platform) => switch (platform) {
  UpdatePlatform.windows => 'Windows x64',
  UpdatePlatform.linux => 'Linux x64',
  UpdatePlatform.android => 'Android arm64',
};

/// 发布附件的精确命名（契约，见 `.github/workflows/release.yml` 与
/// `scripts/build-release.ps1`）。[version] 是 tag 去掉前导 `v`。
///
/// 安卓要的是**裸 APK**：系统安装器只接受 APK 文件，而 Dart 标准库没有解压
/// 能力，拿到 zip 也用不了。
String expectedAssetName(UpdatePlatform platform, String version) {
  final suffix = switch (platform) {
    UpdatePlatform.windows => 'windows-x64.zip',
    UpdatePlatform.linux => 'linux-x64.zip',
    UpdatePlatform.android => 'android-arm64.apk',
  };
  return 'XVPN-$version-$suffix';
}

/// 取暂存目录。
///
/// 安卓必须落在 FileProvider 声明的 `cache-path` 之下
/// （见 `app/android/app/src/main/res/xml/file_paths.xml`），否则系统安装器
/// 拿不到 APK 的 URI、直接抛 `FileUriExposedException`。
///
/// [tempPath] 显式传入是为了让安卓的取值能在 Windows 开发机上被单元测试锁定。
Directory defaultUpdateStagingDir(TargetPlatform platform, {String? tempPath}) {
  final String temp = tempPath ?? Directory.systemTemp.path;
  if (platform == TargetPlatform.android) {
    return Directory('$temp/updates');
  }
  final String separator = platform == TargetPlatform.windows ? '\\' : '/';
  return Directory('$temp${separator}xvpn-update');
}

/// 探测某个目录当前是否**可写**：落一个探针文件再删掉。
///
/// 用真实写入而不是查 ACL：ACL 说「可写」却在不少情况下仍写不进去（受保护
/// 目录、只读卷、被安全软件拦住），而**写入**恰恰是更新真正要做的事。探针写
/// 不进去，更新就一定做不成——早一点、并且以一句人能读懂的话告诉用户，好过
/// 让他看着一个复制到一半的安装目录。
bool probeDirWritable(Directory dir) {
  final String separator = Platform.pathSeparator;
  final probe = File('${dir.path}$separator.xvpn-update-probe');
  try {
    probe.writeAsStringSync('', flush: true);
  } on Object {
    return false;
  }
  try {
    probe.deleteSync();
  } on Object {
    // 探针删不掉不影响结论：写入已经成功了。
  }
  return true;
}

/// 推荐的**用户目录**安装位置。
///
/// 「装在受保护目录」是自动更新需要管理员授权的唯一原因。绿色分发的应用只要
/// 解压到这里，更新就永远不需要提权——VS Code 的 user setup、Chrome 这类自更新
/// 应用走的都是这条路。因此每次拒绝或要求提权时都把这条出路一并给出来，让用户
/// 有机会一次摆脱它，而不是每次更新都要点一次 UAC。
String suggestedUserInstallDir(
  TargetPlatform platform, {
  Map<String, String>? environment,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  if (platform == TargetPlatform.windows) {
    final String? localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      return '$localAppData\\Programs\\XVPN';
    }
    final String? profile = env['USERPROFILE'];
    if (profile != null && profile.trim().isNotEmpty) {
      return '$profile\\AppData\\Local\\Programs\\XVPN';
    }
    return '本地应用数据目录（%LOCALAPPDATA%）\\Programs\\XVPN';
  }
  // Linux：~/.local/opt 在 FHS 之外，但已是「用户级第三方应用」的通行落点，
  // 且一定可写（不像 /usr/bin、/usr/lib 归包管理器所有）。
  final String? home = env['HOME'];
  if (home != null && home.trim().isNotEmpty) {
    return '$home/.local/opt/xvpn';
  }
  return '~/.local/opt/xvpn';
}

// ---------------------------------------------------------------- 版本比较

/// 解析后的版本号。比较规则遵循 SemVer 2.0.0 的主干部分。
class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion(this.numbers, this.preRelease, this.raw);

  /// 主版本号各段。缺省段按 0 处理（`1.1` 等价于 `1.1.0`）。
  final List<int> numbers;

  /// 预发布标识符（`1.1.0-beta.1` → `['beta', '1']`）。为空表示正式版。
  final List<String> preRelease;

  /// 原始输入，仅用于报错信息。
  final String raw;

  static final RegExp _numeric = RegExp(r'^[0-9]+$');
  static final RegExp _identifier = RegExp(r'^[0-9A-Za-z-]+$');

  /// 解析版本号。无法识别时返回 null（**不抛异常**：版本号来自网络，
  /// 任何形态都可能出现，调用方需要的是「无法比较」这个结论）。
  static ReleaseVersion? tryParse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    // tag 是 v1.2.3，而 appVersion 是 1.2.3：前导 v 不参与比较。
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    // 构建元数据（+build）按 SemVer 不参与比较，直接丢弃。
    final int plus = text.indexOf('+');
    if (plus >= 0) text = text.substring(0, plus);

    var preRelease = const <String>[];
    final int dash = text.indexOf('-');
    if (dash >= 0) {
      final preText = text.substring(dash + 1);
      text = text.substring(0, dash);
      if (preText.isEmpty) return null;
      final parts = preText.split('.');
      for (final part in parts) {
        if (part.isEmpty || !_identifier.hasMatch(part)) return null;
      }
      preRelease = parts;
    }

    if (text.isEmpty) return null;
    final numbers = <int>[];
    for (final part in text.split('.')) {
      if (part.isEmpty || !_numeric.hasMatch(part)) return null;
      final value = int.tryParse(part);
      if (value == null) return null;
      numbers.add(value);
    }
    if (numbers.isEmpty) return null;
    return ReleaseVersion(numbers, preRelease, input.trim());
  }

  @override
  int compareTo(ReleaseVersion other) {
    final length = numbers.length > other.numbers.length
        ? numbers.length
        : other.numbers.length;
    for (var i = 0; i < length; i++) {
      final a = i < numbers.length ? numbers[i] : 0;
      final b = i < other.numbers.length ? other.numbers[i] : 0;
      if (a != b) return a < b ? -1 : 1;
    }
    // 主干相同：带预发布后缀的**更小**（SemVer 第 11 条）。
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final preLength = preRelease.length > other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < preLength; i++) {
      if (i >= preRelease.length) return -1;
      if (i >= other.preRelease.length) return 1;
      final cmp = _compareIdentifier(preRelease[i], other.preRelease[i]);
      if (cmp != 0) return cmp;
    }
    return 0;
  }

  static int _compareIdentifier(String a, String b) {
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    if (aNumber != null && bNumber != null) {
      if (aNumber == bNumber) return 0;
      return aNumber < bNumber ? -1 : 1;
    }
    // 纯数字标识符优先级低于字母标识符。
    if (aNumber != null) return -1;
    if (bNumber != null) return 1;
    return a.compareTo(b);
  }
}

/// [candidate] 是否比 [current] 新。
///
/// 任一侧无法解析时返回 false：**宁可不更新，也不要因为版本号读不懂就把用户
/// 推向一个未知版本**。相等或更低同样返回 false。
bool isNewerVersion(String candidate, String current) {
  final a = ReleaseVersion.tryParse(candidate);
  final b = ReleaseVersion.tryParse(current);
  if (a == null || b == null) return false;
  return a.compareTo(b) > 0;
}

/// tag（`v1.2.3`）→ 附件命名里用的版本号（`1.2.3`）。
///
/// 只去掉前导 v：预发布后缀属于版本号本身，附件名里带着它
/// （CI 里 `ver="${REF_NAME#v}"`）。
String normalizeTagVersion(String tag) {
  var text = tag.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  return text;
}

// ---------------------------------------------------------------- 校验和

/// 解析 `SHA256SUMS.txt`（`sha256sum` 格式）。
///
/// 返回「文件名 → 小写十六进制摘要」。无法识别的行直接跳过：一个坏行不该让
/// 整份校验文件作废，而真正的危险是**根本没匹配到**——那由
/// [verifyChecksum] 的 [ChecksumEntryMissing] 明确报出来。
Map<String, String> parseChecksums(String content) {
  final result = <String, String>{};
  var text = content;
  // 带 BOM 的文件（Windows 记事本另存）很常见，不处理会让整个文件白读。
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final line = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final match = line.firstMatch(trimmed);
    if (match == null) continue;
    final name = match.group(2)!.trim();
    if (name.isEmpty) continue;
    result[name] = match.group(1)!.toLowerCase();
  }
  return result;
}

/// 校验结果。
sealed class ChecksumResult {
  const ChecksumResult();
}

/// 摘要匹配。
class ChecksumVerified extends ChecksumResult {
  const ChecksumVerified(this.sha256);

  final String sha256;
}

/// 校验文件里没有这个文件的记录。
class ChecksumEntryMissing extends ChecksumResult {
  const ChecksumEntryMissing(this.assetName);

  final String assetName;
}

/// 摘要不匹配。
class ChecksumMismatch extends ChecksumResult {
  const ChecksumMismatch({required this.expected, required this.actual});

  final String expected;
  final String actual;
}

/// 把实际摘要与校验文件里期望的摘要比对。
ChecksumResult verifyChecksum({
  required Map<String, String> checksums,
  required String assetName,
  required String actualSha256,
}) {
  final actual = actualSha256.toLowerCase();
  final expected = checksums[assetName];
  if (expected == null) return ChecksumEntryMissing(assetName);
  if (expected != actual) {
    return ChecksumMismatch(expected: expected, actual: actual);
  }
  return ChecksumVerified(actual);
}

// ---------------------------------------------------------------- GitHub 模型

/// 发布附件。
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.downloadUrl, this.size});

  final String name;
  final Uri downloadUrl;
  final int? size;
}

/// 一次最新 Release 的解析结果。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.assets,
    this.pageUrl,
    this.notes,
  });

  final String tag;

  /// tag 去掉前导 v，也是附件文件名里使用的版本号。
  final String version;

  final List<ReleaseAsset> assets;
  final Uri? pageUrl;
  final String? notes;

  /// 解析 API 返回的 JSON。结构不对时返回 null（调用方转成可读提示）。
  static ReleaseInfo? tryParse(Object? decoded) {
    if (decoded is! Map) return null;
    final tag = decoded['tag_name'];
    if (tag is! String || tag.trim().isEmpty) return null;
    final version = normalizeTagVersion(tag);
    if (version.isEmpty) return null;

    final assets = <ReleaseAsset>[];
    final assetsRaw = decoded['assets'];
    if (assetsRaw is List) {
      for (final item in assetsRaw) {
        if (item is! Map) continue;
        final name = item['name'];
        final url = item['browser_download_url'];
        if (name is! String || name.isEmpty) continue;
        if (url is! String) continue;
        final parsed = Uri.tryParse(url);
        if (parsed == null) continue;
        final size = item['size'];
        assets.add(
          ReleaseAsset(
            name: name,
            downloadUrl: parsed,
            size: size is int ? size : null,
          ),
        );
      }
    }

    final pageRaw = decoded['html_url'];
    final notes = decoded['body'];
    return ReleaseInfo(
      tag: tag.trim(),
      version: version,
      assets: assets,
      pageUrl: pageRaw is String ? Uri.tryParse(pageRaw) : null,
      notes: notes is String && notes.isNotEmpty ? notes : null,
    );
  }
}

/// 选出本平台要下载的附件。
///
/// 先按契约里的精确文件名匹配；匹配不到时退回同后缀的近似匹配——上游若调整了
/// 版本号的写法，更新器不该立刻失效。返回 null 表示这一版确实没有本平台的包。
ReleaseAsset? selectAsset(
  List<ReleaseAsset> assets,
  UpdatePlatform platform,
  String version,
) {
  final expected = expectedAssetName(platform, version);
  for (final asset in assets) {
    if (asset.name == expected) return asset;
  }
  final pattern = switch (platform) {
    UpdatePlatform.windows => RegExp(
      r'-windows-x64\.zip$',
      caseSensitive: false,
    ),
    UpdatePlatform.linux => RegExp(r'-linux-x64\.zip$', caseSensitive: false),
    UpdatePlatform.android => RegExp(
      r'-android-arm64\.apk$',
      caseSensitive: false,
    ),
  };
  for (final asset in assets) {
    if (pattern.hasMatch(asset.name)) return asset;
  }
  return null;
}

/// 选出 `SHA256SUMS.txt`。找不到它就不该开始下载大文件。
ReleaseAsset? selectChecksumsAsset(List<ReleaseAsset> assets) {
  for (final asset in assets) {
    if (asset.name == 'SHA256SUMS.txt') return asset;
  }
  for (final asset in assets) {
    if (asset.name.toLowerCase() == 'sha256sums.txt') return asset;
  }
  return null;
}

// ---------------------------------------------------------------- HTTP 抽象

/// 一次 GET 响应。
class UpdateHttpResponse {
  const UpdateHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.contentLength,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final int? contentLength;

  /// 大小写不敏感地取响应头。HTTP 头名本身不区分大小写，而不同实现返回的
  /// 大小写并不一致（限流判断依赖这里）。
  String? header(String name) {
    final wanted = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return null;
  }
}

/// 更新器对 HTTP 的最小需求。
///
/// 抽成接口的唯一目的：让「非 200、限流、超时、断网、JSON 坏掉、附件缺失」
/// 这些只有在真实网络上才会遇到的路径，能在 Windows 开发机上用替身稳定复现
/// ——真实网络测试不可重复，而这几条恰恰是用户最常撞到的。
abstract class UpdateHttpClient {
  Future<UpdateHttpResponse> send(Uri url);
}

/// 真实实现，基于 `http` 包（已是项目依赖）。
class RealUpdateHttpClient implements UpdateHttpClient {
  RealUpdateHttpClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<UpdateHttpResponse> send(Uri url) async {
    final request = http.Request('GET', url);
    // GitHub API 对没有 User-Agent 的请求直接返回 403，而不是提示原因。
    request.headers['User-Agent'] = 'XVPN-Updater';
    request.headers['Accept'] = 'application/vnd.github+json';
    final response = await _client.send(request);
    return UpdateHttpResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: response.stream,
      contentLength: response.contentLength,
    );
  }

  void close() => _client.close();
}

/// 把 HTTP 状态码翻译成用户看得懂的中文原因。返回 null 表示成功（2xx）。
String? describeHttpFailure(int statusCode, String? rateLimitRemaining) {
  if (statusCode >= 200 && statusCode < 300) return null;
  if (statusCode == 403 && rateLimitRemaining == '0') {
    return 'GitHub 接口访问过于频繁（已达每小时上限），请稍后再试。';
  }
  if (statusCode == 403) {
    return '更新服务器拒绝了请求（HTTP 403），请稍后再试。';
  }
  if (statusCode == 404) {
    return '没有找到发布记录（HTTP 404），可能尚未发布任何版本。';
  }
  if (statusCode == 429) {
    return '请求过于频繁（HTTP 429），请稍后再试。';
  }
  if (statusCode >= 500) {
    return '更新服务器暂时不可用（HTTP $statusCode），请稍后再试。';
  }
  return '服务器返回 HTTP $statusCode。';
}

// ---------------------------------------------------------------- 下载

/// 取消令牌。
///
/// 用显式令牌而不是直接取消 `StreamSubscription`：调用方需要在「用户主动取消」
/// 与「下载自然结束」之间区分，并给出不同文案。
class UpdateCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 进度回调。[total] 为 null 表示服务器没给长度（进度条应显示不确定态）。
typedef DownloadProgressCallback = void Function(int received, int? total);

/// [Updater.checkForUpdate] 的结果。
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// 有可用更新。
class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable(this.info);

  final UpdateInfo info;
}

/// 已经是最新版本（或最新版本不高于当前版本）。
class UpdateNotAvailable extends UpdateCheckResult {
  const UpdateNotAvailable({
    required this.currentVersion,
    required this.latestVersion,
  });

  final String currentVersion;
  final String latestVersion;
}

/// 检查失败，[message] 是可以直接展示给用户的中文原因。
class UpdateCheckFailure extends UpdateCheckResult {
  const UpdateCheckFailure(this.message);

  final String message;
}

/// 有可用更新时的完整信息。界面据此展示版本号、发布说明，并逐步骤执行。
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.platform,
    required this.assetName,
    required this.assetUri,
    required this.checksumsName,
    required this.checksumsUri,
    this.assetSize,
    this.pageUri,
    this.notes,
  });

  final String tag;
  final String version;
  final UpdatePlatform platform;
  final String assetName;
  final Uri assetUri;
  final String checksumsName;
  final Uri checksumsUri;
  final int? assetSize;
  final Uri? pageUri;
  final String? notes;

  /// 发布页地址。没有时退回仓库地址，至少让用户有地方可去。
  String get releaseUrl => pageUri?.toString() ?? kRepoUrl;
}

/// [Updater.download] 的结果。
sealed class UpdateDownloadResult {
  const UpdateDownloadResult();
}

/// 下载并校验通过。
class UpdateDownloaded extends UpdateDownloadResult {
  const UpdateDownloaded(this.file, this.sha256);

  final File file;
  final String sha256;
}

/// 下载或校验失败，[message] 可直接展示。
class UpdateDownloadFailure extends UpdateDownloadResult {
  const UpdateDownloadFailure(this.message);

  final String message;
}

/// 用户取消。
class UpdateDownloadCancelled extends UpdateDownloadResult {
  const UpdateDownloadCancelled();
}

// ---------------------------------------------------------------- 安装

/// [Updater.install] 的结果。
sealed class UpdateInstallResult {
  const UpdateInstallResult();
}

/// 安装流程已启动。
class UpdateInstallStarted extends UpdateInstallResult {
  const UpdateInstallStarted(this.message, {this.logPath});

  final String message;

  /// 重启助手的日志路径（桌面端）。失败时用户可以在这里看到原因。
  final String? logPath;
}

/// 需要用户先授予权限（目前用于安卓的「安装未知应用」）。
class UpdateInstallPermissionRequired extends UpdateInstallResult {
  const UpdateInstallPermissionRequired(this.message);

  final String message;
}

/// 安装目录受保护，需要管理员授权才能写入（仅 Windows 桌面）。
///
/// 与安卓的 [UpdateInstallPermissionRequired] 语义相近——都要求用户先授权再
/// 重试——但触发的动作完全不同：安卓会把人送去系统设置里允许「安装未知应用」，
/// 这里会弹 Windows 的 UAC 同意框。因此必须是两种结果：合成一种会让界面把
/// 用户指向一个在本平台并不存在的设置项。
class UpdateInstallElevationRequired extends UpdateInstallResult {
  const UpdateInstallElevationRequired(this.message, {this.suggestedDir});

  final String message;

  /// 建议改用的**用户目录**安装位置，见 [suggestedUserInstallDir]。
  ///
  /// 提权能让这一次更新成功，但装在受保护目录会让**每一次**更新都要过 UAC。
  /// 给出这个路径是为了让用户有机会一次性摆脱它。
  final String? suggestedDir;
}

/// 安装无法进行，[message] 说明原因与手动替代方案。
class UpdateInstallFailure extends UpdateInstallResult {
  const UpdateInstallFailure(this.message);

  final String message;
}

/// 安装策略。
///
/// 抽成接口让「桌面生成什么脚本、启动了哪条命令、安卓怎么映射原生结果」都能
/// 在 Windows 开发机上被断言，而不必真的替换一次安装目录。
abstract class UpdateInstaller {
  const UpdateInstaller();

  /// [elevate] 表示用户已同意用管理员权限完成写入；**只有 Windows 桌面**会
  /// 用到它，其余实现忽略（安卓的授权走系统安装器，Linux 不自行提权）。
  Future<UpdateInstallResult> install({
    required UpdateInfo info,
    required File archive,
    required Directory stagingDir,
    bool elevate = false,
  });
}

/// 以**脱离父进程**的方式启动命令（父进程退出后它继续运行）。
abstract class ProcessStarter {
  const ProcessStarter();

  Future<bool> startDetached(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

/// 真实实现。
class RealProcessStarter implements ProcessStarter {
  const RealProcessStarter();

  @override
  Future<bool> startDetached(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    try {
      await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on Object {
      return false;
    }
  }
}

/// 重启助手脚本的文件名（不含扩展名）。写在暂存目录里，**不落进安装目录**。
const String relaunchScriptName = 'xvpn-relaunch';

/// 提权复制脚本的文件名（不含扩展名）。只在安装目录写不进去时才生成。
const String elevatedCopyScriptName = 'xvpn-elevate-copy';

/// 解压目录。两个 Windows 脚本（助手与提权复制）必须指向同一个地方，因此
/// 路径只在这里算一次——分头去拼字符串迟早会分叉，而分叉的表现是「提权复制
/// 报找不到文件」，很难从现象想到原因。
String _windowsExtractDir(String stagingDir) => '$stagingDir\\extract';

/// PowerShell 单引号字面量。
///
/// 用单引号而不是双引号：PowerShell 的双引号会做变量展开，路径里出现 `$`
/// 时会被悄悄改写；单引号里只有 `'` 需要转义（写成两个）。
String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// `Start-Process -ArgumentList` 的一个元素：单引号字面量，里面再套一层双引号。
///
/// 这个参数最后是要**拼成命令行**的，因此路径里的空格必须由双引号保护，否则
/// `C:\Users\Zhang San\AppData\...` 会被拆成两个参数，被启动的 PowerShell 会
/// 把后半截当成另一个选项。单引号内的双引号是字面量，不必转义。
String _psQuotedArg(String value) => "'\"${value.replaceAll("'", "''")}\"'";

/// POSIX shell 单引号字面量：`'` 以 `'\''` 脱出。
String _shQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// 一条「带路径」的 PowerShell 日志调用。
///
/// 路径**必须**经 [_psQuote] 处理后用字符串相加拼进去，不能直接塞进
/// `Write-Log '...'`：那个单引号字符串会被路径里的 `'` 提前结束，从这一行开始
/// 整份脚本语法就是坏的——表现为「Try 语句缺少 Catch/Finally」，而真正的原因
/// 在几十行之前。只有安装路径里恰好含单引号时才会出现（例如
/// `C:\Program Files\Bob's VPN`），因此很容易一直不被发现。
///
/// [prefix] 是固定文案，不能含 `"` 或 `$`。
String _psLogWithPath(String prefix, String path) =>
    'Write-Log ("$prefix" + ${_psQuote(path)})';

/// 生成 Windows 重启助手（PowerShell 脚本）。
///
/// 顺序是硬要求：**等待当前进程退出 → 解压到暂存目录 → 确认解压结果里有
/// 可执行文件 → 覆盖安装目录 → 重新启动**。先等待再替换，是因为运行中的
/// `xvpn.exe` 被占用时覆盖会失败；先确认再覆盖，是为了解压失败时保持原安装
/// 完好——绝不能把用户留在一个被替换了一半、无法启动的目录里。
///
/// [elevatedCopyScriptPath] 不为 null 时，「覆盖安装目录」那一步改由该脚本以
/// 管理员身份执行（会弹一次 UAC）。**只有这一步被提权**：助手自身仍是普通
/// 权限，因此最后重启的 XVPN 也是普通权限。
String buildWindowsRelaunchScript({
  required int pid,
  required String archivePath,
  required String stagingDir,
  required String installDir,
  required String launchPath,
  String? elevatedCopyScriptPath,
}) {
  final log = '$stagingDir\\xvpn-update.log';
  final extract = _windowsExtractDir(stagingDir);
  // 提权是把整个复制动作交给一个管理员进程，而不是让助手自己变成管理员。
  //
  // 这一点是这套流程里最要紧的决定。若反过来让助手以管理员运行，它 `Start-Process`
  // 出来的 XVPN 也会是管理员：一旦 UAC 是由**另一个**管理员账户确认的（标准用户
  // + 管理员凭据是常见配置），提权进程读的是那个账户的 `%LOCALAPPDATA%`，用户看
  // 到的就是「配置与凭据全部不见了」。把权限收窄到一条 `Copy-Item`，这一切都不会
  // 发生，也顺带不必去用「从提权进程降权启动」那种依赖 explorer 的取巧办法。
  final String copyStep = elevatedCopyScriptPath == null
      ? '''
  ${_psLogWithPath('覆盖安装目录 ', installDir)}
  Copy-Item -Path (Join-Path ${_psQuote(extract)} '*') -Destination ${_psQuote(installDir)} -Recurse -Force
'''
      : '''
  ${_psLogWithPath('以管理员身份覆盖安装目录 ', installDir)}
  # -Wait 让助手等到复制真正结束（并拿到退出码）；-PassThru 才能读到它。
  # 用户点「否」时 Start-Process 会抛异常（\$ErrorActionPreference = 'Stop' 已把
  # 它变成终止错误），由外层 catch 记进日志并重新拉起旧版本——不会留下一个
  # 复制到一半的安装目录，因为这时一条文件都还没复制。
  \$copy = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
    -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',${_psQuotedArg(elevatedCopyScriptPath)})
  if (\$copy.ExitCode -ne 0) { throw ('以管理员身份复制失败（退出码 ' + \$copy.ExitCode + '）') }
''';

  return '''
# XVPN 自动更新重启助手。由应用在运行时生成到暂存目录，仓库里没有这个文件。
\$ErrorActionPreference = 'Stop'
function Write-Log(\$message) {
  "\$(Get-Date -Format o) \$message" | Out-File -LiteralPath ${_psQuote(log)} -Append -Encoding utf8
}
try {
  Write-Log '等待主程序退出'
  Wait-Process -Id $pid -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 400

  Write-Log '解压安装包'
  if (Test-Path -LiteralPath ${_psQuote(extract)}) {
    Remove-Item -LiteralPath ${_psQuote(extract)} -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path ${_psQuote(extract)} | Out-Null
  Expand-Archive -LiteralPath ${_psQuote(archivePath)} -DestinationPath ${_psQuote(extract)} -Force

  if (-not (Test-Path -LiteralPath (Join-Path ${_psQuote(extract)} 'xvpn.exe'))) {
    throw '解压结果里没有 xvpn.exe，已取消替换'
  }
$copyStep
  Write-Log '重新启动'
  Start-Process -FilePath ${_psQuote(launchPath)} -WorkingDirectory ${_psQuote(installDir)}
} catch {
  Write-Log "更新失败：\$_"
  # 失败也不能让用户没有程序可用：至少把旧版本重新拉起来。
  try {
    Start-Process -FilePath ${_psQuote(launchPath)} -WorkingDirectory ${_psQuote(installDir)}
  } catch { }
} finally {
  # 只清中间产物，**保留日志**：提权那条路上用户点了「否」时，日志是他事后
  # 唯一能查到原因的入口（`UpdateInstallStarted.logPath` 指向的就是它）。
  Remove-Item -LiteralPath ${_psQuote(extract)} -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath ${_psQuote(archivePath)} -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
}
''';
}

/// 生成 Windows 提权复制脚本（以管理员身份运行）。
///
/// 只做一件事：把解压结果覆盖到安装目录。**不重启应用**——重启交给那个非提权的
/// 助手，这样 XVPN 不会以管理员身份运行（原因见 [buildWindowsRelaunchScript]）。
///
/// 失败必须以**非零退出码**收场：助手据此判定「复制没成功」，从而不去假装更新
/// 成功。
String buildWindowsElevatedCopyScript({
  required String stagingDir,
  required String installDir,
}) {
  final log = '$stagingDir\\xvpn-update.log';
  final extract = _windowsExtractDir(stagingDir);
  return '''
# XVPN 提权复制脚本。由更新助手以管理员身份启动（会弹一次 UAC）。
\$ErrorActionPreference = 'Stop'
function Write-Log(\$message) {
  "\$(Get-Date -Format o) \$message" | Out-File -LiteralPath ${_psQuote(log)} -Append -Encoding utf8
}
try {
  ${_psLogWithPath('以管理员身份覆盖安装目录 ', installDir)}
  # \$ErrorActionPreference = 'Stop' 让单个文件复制失败也中止整步：宁可整体失败
  # 并报错，也不要留下一个半新半旧的安装目录。
  Copy-Item -Path (Join-Path ${_psQuote(extract)} '*') -Destination ${_psQuote(installDir)} -Recurse -Force
  Write-Log '管理员复制完成'
  exit 0
} catch {
  Write-Log "提权复制失败：\$_"
  exit 1
}
''';
}

/// 启动 Windows 重启助手的命令。
List<String> windowsRelaunchCommand(String scriptPath) => <String>[
  'powershell.exe',
  '-NoProfile',
  '-NonInteractive',
  // 避免闪出一个控制台窗口。
  '-WindowStyle',
  'Hidden',
  // 脚本生成在临时目录，默认执行策略可能拒绝运行它。
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  scriptPath,
];

/// 生成 Linux 重启助手（POSIX sh 脚本）。
///
/// 与 Windows 同样的顺序要求；解压交给系统自带的 `unzip`（脚本所在的暂存
/// 目录是应用自己创建的，因此不需要任何特权）。
///
/// **已知限制**：如果应用被安装在只读的系统目录（`/usr/bin`、`/usr/lib`……），
/// 覆盖会失败；[DesktopUpdateInstaller] 在启动脚本前会先做写权限探测并如实
/// 拒绝，而不是留下一个坏掉的安装。
String buildLinuxRelaunchScript({
  required int pid,
  required String archivePath,
  required String stagingDir,
  required String installDir,
  required String launchPath,
}) {
  final log = '$stagingDir/xvpn-update.log';
  final extract = '$stagingDir/extract';
  return '''#!/bin/sh
# XVPN 自动更新重启助手。由应用在运行时生成到暂存目录，仓库里没有这个文件。
LOG=${_shQuote(log)}
log() { printf '%s %s\\n' "\$(date '+%Y-%m-%dT%H:%M:%S')" "\$1" >> "\$LOG"; }

log '等待主程序退出'
while kill -0 $pid 2>/dev/null; do
  sleep 1
done
sleep 1

EXTRACT=${_shQuote(extract)}
rm -rf "\$EXTRACT"
mkdir -p "\$EXTRACT"

log '解压安装包'
if command -v unzip >/dev/null 2>&1; then
  unzip -o -q ${_shQuote(archivePath)} -d "\$EXTRACT" >> "\$LOG" 2>&1
else
  log '系统里没有 unzip，无法自动解压；请手动解压安装包并覆盖安装目录'
fi

if [ ! -f "\$EXTRACT/xvpn" ]; then
  log '解压结果里没有 xvpn，已取消替换'
  ${_shQuote(launchPath)} >/dev/null 2>&1 &
  exit 1
fi

log '覆盖安装目录'
cp -a "\$EXTRACT/." ${_shQuote(installDir)}/ >> "\$LOG" 2>&1
chmod +x ${_shQuote(installDir)}/xvpn 2>/dev/null || true
chmod +x ${_shQuote(installDir)}/sing-box 2>/dev/null || true

log '重新启动'
${_shQuote(launchPath)} >/dev/null 2>&1 &

rm -f ${_shQuote(archivePath)}
rm -rf "\$EXTRACT"
rm -f "\$0"
''';
}

/// 启动 Linux 重启助手的命令。
///
/// 用 `/bin/sh 脚本` 而不是直接执行：这样脚本不需要可执行位（Dart 标准库
/// 没有 chmod），也避免挂载选项 `noexec` 带来的问题。
List<String> linuxRelaunchCommand(String scriptPath) => <String>[
  '/bin/sh',
  scriptPath,
];

/// Windows / Linux 的自替换安装。
///
/// 这里只负责生成并启动助手，**不替代当前进程**：调用方收到
/// [UpdateInstallStarted] 后应退出应用，助手会等它退出再替换并重启。
class DesktopUpdateInstaller implements UpdateInstaller {
  DesktopUpdateInstaller({
    required this.platform,
    required this.installDir,
    required this.launchPath,
    this.processStarter = const RealProcessStarter(),
    int? hostPid,
    this.writabilityProbe = probeDirWritable,
  }) : hostPid = hostPid ?? pid;

  final TargetPlatform platform;

  /// 安装目录，取自 `Platform.resolvedExecutable` 的父目录（与内核寻址同一处，
  /// 见 `singbox_runner.dart`）。
  final Directory installDir;

  /// 替换完成后要启动的可执行文件路径。
  final String launchPath;

  final ProcessStarter processStarter;

  /// 当前进程号，助手据此等待退出。
  final int hostPid;

  /// 「安装目录是否可写」的探测实现。
  ///
  /// 抽成注入点是因为它决定用户最终走哪条路（直接更新 / 提权更新 / 拒绝），
  /// 而真实的受保护目录在测试里造不出来：Windows 上要管理员才能改 ACL，CI 的
  /// Linux runner 也不是以 root 跑的。测试传 `(_) => true` 表示可写、
  /// `(_) => false` 表示装在受保护目录。
  final bool Function(Directory dir) writabilityProbe;

  @override
  Future<UpdateInstallResult> install({
    required UpdateInfo info,
    required File archive,
    required Directory stagingDir,
    bool elevate = false,
  }) async {
    if (!archive.existsSync()) {
      return UpdateInstallFailure('更新包不存在：${archive.path}');
    }
    final (blocked: UpdateInstallResult? blocked, elevate: bool elevated) =
        _preflight(elevate: elevate);
    if (blocked != null) return blocked;

    try {
      stagingDir.createSync(recursive: true);
    } on Object catch (e) {
      return UpdateInstallFailure('无法创建暂存目录：$e');
    }

    final bool isWindows = platform == TargetPlatform.windows;
    // 脚本与日志是**本机磁盘上**的真实文件，分隔符必须按宿主平台取；
    // 脚本内容里给目标平台用的分隔符由 buildXxxRelaunchScript 自己负责。
    //
    // 这里曾经用目标平台的分隔符来拼宿主路径，在 Windows 上恰好等价（二者都是
    // `\`）因此长期没暴露；在 Linux 上执行 Windows 安装策略时，脚本会被写成一个
    // 名为 `staging\xvpn-relaunch.ps1` 的文件（反斜杠成了文件名的一部分），
    // 实际路径 `staging/xvpn-relaunch.ps1` 并不存在——CI 上跑双平台测试时抓到。
    final String separator = Platform.pathSeparator;

    // 提权复制脚本只在需要提权时才生成：它存在的意义就是被 Start-Process
    // -Verb RunAs 拉起来。多写一个用不上的脚本会让人以为提权路径被走过了。
    File? copyScript;
    if (elevated && isWindows) {
      copyScript = File(
        '${stagingDir.path}$separator$elevatedCopyScriptName.ps1',
      );
      // 与主脚本同样的理由要加 UTF-8 BOM：PowerShell 5.1 没有它就会按 ANSI
      // 读，脚本里的中文日志会变成乱码——而用户要读的正是这些中文。
      final String copySource = buildWindowsElevatedCopyScript(
        stagingDir: stagingDir.path,
        installDir: installDir.path,
      );
      try {
        copyScript.writeAsStringSync('\uFEFF$copySource', flush: true);
      } on Object catch (e) {
        return UpdateInstallFailure('无法写入提权复制脚本：$e');
      }
    }

    final File script = File(
      '${stagingDir.path}$separator$relaunchScriptName.${isWindows ? 'ps1' : 'sh'}',
    );
    final String source = isWindows
        ? buildWindowsRelaunchScript(
            pid: hostPid,
            archivePath: archive.path,
            stagingDir: stagingDir.path,
            installDir: installDir.path,
            launchPath: launchPath,
            elevatedCopyScriptPath: copyScript?.path,
          )
        : buildLinuxRelaunchScript(
            pid: hostPid,
            archivePath: archive.path,
            stagingDir: stagingDir.path,
            installDir: installDir.path,
            launchPath: launchPath,
          );
    try {
      // Windows 的 PowerShell 5.1 在没有 BOM 时按系统 ANSI 代码页读取 .ps1，
      // 脚本里的中文（日志与失败原因）会变成乱码——而出错时用户要读的正是
      // 这些中文信息。显式加 UTF-8 BOM 让它按 UTF-8 解码。
      final String payload = isWindows ? '\uFEFF$source' : source;
      script.writeAsStringSync(payload, flush: true);
    } on Object catch (e) {
      return UpdateInstallFailure('无法写入更新脚本：$e');
    }

    final command = isWindows
        ? windowsRelaunchCommand(script.path)
        : linuxRelaunchCommand(script.path);
    final started = await processStarter.startDetached(
      command.first,
      command.sublist(1),
      workingDirectory: stagingDir.path,
    );
    if (!started) {
      return UpdateInstallFailure(
        '无法启动更新程序。请手动解压 ${archive.path} 并覆盖安装目录 ${installDir.path}。',
      );
    }
    // 提权那次要在文案里说清楚「授权才会动手」：脚本确实已经跑起来了，但真正
    // 的复制要等用户在 UAC 上点「是」——否则用户会以为更新已经在进行。
    final String message = copyScript == null
        ? '更新程序已启动。请退出 XVPN，它会在应用退出后自动替换文件并重新启动。'
        : '更新程序已启动。请退出 XVPN；它会在应用退出后弹出一次管理员授权，'
              '获得授权才会替换文件（取消则不做任何改动），随后自动重新启动。';
    return UpdateInstallStarted(
      message,
      logPath: '${stagingDir.path}${separator}xvpn-update.log',
    );
  }

  /// 安装前的可行性检查。
  ///
  /// 返回 `(blocked, elevate)`：`blocked` 非空表示直接把这个结果回给界面；
  /// 否则继续，并用 `elevate` 决定「覆盖安装目录」这一步是否交给管理员执行。
  ({UpdateInstallResult? blocked, bool elevate}) _preflight({
    required bool elevate,
  }) {
    if (!installDir.existsSync()) {
      return (
        blocked: UpdateInstallFailure(
          '找不到安装目录（${installDir.path}），无法自动更新。请手动下载新版本解压覆盖。',
        ),
        elevate: false,
      );
    }
    if (writabilityProbe(installDir)) {
      // 目录可写：即便界面传了 elevate 也不要提权。用户点过一次「以管理员身份
      // 更新」之后重试，而目录其实已经可写（例如他顺手把安装目录搬到了用户
      // 目录），这时弹 UAC 是纯粹的打扰。
      return (blocked: null, elevate: false);
    }

    if (platform == TargetPlatform.windows) {
      // 受保护目录 + 用户已同意授权：把复制那一步交给管理员进程。
      if (elevate) return (blocked: null, elevate: true);
      return (
        blocked: UpdateInstallElevationRequired(
          '当前安装在受保护目录（${installDir.path}），写入它需要管理员权限。',
          suggestedDir: suggestedUserInstallDir(platform),
        ),
        elevate: false,
      );
    }

    // Linux 不自行提权。`/usr/bin`、`/usr/lib` 这些路径归包管理器所有：绕过
    // dpkg/rpm 直接覆盖文件会破坏包数据库，而且下一次包升级又会把它们改回去。
    // 唯一诚实的做法是拒绝，并给出两条真实可走的路。
    return (
      blocked: UpdateInstallFailure(
        '当前安装在只读位置（${installDir.path}），自动更新需要写权限。'
        '请用系统包管理器更新；或把 XVPN 解压到用户目录'
        '（${suggestedUserInstallDir(platform)}）后即可自动更新。',
      ),
      elevate: false,
    );
  }
}

/// 与原生安装器对话的最小接口。
///
/// 抽出来是为了让「权限被拒 → 引导去系统设置」「原生报错 → 中文提示」这两条
/// 分支能在桌面测试里被断言；真实安装只能在真机上完成。
abstract class ApkInstallChannel {
  const ApkInstallChannel();

  /// 返回原生侧的 status：`launched` 或 `permission_required`。
  Future<String?> installApk(String path);
}

/// 复用既有的平台通道。
///
/// 通道名刻意保持 `com.xvpn.xvpn/vpn`（虽然包名已改成 `net.lusida.xvpn`）：
/// 它是 Dart 与 `MainActivity.kt` 之间的存量契约，改名要两端同时动，收益为零。
class MethodChannelApkInstallChannel implements ApkInstallChannel {
  const MethodChannelApkInstallChannel();

  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/vpn');

  @override
  Future<String?> installApk(String path) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'installApk',
      <String, Object?>{'path': path},
    );
    final status = result?['status'];
    return status is String ? status : null;
  }
}

/// 安卓：APK 已由引擎下载并校验，这里交给系统安装器。
///
/// 安装界面由系统弹出，用户仍需确认一次——应用不会、也无法静默安装。
class AndroidUpdateInstaller implements UpdateInstaller {
  const AndroidUpdateInstaller({
    this.channel = const MethodChannelApkInstallChannel(),
  });

  final ApkInstallChannel channel;

  @override
  Future<UpdateInstallResult> install({
    required UpdateInfo info,
    required File archive,
    required Directory stagingDir,
    bool elevate = false,
  }) async {
    if (!archive.existsSync()) {
      return UpdateInstallFailure('安装包不存在：${archive.path}');
    }
    final String? status;
    try {
      status = await channel.installApk(archive.path);
    } on PlatformException catch (e) {
      return UpdateInstallFailure('无法启动系统安装器：${e.message ?? e.code}');
    } on Object catch (e) {
      return UpdateInstallFailure('无法启动系统安装器：$e');
    }
    switch (status) {
      case 'launched':
        return const UpdateInstallStarted('已交给系统安装器，请在弹出的界面里确认安装。');
      case 'permission_required':
        return const UpdateInstallPermissionRequired(
          '需要先允许 XVPN 安装未知应用。已为你打开系统设置，授权后请返回重试。',
        );
      default:
        return const UpdateInstallFailure('系统安装器没有返回有效结果，请到发布页手动下载安装。');
    }
  }
}

/// 未接入自动更新的平台。
class UnsupportedUpdateInstaller implements UpdateInstaller {
  const UnsupportedUpdateInstaller();

  @override
  Future<UpdateInstallResult> install({
    required UpdateInfo info,
    required File archive,
    required Directory stagingDir,
    bool elevate = false,
  }) async => const UpdateInstallFailure('当前平台不支持自动安装，请到发布页手动下载。');
}

/// 按平台选择默认安装策略。
UpdateInstaller defaultUpdateInstaller(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return DesktopUpdateInstaller(
        platform: platform,
        // 与内核寻址同一处：安装目录就是可执行文件所在目录。
        installDir: File(Platform.resolvedExecutable).parent,
        launchPath: Platform.resolvedExecutable,
        processStarter: const RealProcessStarter(),
      );
    case TargetPlatform.android:
      return const AndroidUpdateInstaller();
    default:
      return const UnsupportedUpdateInstaller();
  }
}

// ---------------------------------------------------------------- 引擎

/// 应用内自动更新引擎。
///
/// 职责划分：本类只做「查询 → 下载并校验 → 启动安装」三步，每一步都返回
/// 结构化结果，由界面决定何时向用户确认。**任何一步都不会静默安装**，
/// 每一步的失败都变成可直接展示的中文消息，而不是未处理的异常。
class Updater {
  Updater({
    required this.platform,
    required this.currentVersion,
    UpdateHttpClient? http,
    UpdateInstaller? installer,
    Directory? stagingRoot,
    this.repoUrl = kRepoUrl,
    this.requestTimeout = const Duration(seconds: 30),
    this.stallTimeout = const Duration(seconds: 60),
  }) : _http = http ?? RealUpdateHttpClient(),
       installer = installer ?? defaultUpdateInstaller(platform),
       stagingRoot = stagingRoot ?? defaultUpdateStagingDir(platform);

  /// 用当前平台与构建期注入的版本号构造。[currentVersion] 默认取
  /// `app/lib/version.dart` 的 [appVersion]，与设置页显示的是同一个值。
  factory Updater.forCurrentPlatform({
    String? currentVersion,
    UpdateHttpClient? http,
    UpdateInstaller? installer,
    Directory? stagingRoot,
    String repoUrl = kRepoUrl,
  }) {
    final TargetPlatform platform = defaultTargetPlatform;
    return Updater(
      platform: platform,
      currentVersion: currentVersion ?? appVersion,
      http: http,
      installer: installer,
      stagingRoot: stagingRoot,
      repoUrl: repoUrl,
    );
  }

  final TargetPlatform platform;
  final String currentVersion;
  final String repoUrl;
  final Duration requestTimeout;

  /// 两个数据块之间的最长等待。用它兜住「连接建立了但服务器不再发数据」——
  /// 没有它，下载会永远挂在进度条上。
  final Duration stallTimeout;

  final UpdateHttpClient _http;
  final UpdateInstaller installer;
  final Directory stagingRoot;

  /// 当前平台对应的更新平台；不支持时为 null。
  UpdatePlatform? get updatePlatform => updatePlatformFor(platform);

  /// 查询最新发布并与 [currentVersion] 比较。
  Future<UpdateCheckResult> checkForUpdate() async {
    final target = updatePlatform;
    if (target == null) {
      return const UpdateCheckFailure('当前平台不支持自动更新，请到发布页手动下载。');
    }
    if (ReleaseVersion.tryParse(currentVersion) == null) {
      return UpdateCheckFailure('当前版本号「$currentVersion」格式异常，无法比较。');
    }

    final Uri api;
    try {
      api = latestReleaseApiUri(repoUrl: repoUrl);
    } on Object catch (e) {
      return UpdateCheckFailure('更新地址无效：$e');
    }

    final UpdateHttpResponse response;
    try {
      response = await _http.send(api).timeout(requestTimeout);
    } on TimeoutException {
      return const UpdateCheckFailure('连接更新服务器超时，请检查网络后重试。');
    } on SocketException {
      return const UpdateCheckFailure('无法连接更新服务器，请检查网络后重试。');
    } on HandshakeException {
      return const UpdateCheckFailure('与更新服务器建立安全连接失败，请检查网络或系统时间。');
    } on http.ClientException {
      return const UpdateCheckFailure('无法连接更新服务器，请检查网络后重试。');
    } on Object catch (e) {
      return UpdateCheckFailure('检查更新失败：$e');
    }

    final failure = describeHttpFailure(
      response.statusCode,
      response.header('x-ratelimit-remaining'),
    );
    if (failure != null) return UpdateCheckFailure('检查更新失败：$failure');

    final String text;
    try {
      text = await _readBodyText(response);
    } on Object catch (e) {
      return UpdateCheckFailure('读取更新信息失败：${_networkReason(e)}');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const UpdateCheckFailure('更新信息解析失败（服务器返回的不是有效 JSON）。');
    }
    final ReleaseInfo? release = ReleaseInfo.tryParse(decoded);
    if (release == null) {
      return const UpdateCheckFailure('更新信息解析失败（缺少版本号等必要字段）。');
    }
    if (ReleaseVersion.tryParse(release.tag) == null) {
      return UpdateCheckFailure('无法识别最新版本号「${release.tag}」，请到发布页手动确认。');
    }
    if (!isNewerVersion(release.tag, currentVersion)) {
      return UpdateNotAvailable(
        currentVersion: currentVersion,
        latestVersion: release.version,
      );
    }

    final asset = selectAsset(release.assets, target, release.version);
    if (asset == null) {
      return UpdateCheckFailure(
        '最新版本 ${release.version} 没有适用于 ${updatePlatformLabel(target)} 的安装包，'
        '请到发布页手动下载。',
      );
    }
    final checksums = selectChecksumsAsset(release.assets);
    if (checksums == null) {
      return const UpdateCheckFailure(
        '最新发布缺少 SHA256SUMS.txt，无法校验安装包完整性，已中止更新。',
      );
    }

    return UpdateAvailable(
      UpdateInfo(
        tag: release.tag,
        version: release.version,
        platform: target,
        assetName: asset.name,
        assetUri: asset.downloadUrl,
        assetSize: asset.size,
        checksumsName: checksums.name,
        checksumsUri: checksums.downloadUrl,
        pageUri: release.pageUrl,
        notes: release.notes,
      ),
    );
  }

  /// 下载安装包到暂存目录并校验 SHA-256。
  ///
  /// 先取 `SHA256SUMS.txt`，没有记录就不开始下载大文件；下载过程中边写盘边
  /// 计算摘要；只有摘要匹配才返回 [UpdateDownloaded]。校验失败、网络失败、
  /// 用户取消都会删除半成品，不留下一个可能被误当成安装包的文件。
  Future<UpdateDownloadResult> download(
    UpdateInfo info, {
    DownloadProgressCallback? onProgress,
    UpdateCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const UpdateDownloadCancelled();
    }

    // 1) 校验文件必须可用，否则后面下完也没法验证。
    final Map<String, String> checksums;
    try {
      final response = await _http.send(info.checksumsUri).timeout(requestTimeout);
      final failure = describeHttpFailure(
        response.statusCode,
        response.header('x-ratelimit-remaining'),
      );
      if (failure != null) {
        return UpdateDownloadFailure('下载校验文件失败：$failure');
      }
      checksums = parseChecksums(await _readBodyText(response));
    } on TimeoutException {
      return const UpdateDownloadFailure('下载校验文件超时，请检查网络后重试。');
    } on Object catch (e) {
      return UpdateDownloadFailure('下载校验文件失败：${_networkReason(e)}');
    }
    if (checksums.isEmpty) {
      return const UpdateDownloadFailure('SHA256SUMS.txt 内容无法解析，已中止更新。');
    }

    // 2) 下载安装包，边下边算摘要。
    final Directory downloads = Directory(
      '${stagingRoot.path}${Platform.pathSeparator}downloads',
    );
    try {
      downloads.createSync(recursive: true);
    } on Object catch (e) {
      return UpdateDownloadFailure('无法创建暂存目录：$e');
    }
    final File target = File(
      '${downloads.path}${Platform.pathSeparator}${info.assetName}',
    );
    final hasher = Sha256();
    var received = 0;
    String? downloadError;
    var cancelled = false;

    final IOSink sink;
    try {
      sink = target.openWrite();
    } on Object catch (e) {
      return UpdateDownloadFailure('无法写入暂存文件：$e');
    }
    try {
      final response = await _http.send(info.assetUri).timeout(requestTimeout);
      final failure = describeHttpFailure(
        response.statusCode,
        response.header('x-ratelimit-remaining'),
      );
      if (failure != null) {
        downloadError = '下载安装包失败：$failure';
      } else {
        final total = response.contentLength ?? info.assetSize;
        onProgress?.call(0, total);
        await for (final chunk in response.body.timeout(stallTimeout)) {
          if (cancellation?.isCancelled ?? false) {
            cancelled = true;
            break;
          }
          sink.add(chunk);
          hasher.update(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      }
    } on TimeoutException {
      downloadError = '下载安装包超时，请检查网络后重试。';
    } on Object catch (e) {
      downloadError = '下载安装包失败：${_networkReason(e)}';
    } finally {
      await _closeQuietly(sink);
    }

    if (cancelled || (cancellation?.isCancelled ?? false)) {
      _deleteQuietly(target);
      return const UpdateDownloadCancelled();
    }
    if (downloadError != null) {
      _deleteQuietly(target);
      return UpdateDownloadFailure(downloadError);
    }

    // 3) 只有摘要匹配才交给安装步骤。
    final actual = hasher.digestHex();
    final verification = verifyChecksum(
      checksums: checksums,
      assetName: info.assetName,
      actualSha256: actual,
    );
    switch (verification) {
      case ChecksumVerified():
        return UpdateDownloaded(target, actual);
      case ChecksumEntryMissing(assetName: final name):
        _deleteQuietly(target);
        return UpdateDownloadFailure(
          'SHA256SUMS.txt 里没有 $name 的记录，无法校验完整性，已中止更新。',
        );
      case ChecksumMismatch(expected: final expected, actual: final actual):
        _deleteQuietly(target);
        return UpdateDownloadFailure(
          '安装包校验失败（期望 $expected，实际 $actual），已中止更新。请稍后重试。',
        );
    }
  }

  /// 启动安装流程。桌面端会生成重启助手并返回 [UpdateInstallStarted]，
  /// 调用方收到后应退出应用；安卓端会唤起系统安装器。
  ///
  /// [elevate] 只在 Windows 桌面有意义：安装目录受保护时，界面会先收到
  /// [UpdateInstallElevationRequired]，用户确认后再带着 `elevate: true` 重试。
  Future<UpdateInstallResult> install(
    UpdateInfo info,
    File artifact, {
    bool elevate = false,
  }) => installer.install(
    info: info,
    archive: artifact,
    stagingDir: stagingRoot,
    elevate: elevate,
  );

  /// 释放内部 HTTP 客户端。
  ///
  /// 只在 [Updater] 自己创建了客户端时才需要释放；注入的替身由调用方负责。
  /// 界面持有 Updater 的实例应在销毁时调用这里，否则默认实现里的
  /// `HttpClient` 会一直挂着连接。
  void dispose() {
    final client = _http;
    if (client is RealUpdateHttpClient) client.close();
  }

  Future<String> _readBodyText(UpdateHttpResponse response) =>
      response.body.timeout(stallTimeout).transform(utf8.decoder).join();

  Future<void> _closeQuietly(IOSink sink) async {
    try {
      await sink.close();
    } on Object {
      // 已经关掉、或写入过程中出错：不影响最终结论。
    }
  }

  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // 删不掉不影响结论。
    }
  }

  String _networkReason(Object error) {
    if (error is TimeoutException) return '连接更新服务器超时，请检查网络后重试。';
    if (error is SocketException) return '无法连接更新服务器，请检查网络后重试。';
    if (error is HandshakeException) {
      return '与更新服务器建立安全连接失败，请检查网络或系统时间。';
    }
    if (error is http.ClientException) {
      return '无法连接更新服务器，请检查网络后重试。';
    }
    return error.toString();
  }
}
