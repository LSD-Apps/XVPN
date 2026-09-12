#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例：同一时间只允许一个 XVPN 在跑。
  //
  // 多开会实实在在地把网络弄坏，而不是仅仅「有点乱」：系统代理是**全局且唯一**
  // 的一份设置，两个实例各自接管一次，后启动的那个会覆盖掉前一个；此后关掉任意
  // 一个，它的还原逻辑都会把代理改回「用户原本的取值」，而另一个实例的内核还在
  // 运行——用户看到的是「隧道显示已连接，但所有网站都打不开」。
  //
  // 已经有一个实例时，把它的窗口显示出来（可能正收在托盘里）再退出，
  // 这样用户点第二次图标时的预期（「切换到已经开着的那个」）也得到满足。
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Local\\XVPN-SingleInstance");
  if (single_instance != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(nullptr, L"XVPN");
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_SHOW);
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }
  // 句柄故意不关闭：进程存活期间要一直持有它，否则互斥体会被释放，
  // 单实例约束随之失效。

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 画布 1180 × 742（设计稿）再加上 46 高的自绘标题栏，
  // 另外留出窗口边框在被 WM_NCCALCSIZE 去掉后仍能正常显示的空间。
  Win32Window::Size size(1180, 788);
  if (!window.Create(L"XVPN", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
