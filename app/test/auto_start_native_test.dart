import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「随系统启动」的**原生实现**必须守住的几条纪律。
///
/// 这一项的事实来源是系统（`HKCU\...\CurrentVersion\Run`），而界面上的开关只是
/// 镜像。因此这里断言的不是 Dart 行为（那在 `auto_start_test.dart`），而是原生
/// 代码里那些**只能靠读源码才能发现**的形状——它们全都是真实踩过的坑：
///
///   1. 写完之后必须**回读**：`RegSetValueExW` 返回成功只说明调用被受理，不等于
///      「开机真的会启动」；
///   2. 读不出来时按**没开**处理：把「读不出来」显示成「已开启」会让用户以为已经
///      生效，这是这一项最不该出现的错法；
///   3. 托盘菜单弹出**之前**要回读系统：托盘读的是缓存的镜像，而用户随时能在
///      「任务管理器 → 启动」里改它——不回读就会出现「托盘的勾与真实状态相反，
///      点一下反而什么都没变」。
///
/// 与 `test/msix_packaging_test.dart`（已随 MSIX 一起删除）和
/// `test/scripts_syntax_test.dart` 同一条思路：文本断言不能替代真机验证，但能让
/// 最贵的那个错误不可能悄悄溜回来。
void main() {
  final File source = File('windows/runner/auto_start.cc');
  final File window = File('windows/runner/flutter_window.cpp');

  /// 去掉注释后的源码：注释里大段解释「为什么不能这么做」，直接匹配代码会被
  /// 这些解释命中（例如 `get_Status` 那类禁用词）。
  String codeOnly(String text) => text
      .split('\n')
      .map((String line) {
        final int at = line.indexOf('//');
        return at < 0 ? line : line.substring(0, at);
      })
      .join('\n');

  late String code;

  setUpAll(() {
    expect(source.existsSync(), isTrue,
        reason: '找不到 ${source.path}——测试的工作目录应是 app/');
    code = codeOnly(source.readAsStringSync());
  });

  test('写状态后回读，而不是把「写入被受理」当成成功', () {
    // 写进去的值可能不指向当前安装路径（残留的旧路径、被策略改写），那都不算
    // 「开着」。只看写入调用的返回值会给出一个「开了但其实没开」的开关。
    final int setAt = code.indexOf('bool SetEnabled(bool enabled)');
    expect(setAt, greaterThanOrEqualTo(0), reason: '没找到 SetEnabled');
    final String body = code.substring(setAt, code.indexOf('\n}', setAt));
    expect(
      body.contains('RegistryIsEnabled()'),
      isTrue,
      reason: 'SetEnabled 必须回读系统里的真实状态作为结论。',
    );
  });

  test('「开着」的判据是值指向我们自己，而不是值存在', () {
    final int at = code.indexOf('bool RegistryIsEnabled()');
    expect(at, greaterThanOrEqualTo(0), reason: '没找到 RegistryIsEnabled');
    final String body = code.substring(at, code.indexOf('\n}', at));
    // 残留的、指向旧安装目录的 Run 项会让界面显示成「已开启」，而它每次开机都在
    // 报错——用户看到开关是开的，实际什么也没启动。
    expect(
      body.contains('QuotedExecutablePath()'),
      isTrue,
      reason: '必须把注册表里的值与当前可执行文件路径比对。',
    );
    expect(
      body.contains('_wcsicmp'),
      isTrue,
      reason: '路径比较要不区分大小写（Windows 路径本来就大小写不敏感）。',
    );
  });

  test('读不出来按「没开」处理，而不是按「已开」', () {
    final int at = code.indexOf('bool RegistryIsEnabled()');
    final String body = code.substring(at, code.indexOf('\n}', at));
    expect(
      body.contains('return false'),
      isTrue,
      reason: '取不到值 / 类型不对时必须返回 false（当作没开）。',
    );
  });

  test('路径带引号：否则 Run 项会被拆成「命令 + 参数」', () {
    final int at = code.indexOf('std::wstring QuotedExecutablePath()');
    expect(at, greaterThanOrEqualTo(0));
    final String body = code.substring(at, code.indexOf('\n}', at));
    expect(
      body.contains(r'\""'),
      isTrue,
      reason: '返回的路径必须带双引号，否则路径里的空格会让开机启动失败。',
    );
  });

  group('托盘菜单读的是系统里的实时状态，不是缓存的镜像', () {
    late String windowCode;

    setUpAll(() {
      expect(window.existsSync(), isTrue, reason: '缺少 ${window.path}');
      windowCode = codeOnly(window.readAsStringSync());
    });

    test('弹托盘菜单之前先回读系统', () {
      // `tray_auto_start_` 只在两个时刻被赋值：Dart 推来托盘载荷，或本进程自己
      // 切换完。系统里被应用之外改过之后，镜像就过期了，于是托盘菜单的勾与真实
      // 状态**相反**——用户点它一下反而什么都没变（它以为要关，而系统本来就关着）。
      final int menuAt = windowCode.indexOf('void FlutterWindow::ShowTrayMenu()');
      expect(menuAt, greaterThanOrEqualTo(0), reason: '没找到 ShowTrayMenu');
      final String body =
          windowCode.substring(menuAt, windowCode.indexOf('\n}', menuAt));

      expect(
        body.contains('auto_start::QueryEnabled()'),
        isTrue,
        reason: 'ShowTrayMenu 必须先回读系统状态，不能直接用 tray_auto_start_。',
      );
      // 而且要在建菜单之前回读，否则这一次弹出的还是旧值。
      final int readAt = body.indexOf('auto_start::QueryEnabled()');
      final int appendAt = body.indexOf('AppendMenuW');
      expect(readAt, lessThan(appendAt),
          reason: '回读要发生在往菜单里加项之前，否则这一次弹出的仍是旧值。');
    });

    test('回读发现与镜像不一致时，把 Dart 也校准过来', () {
      final int menuAt = windowCode.indexOf('void FlutterWindow::ShowTrayMenu()');
      final String body =
          windowCode.substring(menuAt, windowCode.indexOf('\n}', menuAt));
      expect(
        body.contains('NotifyAutoStartChanged()'),
        isTrue,
        reason: '回读到真实状态后要推给 Dart，否则设置页的开关会继续显示旧值——'
            '同一边显示为开、另一边显示为关。',
      );
    });
  });
}
