import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 安卓侧原生通道 `com.xvpn.xvpn/vpn` 的**唯一**方法回调宿主。
///
/// 为什么需要这一层：Flutter 的 `MethodChannel` 每条通道**只保留一个** handler，
/// `setMethodCallHandler` 是**替换**而不是追加。被替换掉的那条推送不会报错、
/// 也不会落日志，只是永远不再到达——`window_controls.dart` 里为此专门留过一句
/// 「两个 setMethodCallHandler 的话，先注册的那条推送会被静默丢弃」。
///
/// 而这条通道上恰好有两类互不相干的推送：
///
///   * **原生分享/打开进来的配置**（`sharedConfigAvailable`）——`main.dart` 关心；
///   * **内核日志**（`coreLog`）——`AndroidVpnCore` 关心，失败归因靠它。
///
/// 此前两边各自 `setMethodCallHandler`，于是**谁后注册谁生效**：应用只要连接过
/// 一次，`AndroidVpnCore` 就装上了自己的 handler，而它只认 `coreLog`，其余一律
/// 忽略。结果是「把配置分享到幽门」从那一刻起彻底失效——没有确认框、没有报错、
/// 什么都没有。冷启动时还能成功，仅仅因为那时还没有人把它顶掉。
///
/// 这个缺陷是在真机上抓到的：同一个 `vless://` 链接，冷启动弹出确认框、
/// 应用已在运行时什么都不发生。`test/android_channel_test.dart` 守住了它。
///
/// 所以 handler 只在 [addHandler] 第一次被调用时装**一次**；此后每个兴趣方都会
/// 收到每一条推送，各自忽略自己不关心的那些。
class AndroidChannel {
  AndroidChannel._();

  /// 与原生 `MethodChannel("com.xvpn.xvpn/vpn")` 同名。
  ///
  /// 多个 `MethodChannel` 实例共用同一个名字是安全的：它们共享底层 messenger，
  /// 会冲突的只有 `setMethodCallHandler`。
  static const MethodChannel channel = MethodChannel('com.xvpn.xvpn/vpn');

  static final List<Future<void> Function(MethodCall)> _handlers =
      <Future<void> Function(MethodCall)>[];

  static bool _installed = false;

  /// 已登记的兴趣方数量。测试用它确认没有重复登记。
  @visibleForTesting
  static int get handlerCount => _handlers.length;

  /// 登记一个兴趣方，返回注销用的回调。
  ///
  /// 注销不是可有可无的：`AndroidVpnCore` 在测试里会被构造很多次，不注销就会
  /// 往列表里越堆越多，而每条推送都要把它们全跑一遍。
  static void Function() addHandler(
    Future<void> Function(MethodCall) handler,
  ) {
    _handlers.add(handler);
    if (!_installed) {
      _installed = true;
      channel.setMethodCallHandler(dispatch);
    }
    return () => _handlers.remove(handler);
  }

  /// 把一条原生调用分发给全部兴趣方。
  ///
  /// 单独暴露是为了让测试能直接驱动它：这个缺陷的症状（handler 被顶掉）不需要
  /// 真的起一条平台通道就能断言，而且断言得更准——它测的正是「两个兴趣方都能
  /// 收到同一条推送」。
  @visibleForTesting
  static Future<void> dispatch(MethodCall call) async {
    // 复制一份再遍历：handler 在处理过程中注销自己（或登记新的）不该影响本轮。
    for (final handler
        in List<Future<void> Function(MethodCall)>.of(_handlers)) {
      await handler(call);
    }
  }

  /// 仅供测试：清空登记，让每个用例从干净状态开始。
  @visibleForTesting
  static void resetForTesting() {
    _handlers.clear();
    _installed = false;
  }
}
