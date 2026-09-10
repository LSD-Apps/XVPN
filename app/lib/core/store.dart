import 'dart:convert';
import 'dart:io';

/// 本地持久化。
///
/// 在这之前应用**完全没有持久化**：导入的配置只活在内存里，进程一重启就没了，
/// 用户每次打开都要重新导入一遍——与「傻瓜式」的目标直接冲突。
/// 安卓上后果更明显：隧道跑在前台服务里，界面进程被系统回收后隧道还在跑，
/// 重新打开界面却退回「导入配置」的空状态，看起来像「配置丢了但流量还在走」。
///
/// 存的东西只有三类，都是「用户不想再填第二遍」的信息：
///   * 导入过的配置原文（解析结果由原文重新推导，不存派生数据）；
///   * 当前选中的是哪一份；
///   * 用户改过的设置项。
///
/// 刻意不引入 `shared_preferences`：目录由调用方给出（桌面端用
/// `%LOCALAPPDATA%\XVPN`，安卓用原生侧的 `filesDir`），
/// 这样没有新依赖，两个平台也能共用同一份实现。
class AppStore {
  AppStore(this.directory);

  /// 读写目录。不存在时由 [save] 自动创建。
  final Directory directory;

  static const String fileName = 'config.json';

  /// 版本号。将来结构变化时用它决定要不要迁移，而不是靠猜字段。
  static const int schemaVersion = 1;

  File get file =>
      File('${directory.path}${Platform.pathSeparator}$fileName');

  /// 读取。文件不存在或内容损坏时返回空表——
  /// 配置读不出来不应该让应用起不来，最坏情况就是回到「重新导入」。
  Map<String, Object?> load() {
    try {
      if (!file.existsSync()) return <String, Object?>{};
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return <String, Object?>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return <String, Object?>{};
      final version = decoded['version'];
      if (version is! int || version > schemaVersion) return <String, Object?>{};
      return decoded;
    } on Object {
      return <String, Object?>{};
    }
  }

  /// 写入。返回是否成功——调用方不需要处理失败，但测试要断言。
  bool save(Map<String, Object?> data) {
    try {
      directory.createSync(recursive: true);
      final payload = <String, Object?>{'version': schemaVersion, ...data};
      // 先写临时文件再改名：写入过程中被杀掉也不会留下半截 JSON，
      // 否则下次启动会读到损坏的文件从而丢掉全部配置。
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(payload), flush: true);
      tmp.renameSync(file.path);
      return true;
    } on Object {
      return false;
    }
  }

  void clear() {
    try {
      if (file.existsSync()) file.deleteSync();
      final tmp = File('${file.path}.tmp');
      if (tmp.existsSync()) tmp.deleteSync();
    } on Object {
      // 清理失败无所谓：下次保存会覆盖。
    }
  }

  /// 桌面端的默认目录：`%LOCALAPPDATA%\XVPN`，与规则库同一处。
  static Directory defaultDesktopDir() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory('$base${Platform.pathSeparator}XVPN');
  }
}
