import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

/// 「开机自动启动」的原生桥。
///
/// **这一项的事实只在系统里**，不在应用的存档里：Windows 上它是
/// `HKCU\...\CurrentVersion\Run` 下的一项，用户在「任务管理器 → 启动」或
/// 「设置 → 应用 → 启动」里随时能改，我们无从得知。因此这里的每个方法都直接问
/// 原生，而不是读一份自己维护的副本。
///
/// Windows 的原生实现在 `windows/runner/auto_start.cc`。
///
/// 安卓与 Linux 没有这一项：[supported] 为 false，设置页**不显示**这一行。
/// 显示一个拨了不会有任何效果的开关，比没有这个开关更糟。
class AutoStartService {
  AutoStartService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.xvpn.xvpn/platform');

  final MethodChannel _channel;

  /// 当前平台是否可能支持随系统启动。
  ///
  /// 这是**平台推断**，真正的结论要看 [querySupported]——原生会按自己的实现
  /// 如实回答（Linux 尚未落地）。
  static bool get platformSupported =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// 问原生：这一项在当前形态下能不能用。
  ///
  /// Linux runner 目前没有实现（届时随 XDG autostart 一起落地），通道会返回
  /// MissingPluginException ——那种情况下如实回答 false，而不是假装能用。
  Future<bool> querySupported() async {
    if (!platformSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('autoStartSupported') ?? false;
    } on Object {
      return false;
    }
  }

  /// 问原生：系统里现在是不是真的会随开机启动。
  ///
  /// 失败时返回 null 而不是 false：**「读不到」与「没开」必须区分得开**——
  /// 前者不该让界面显示一个可能不实的「已关闭」，界面的做法是保留上一次的
  /// 已知状态。
  Future<bool?> query() async {
    if (!platformSupported) return null;
    try {
      return await _channel.invokeMethod<bool>('getAutoStart');
    } on Object {
      return null;
    }
  }

  /// 请原生写入新状态。返回「请求是否被受理」。
  ///
  /// 刻意**不把这里的返回值当成最终结果**：写进去了也不等于「开机真的会启动」
  /// ——值可能不指向当前安装路径（见 windows/runner/auto_start.cc 的判据），
  /// 也可能被系统策略挡住。最终状态由原生回读后经 `autoStartChanged` 推来
  /// （见 [WindowControls.onAutoStartChanged]），调用方应以那条推送为准。
  Future<bool> set(bool enabled) async {
    if (!platformSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('setAutoStart', enabled) ?? false;
    } on Object {
      return false;
    }
  }
}

/// 「开机自动启动」在界面上的状态。
///
/// 它自己不持有事实：[enabled] 直接读 [AppState.settings]（那是界面用的镜像，
/// 由原生回读的结果校准），[supported] 由构造时问原生得到。
///
/// 由 [XvpnApp] 创建并向下传给外壳：托盘菜单（原生侧）与设置页（Dart 侧）
/// 必须显示同一个状态，因此**只能有一个实例**。
class AutoStartController extends ChangeNotifier {
  AutoStartController({required this.state, AutoStartService? service})
    : _service = service ?? AutoStartService();

  final AppState state;
  final AutoStartService _service;

  bool _supported = false;

  /// 是否问过原生。测试与「通道尚未就绪」时先按不支持处理。
  bool _resolved = false;

  /// 当前形态下能不能用。没用原生确认过之前一律为 false。
  bool get supported => _supported;

  /// 是否已经问过原生。界面据此避免「先显示开关，一秒后它又消失」的跳动。
  bool get resolved => _resolved;

  /// 系统里现在是否真的会随开机启动。事实来源是 [AppState.settings]，
  /// 那份字段在每次启动与每次切换后都与系统核对过。
  bool get enabled => state.settings.autoRunAtStartup;

  /// 问原生要一次能力与当前状态，并把镜像校准到系统的真实状态。
  ///
  /// 在 `initState` 里调用一次即可。它**不阻塞首帧**：界面在结果回来之前把这一
  /// 行当作「不支持」而不渲染，因此不会出现一个闪一下就没的开关。
  Future<void> refresh() async {
    final supported = await _service.querySupported();
    final actual = supported ? await _service.query() : null;
    _supported = supported;
    _resolved = true;
    _mirror(actual);
    notifyListeners();
  }

  /// 用户拨动开关。
  ///
  /// 先把意图写进设置（界面立刻响应），再落到系统，最后**回读**并以系统为准
  /// 校准——用户可能在等待期间去系统设置里改了它，也可能被策略挡住。
  Future<void> setEnabled(bool value) async {
    if (!_supported) return;
    _apply(value);
    final accepted = await _service.set(value);
    if (!accepted) {
      // 连请求都没被受理（后端不可用）。回到系统里的真实状态，而不是停在
      // 用户拨到的位置——一个显示「已开启」却什么都没做的开关是最坏的结果。
      _mirror(await _service.query());
      notifyListeners();
      return;
    }
    final actual = await _service.query();
    _mirror(actual);
    notifyListeners();
  }

  /// 原生侧（托盘菜单）改了状态，把它收进设置。
  ///
  /// 托盘与设置页是同一个事实的两个显示点：托盘勾上之后设置页必须立刻跟上，
  /// 否则用户会看到两处说法相反。
  void onNativeChanged(bool value) {
    _apply(value);
    notifyListeners();
  }

  /// 把原生回读到的状态写进设置镜像。
  ///
  /// [actual] 为 null 表示**读不到**，此时什么都不做：保留上一次已知的状态，
  /// 总好过把一个「读不到」显示成「已关闭」。
  void _mirror(bool? actual) {
    if (actual == null || actual == enabled) return;
    _apply(actual);
  }

  void _apply(bool value) {
    state.updateSettings(state.settings.copyWith(autoRunAtStartup: value));
  }
}
