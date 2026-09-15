import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/android_channel.dart';

/// 守住一个真机上抓到的缺陷：**应用连接过一次之后，「把配置分享到幽门」就彻底
/// 失效了**——没有确认框、没有报错、什么都没有；冷启动时却完全正常。
///
/// 根因是 Flutter 的 `MethodChannel` 每条通道只保留一个 handler，
/// `setMethodCallHandler` 是**替换**：`main.dart` 为分享登记了一条，
/// `AndroidVpnCore` 连接时又为内核日志登记了一条，后者把前者顶掉，而它只认
/// `coreLog`，`sharedConfigAvailable` 从此无人处理。
///
/// 所以这里的断言不是「某函数被调用」，而是**「两个兴趣方都能收到同一条推送」**
/// ——这正是旧实现做不到的那一件事。
void main() {
  // 要先有 binding：[AndroidChannel.addHandler] 会真的去
  // `channel.setMethodCallHandler`，没有 binary messenger 时那会直接断言失败。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AndroidChannel.resetForTesting);
  tearDown(AndroidChannel.resetForTesting);

  test('内核日志的兴趣方登记之后，分享的兴趣方仍然收得到推送', () async {
    final shares = <String>[];
    AndroidChannel.addHandler((MethodCall call) async {
      if (call.method == 'sharedConfigAvailable') shares.add('consumed');
    });

    // 模拟 AndroidVpnCore 在连接时登记自己的兴趣。旧实现里，这一步会把上面那条
    // 换掉——分享从此静默失效。
    final coreLogs = <String>[];
    AndroidChannel.addHandler((MethodCall call) async {
      if (call.method == 'coreLog') coreLogs.add(call.arguments as String);
    });

    await AndroidChannel.dispatch(const MethodCall('sharedConfigAvailable'));
    await AndroidChannel.dispatch(const MethodCall('coreLog', 'kernel line'));

    expect(
      shares,
      <String>['consumed'],
      reason: '登记内核日志之后分享推送被吞掉了——用户看到的是「分享进来没反应」',
    );
    expect(coreLogs, <String>['kernel line']);
  });

  test('注销之后不再收到推送', () async {
    final seen = <String>[];
    final dispose = AndroidChannel.addHandler((MethodCall call) async {
      seen.add(call.method);
    });

    await AndroidChannel.dispatch(const MethodCall('a'));
    dispose();
    await AndroidChannel.dispatch(const MethodCall('b'));

    expect(seen, <String>['a']);
    expect(AndroidChannel.handlerCount, 0);
  });

  test('同一个兴趣方只登记一次，推送不会被处理两遍', () async {
    var count = 0;
    void Function()? subscription;
    void subscribe() {
      subscription ??= AndroidChannel.addHandler((MethodCall call) async {
        count++;
      });
    }

    subscribe();
    subscribe();
    subscribe();
    expect(AndroidChannel.handlerCount, 1);

    await AndroidChannel.dispatch(const MethodCall('coreLog', 'x'));
    expect(count, 1, reason: '重复登记会让同一条内核日志被处理多遍');

    subscription!.call();
  });
}
