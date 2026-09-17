import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// MSIX 打包的**清单与脚本**必须互相说得通。
///
/// 这些断言锁的是几条只能在真机装包时才暴露、而代价很高的契约：
///
///   1. `windows.startupTask` 的 TaskId 与原生代码里的 `kStartupTaskId` 必须
///      逐字一致。不一致时 `StartupTask.GetAsync(TaskId)` 抛异常，原生按
///      「后端不可用」处理，于是设置页里那一行**悄悄消失**——用户看到的是
///      「这个版本没有开机自启」，而不是任何错误。
///   2. 清单引用的资源图必须真的会被生成（名字对不上时包里的图是裂的）。
///   3. 两个扩展缺一不可：少了 startupTask，「随系统启动」在 MSIX 形态下静默
///      失效（注册表 Run 键在包内被虚拟化，Windows 不会为它创建登录启动项）；
///      少了 appExecutionAlias，桌面快捷方式指向的别名不存在。
///
/// 真正的安装与运行只能在有桌面的 Windows 上验证——这一层测的是**文本契约**，
/// 不能替代真机验证，但能让最贵的那个错误（TaskId 拼错）不可能悄悄溜过去。
void main() {
  final manifest = File('../app/packaging/AppxManifest.xml');
  final packagingScript = File('../scripts/package-msix.ps1');
  final installScript = File('../scripts/install-msix.ps1');
  final nativeSource = File('../app/windows/runner/auto_start.cc');
  final nativeHeader = File('../app/windows/runner/auto_start.h');

  test('清单模板存在且是合法 XML', () {
    expect(
      manifest.existsSync(),
      isTrue,
      reason: '缺少 ${manifest.path}：MSIX 打包没有清单就无从谈起',
    );
    final text = manifest.readAsStringSync();
    // 只做「标签闭合 / 属性合法」这一层校验：Flutter 测试环境里没有 XSD，
    // 而真正的模式校验由 makeappx 在打包时完成（构建期就会失败）。
    final openTags = RegExp(r'<([A-Za-z][\w:.-]*)(?:\s[^>]*?)?(?<!/)>')
        .allMatches(text)
        .map((Match m) => m.group(1))
        .toList();
    final closeTags = RegExp(r'</([A-Za-z][\w:.-]*)\s*>')
        .allMatches(text)
        .map((Match m) => m.group(1))
        .toList();
    for (final tag in closeTags) {
      expect(
        openTags,
        contains(tag),
        reason: '有 </$tag> 却没有对应的开始标签',
      );
    }
  });

  test('清单用 uap5 声明 windows.startupTask，TaskId 与原生代码一致', () {
    final text = manifest.readAsStringSync();
    expect(
      text,
      contains('http://schemas.microsoft.com/appx/manifest/uap/windows10/5'),
      reason: 'startupTask 属于 uap5 命名空间；用错命名空间的扩展会被忽略',
    );
    expect(text, contains('Category="windows.startupTask"'));
    expect(text, contains('<uap5:StartupTask'));

    final taskIdMatch = RegExp(r'TaskId="([^"]+)"').firstMatch(text);
    expect(taskIdMatch, isNotNull, reason: 'windows.startupTask 必须有 TaskId');
    final taskId = taskIdMatch!.group(1)!;

    // 原生侧的任务 id 是 C++ 里的一个常量字符串字面量。
    final native = nativeSource.readAsStringSync();
    final nativeIdMatch = RegExp(r'kStartupTaskId\[\]\s*=\s*L"([^"]+)"')
        .firstMatch(native);
    expect(
      nativeIdMatch,
      isNotNull,
      reason: '在 auto_start.cc 里找不到 kStartupTaskId 的定义（改名了？）',
    );
    expect(
      nativeIdMatch!.group(1),
      taskId,
      reason:
          'TaskId 不一致：清单写「$taskId」，原生写「${nativeIdMatch.group(1)}」。'
          '不一致时 StartupTask.GetAsync 会失败，设置页里「随系统启动」那一行会'
          '静默消失——没有任何错误提示。',
    );
  });

  test('清单声明了应用执行别名，且别名指向同一个可执行文件', () {
    final text = manifest.readAsStringSync();
    expect(
      text,
      contains('Category="windows.appExecutionAlias"'),
      reason: '桌面快捷方式指向这个别名，缺了它快捷方式就是死链接',
    );
    final aliasMatch = RegExp(r'ExecutionAlias Alias="([^"]+)"').firstMatch(text);
    expect(aliasMatch, isNotNull);
    expect(
      aliasMatch!.group(1),
      'xvpn.exe',
      reason: '安装脚本里拼的是 xvpn.exe，两处必须一致',
    );

    // 安装脚本确实按这个名字拼快捷方式的目标。
    final install = installScript.readAsStringSync();
    expect(install, contains("'xvpn.exe'"));
  });

  test('清单引用的每张资源图都由打包脚本生成', () {
    final text = manifest.readAsStringSync();
    final referenced = RegExp(r'Assets\\([A-Za-z0-9_]+\.png)')
        .allMatches(text)
        .map((Match m) => m.group(1)!)
        .toSet();
    expect(referenced, isNotEmpty);

    final script = packagingScript.readAsStringSync();
    for (final asset in referenced) {
      expect(
        script,
        contains(asset),
        reason:
            '清单引用了 Assets\\$asset，但 package-msix.ps1 没有生成它——'
            '包里的图会裂掉，而 makeappx 不会为此报错',
      );
    }
  });

  test('打包脚本声明了 MSIX 要求的固定像素尺寸', () {
    final script = packagingScript.readAsStringSync();
    for (final expected in <String>[
      'Square44x44Logo.png',
      'Square150x150Logo.png',
      'Wide310x150Logo.png',
      'SplashScreen.png',
      'StoreLogo.png',
      // 清单不引用它，但安装脚本要用它合成桌面快捷方式的图标——快捷方式的目标
      // 是执行别名（0 字节重解析点，没有图标资源），因此包里必须有一份真实图片
      // 文件当来源。缺了它桌面就是一块白板。
      'Icon-256.png',
    ]) {
      expect(script, contains(expected), reason: '打包脚本没有产出 $expected');
    }
  });

  test('安装脚本不再把快捷方式图标指向执行别名', () {
    final script = installScript.readAsStringSync();
    // 关键回归：**目标**必须是执行别名（稳定、不随升级变化），但 IconLocation
    // **不能**跟着指向它。别名是 0 字节重解析点，没有图标资源可提取，指过去
    // 桌面就是白板——实测踩过这个坑。
    expect(
      script,
      isNot(contains(r'IconLocation = "$TargetPath,0"')),
      reason: '图标不能指向执行别名：那是 0 字节重解析点，没有图标可提取',
    );
    expect(script, contains(r'IconLocation = "$IconPath,0"'));
    // 必须真的去取一份图标文件，而不是留空。
    expect(script, contains('Install-AppIcon'));
    expect(script, contains('Icon-256.png'));
  });

  test('原生实现两种后端都在，且都不依赖 C++/WinRT 投影', () {
    final native = nativeSource.readAsStringSync();
    // 打包形态：StartupTask（注册表 Run 键在 MSIX 包内会被虚拟化而失效）。
    expect(
      native,
      contains('Windows.ApplicationModel.StartupTask'),
      reason: 'MSIX 形态必须有 StartupTask 后端',
    );
    expect(native, contains('RequestEnableAsync'));
    // 未打包形态：注册表 Run 键。只比对路径里不会引起转义歧义的那一段——
    // 写成 r'Software\\Microsoft\\...' 会去匹配**两个**反斜杠，而 C++ 源码里
    // 字符串字面量中确实是两个，读出来却只有一个，断言会以「找不到」的形式
    // 失败，且看起来像是功能缺失。
    expect(
      native,
      contains('CurrentVersion'),
      reason: '绿色解压版仍然用注册表 Run 键',
    );
    expect(
      native,
      contains('RegSetValueExW'),
      reason: '注册表后端必须真的写入',
    );
    // 形态判定。
    expect(
      native,
      contains('GetCurrentPackageFullName'),
      reason: '必须能区分「是否打包」，两套后端按它二选一',
    );
    // 用 SDK 的 ABI 声明而不是自己复述 vtable：此前自己写反了
    // IStartupTask 的方法顺序，调用 RequestEnableAsync 实际调到了 get_State。
    expect(
      native,
      contains('windows.applicationmodel.h'),
      reason: '必须用 SDK 的接口声明；手写的 vtable 顺序错过一次，且不会编译报错',
    );
    // C++/WinRT 的投影依赖异常，而 runner 关掉了异常。**不能只查 'winrt::'**：
    // 文件顶部的注释里正好在解释「为什么不用 C++/WinRT」，那句解释本身就会命中。
    // 要挡的是真的把它 include 进来（`#include <winrt/...>`）或把它的命名空间
    // 引进来（`using namespace winrt`）。
    expect(
      native,
      isNot(contains('#include <winrt/')),
      reason: 'runner 用 _HAS_EXCEPTIONS=0，C++/WinRT 投影在这个设置下编不过',
    );
    expect(
      native,
      isNot(contains('using namespace winrt')),
      reason: 'runner 用 _HAS_EXCEPTIONS=0，C++/WinRT 投影在这个设置下编不过',
    );
  });

  test('原生头文件暴露的入口与 flutter_window 用的是同一套', () {
    final header = nativeHeader.readAsStringSync();
    for (final symbol in <String>[
      'IsSupported',
      // `QueryEnabled` 是同步读（内部等 StartupTask 的异步操作完成）。
      // 早先叫 `IsEnabled`，改名是为了让「它会阻塞到拿到结果」这件事在调用处
      // 一眼可见——它确实会等，不该被当成一次普通的属性读取。
      'QueryEnabled',
      'SetEnabled',
      'CurrentMode',
    ]) {
      expect(header, contains(symbol), reason: 'auto_start.h 缺少 $symbol');
    }
  });

  test('两个新脚本都带 UTF-8 BOM', () {
    // 与 test/scripts_syntax_test.dart 同一条纪律：write/edit 工具不保留 BOM，
    // 而 Windows PowerShell 5.1 会把没有 BOM 的中文注释按 ANSI 解码，
    // 报出与真实原因毫无关系的语法错误。
    for (final file in <File>[packagingScript, installScript]) {
      expect(file.existsSync(), isTrue, reason: '缺少 ${file.path}');
      final bytes = file.readAsBytesSync();
      final hasBom = bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF;
      expect(hasBom, isTrue, reason: '${file.path} 缺少 UTF-8 BOM');
    }
  });
}
