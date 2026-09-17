import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「随系统启动」的 MSIX 后端要在 `_HAS_EXCEPTIONS=0` 的编译设置下直接调
/// WinRT 的 ABI 接口。这条路**错位不报错、只崩溃**，实际排查绕了很远，
/// 因此把踩出来的三条规矩钉在这里。
///
/// 这不是在测实现细节，而是在守一份**手写的、外部 ABI 的用法**——那份用法
/// 一旦写错，编译期毫无提示，只在用户机器上以「启动即崩」或「开关没反应」出现。
void main() {
  final File source = File('windows/runner/auto_start.cc');

  /// 去掉注释，只留代码。
  ///
  /// 有必要：文件里专门写了「当初那么写是错的」的说明，里面的错法本身不该被判违规。
  String codeOnly(String text) {
    final String withoutBlock =
        text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    return withoutBlock
        .split('\n')
        .map((String line) {
          final int at = line.indexOf('//');
          return at < 0 ? line : line.substring(0, at);
        })
        .join('\n');
  }

  late String code;

  setUpAll(() {
    expect(source.existsSync(), isTrue,
        reason: '找不到 ${source.path}——测试的工作目录应是 app/');
    code = codeOnly(source.readAsStringSync());
  });

  test('不得手写 IAsyncOperation 的 vtable', () {
    // 这是这次最大的一个坑：为了「顺便看一眼进度」而复述了 IAsyncOperation<T>
    // 的 vtable，而 SDK 里
    //
    //     struct IAsyncOperation_impl<TResult> : IInspectable
    //
    // **只有三个自有方法**（put_Completed / get_Completed / GetResults），
    // 根本没有 IAsyncInfo 的 get_Status。按自己以为的顺序去调，第一次调用就
    // 访问冲突（0xc0000005，崩在 xvpn.exe 自己身上）。
    //
    // 正确做法是用 SDK 给的具体类型（`__FIAsyncOperation_1_...`），只调确实
    // 存在的方法。因此这里禁止再出现任何复述异步接口的结构体。
    expect(
      RegExp(r'struct\s+IAsyncOperationBase').hasMatch(code),
      isFalse,
      reason: '不要再手写 IAsyncOperation 的 vtable——SDK 的 '
          'IAsyncOperation_impl<TResult> 只继承 IInspectable、只有三个自有方法，'
          '手写必然错位。直接用 __FIAsyncOperation_1_... 类型。',
    );
    expect(
      code.contains('get_Status'),
      isFalse,
      reason: 'IAsyncOperation 上没有 get_Status（它属于 IAsyncInfo，而这层关系'
          '不在 IAsyncOperation_impl 的继承链里）。完成信号请用 put_Completed 的'
          '回调，不要轮询状态。',
    );
  });

  test('一律用 SDK 生成的异步类型别名，而不是自己拼模板参数', () {
    // `IAsyncOperation<StartupTask*>` 的那支特化，其完成处理器叫
    // `...CompletedHandler<StartupTask*>`，**不是** `<IStartupTask*>`——
    // 后者根本没有特化，写出来会撞 not_yet_specialized 的 static_assert。
    expect(
      code.contains('__FIAsyncOperation_1_Windows__CApplicationModel__CStartupTask'),
      isTrue,
      reason: '取任务对象要用 MIDL 生成的别名（IAsyncOperation<StartupTask*>）。',
    );
    expect(
      code.contains(
          '__FIAsyncOperationCompletedHandler_1_Windows__CApplicationModel__CStartupTask'),
      isTrue,
      reason: '完成处理器要用 MIDL 生成的特化名（...CompletedHandler<StartupTask*>）。',
    );
  });

  test('完成回调只继承一个接口，不共享带 IInspectable 的基类', () {
    final RegExpMatch? match = RegExp(
      r'class\s+SignalHandler\s+final\s*:\s*public\s+([\w:]+)',
    ).firstMatch(code);
    expect(match, isNotNull, reason: '没找到 SignalHandler 的声明');
    // 多继承一个带 IInspectable 的基类会让 vtable 错位（踩过：崩在 combase.dll）。
    expect(match!.group(1)!.contains(','), isFalse,
        reason: 'SignalHandler 只能有一个基类。');
  });

  test('回调不自我释放（Invoke 里不能 delete this）', () {
    // Invoke 返回后运行库还要走这个对象的 vtable，在里面 delete 就是
    // use-after-free。生命周期由创建处管。
    final int invokeAt = code.indexOf('HRESULT STDMETHODCALLTYPE Invoke(');
    expect(invokeAt, greaterThanOrEqualTo(0));
    final int invokeEnd = code.indexOf('\n  }', invokeAt);
    final String body = code.substring(invokeAt, invokeEnd);
    expect(body.contains('delete this'), isFalse,
        reason: 'Invoke 里不能删除自己。');
    expect(body.contains('Release()'), isFalse,
        reason: 'Invoke 里不能释放自己。');
  });

  test('取结果之前必须等完成通知，不能直接 GetResults', () {
    final int getTask = code.indexOf('IStartupTask* GetStartupTask()');
    expect(getTask, greaterThanOrEqualTo(0));
    final int end = code.indexOf('\n}', getTask);
    final String body = code.substring(getTask, end);

    // `GetAsync` 是**真正未完成**的异步操作：未完成时 GetResults 返回
    // E_PENDING，拿到的 task 是 null，整个功能会静默失效。
    final int waitAt = body.indexOf('WaitForOperation');
    final int resultsAt = body.indexOf('GetResults');
    expect(waitAt, greaterThanOrEqualTo(0),
        reason: 'GetStartupTask 必须先等完成通知。');
    expect(resultsAt, greaterThanOrEqualTo(0));
    expect(waitAt, lessThan(resultsAt),
        reason: '等待必须发生在 GetResults 之前，否则拿到 E_PENDING。');
  });

  test('写状态后回读，而不是把「请求被受理」当成成功', () {
    // 系统可能拒绝（DisabledByPolicy），也可能要用户去「设置 → 应用 → 启动」
    // 放行。只看 RequestEnableAsync 是否成功会给出一个「开了但其实没开」的开关。
    final int setAt = code.indexOf('bool StartupTaskSetEnabled(bool enabled)');
    expect(setAt, greaterThanOrEqualTo(0));
    final int end = code.indexOf('\n}', setAt);
    final String body = code.substring(setAt, end);
    expect(body.contains('StartupTaskIsEnabled()'), isTrue,
        reason: 'SetEnabled 必须回读真实状态作为结论。');
  });

  test('读不出来按「没开」处理，而不是按「已开」', () {
    // 把「读不出来」显示成「已开启」会让用户以为已经生效——这是这一项最不该
    // 出现的错法。
    final int at = code.indexOf('bool StartupTaskIsEnabled()');
    expect(at, greaterThanOrEqualTo(0));
    final String body = code.substring(at, code.indexOf('\n}', at));
    expect(body.contains('SUCCEEDED(got)'), isTrue,
        reason: 'get_State 失败时必须返回 false（当作没开）。');
  });

  group('托盘菜单读的是系统里的实时状态，不是缓存的镜像', () {
    final File window = File('windows/runner/flutter_window.cpp');
    late String windowCode;

    setUpAll(() {
      expect(window.existsSync(), isTrue, reason: '缺少 ${window.path}');
      windowCode = codeOnly(window.readAsStringSync());
    });

    test('弹托盘菜单之前先回读系统', () {
      // 这一项的**事实在系统里**：用户随时能在「任务管理器 → 启动」或
      // 「设置 → 应用 → 启动」里改它，应用无从得知。
      //
      // 而 `tray_auto_start_` 只在两个时刻被赋值：Dart 推来托盘载荷，或本进程
      // 自己切换完。实测踩到过：系统里已经是「关」，应用里的镜像还停在「开」，
      // 于是托盘菜单的勾与真实状态**相反**——用户点它一下反而什么都没变
      // （它以为要关，而系统本来就关着）。这正是「托盘点了没对接上」的体感。
      final int menuAt = windowCode.indexOf('void FlutterWindow::ShowTrayMenu()');
      expect(menuAt, greaterThanOrEqualTo(0), reason: '没找到 ShowTrayMenu');
      final int menuEnd = windowCode.indexOf('\n}', menuAt);
      final String body = windowCode.substring(menuAt, menuEnd);

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
