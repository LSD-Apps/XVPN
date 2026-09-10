import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统代理接管。
///
/// Windows 上没有管理员权限也能设置「系统代理」，浏览器与绝大多数软件会立即
/// 走本地内核的混合入站端口。相对于 TUN，这是零权限、零驱动、最不容易出错的
/// 接管方式，因此作为默认。
///
/// 原生侧会在写入前先备份用户原有的代理设置，断开时还原；备份放在注册表里，
/// 这样即使进程被强杀，下次启动也能恢复（见 [recoverIfNeeded]）。
class SystemProxy {
  SystemProxy._();

  /// 与窗口控制共用同一个平台通道，方法名见 flutter_window.cpp。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/platform');

  static bool get supported => defaultTargetPlatform == TargetPlatform.windows;

  /// 设置系统代理。[host] 与 [port] 指向本地内核的混合入站。
  static Future<bool> set({required String host, required int port}) async {
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

  /// 还原系统代理设置。
  static Future<bool> clear() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('clearSystemProxy') ?? false;
    } on Object {
      return false;
    }
  }

  /// 是否存在上次未还原的备份。
  static Future<bool> hasBackup() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasProxyBackup') ?? false;
    } on Object {
      return false;
    }
  }

  /// 启动时调用：若上次异常退出留下了备份，先把系统代理恢复回去。
  ///
  /// 这是必须的兜底——否则用户会遇到「所有网站都打不开」且不知道为什么。
  static Future<bool> recoverIfNeeded() async {
    if (!await hasBackup()) return false;
    return clear();
  }
}
