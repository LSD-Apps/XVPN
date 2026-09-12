import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统代理的接管与还原。
///
/// 抽成接口（而不是直接调静态方法）是为了让「接管 → 还原」这对动作的**配对关系**
/// 能被测试：系统代理是全局设置，一旦接管了却没还原，用户关掉应用后所有网站都
/// 打不开，而现象与隧道毫无关系——没人会想到去代理设置里找原因。这条路径此前
/// 只能靠读代码确认，而它恰恰是最不能出错的一处。
///
/// 与 [DnsResolver] 同一个思路：真实实现走平台通道，测试注入替身。
abstract class SystemProxyController {
  /// 接管系统代理。[host] 与 [port] 指向本地内核的混合入站。
  ///
  /// 返回 false 表示没能接管（非 Windows 平台、被策略锁定等），
  /// 调用方据此决定要不要提示用户。
  Future<bool> set({required String host, required int port});

  /// 还原系统代理。返回 false 表示**还原失败**——此时用户的网络仍然是坏的，
  /// 调用方必须把这件事说出来，而不是静默继续。
  Future<bool> clear();

  /// 启动时调用：若上次异常退出留下了备份，先把系统代理恢复回去。
  Future<bool> recoverIfNeeded();
}

/// Windows 上的真实实现。
///
/// 原生侧会在写入前先备份用户原有的代理设置，断开时还原；备份放在注册表里，
/// 这样即使进程被强杀，下次启动也能恢复（见 [recoverIfNeeded]）。
class SystemProxy implements SystemProxyController {
  const SystemProxy();

  /// 与窗口控制共用同一个平台通道，方法名见 flutter_window.cpp。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/platform');

  static bool get supported => defaultTargetPlatform == TargetPlatform.windows;

  @override
  Future<bool> set({required String host, required int port}) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setSystemProxy',
            '$host:$port',
          ) ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('clearSystemProxy') ?? false;
    } on Object {
      return false;
    }
  }

  /// 是否存在上次未还原的备份。
  Future<bool> hasBackup() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasProxyBackup') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> recoverIfNeeded() async {
    if (!await hasBackup()) return false;
    return clear();
  }
}
