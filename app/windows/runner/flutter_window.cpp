#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <tlhelp32.h>
#include <wininet.h>

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr const wchar_t kInternetSettings[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
// 系统代理的原始取值备份在这里。用注册表而不是文件，是为了在进程被强杀
// 之后仍然能恢复——否则用户会留下一个指向已退出内核的代理设置。
constexpr const wchar_t kProxyBackupKey[] = L"Software\\XVPN\\ProxyBackup";

// 是否已经开始退出。一旦置位，**不再接受**任何新的代理接管请求。
//
// 存在的理由是关停过程中一个很窄但后果严重的竞争：Dart 侧的连接流程是异步的，
// 「等待内核就绪 → 设置系统代理」可能正好卡在退出清理之后完成。那样退出时刚
// 还原好的代理会被重新写回一个已经死掉的端口，用户看到的就是「关掉应用之后
// 所有网站都打不开」——正是最难自查的那类故障。
bool g_shutting_down = false;

// 退出清理是否已经执行过。清理必须幂等：WM_QUERYENDSESSION 与 WM_DESTROY
// 可能先后到达，托盘退出又可能再来一次。
bool g_cleanup_done = false;

// 内核子进程所属的作业对象。
//
// 为什么需要它：内核是 Dart 侧用 Process.start 拉起来的**子进程**，而 Windows
// 不会在父进程消失时自动结束子进程。此前只在 WM_DESTROY 里枚举子进程来结束，
// 于是「任务管理器强制结束」「应用崩溃」这两条路径都会留下一个孤儿内核——它
// 继续占着 2080/2081，下一次启动就可能因为端口被占而起不来。
//
// 作业对象把这件事交给系统：把本进程放进一个带 KILL_ON_JOB_CLOSE 的作业，
// 它派生的子进程会自动加入同一个作业；本进程无论以**任何**方式结束（包括被
// 强杀），最后一个作业句柄关闭时系统会一并结束其中的内核。
HANDLE g_kernel_job = nullptr;

bool SetRegistryString(HKEY root, const wchar_t* subkey, const wchar_t* name,
                       const wchar_t* value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(root, subkey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD bytes =
      static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t));
  const LSTATUS status =
      RegSetValueExW(key, name, 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(value), bytes);
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool SetRegistryDword(HKEY root, const wchar_t* subkey, const wchar_t* name,
                      DWORD value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(root, subkey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status =
      RegSetValueExW(key, name, 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool ReadRegistryDword(HKEY root, const wchar_t* subkey, const wchar_t* name,
                       DWORD* out) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(root, subkey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  DWORD size = sizeof(DWORD);
  const LSTATUS status =
      RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(out), &size);
  RegCloseKey(key);
  return status == ERROR_SUCCESS && type == REG_DWORD;
}

bool ReadRegistryString(HKEY root, const wchar_t* subkey, const wchar_t* name,
                        std::wstring* out) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(root, subkey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  DWORD size = 0;
  LSTATUS status = RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size == 0) {
    RegCloseKey(key);
    return false;
  }
  std::wstring buffer(size / sizeof(wchar_t), L'\0');
  status = RegQueryValueExW(key, name, nullptr, &type,
                            reinterpret_cast<BYTE*>(buffer.data()), &size);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    return false;
  }
  while (!buffer.empty() && buffer.back() == L'\0') {
    buffer.pop_back();
  }
  *out = buffer;
  return true;
}

bool DeleteRegistryTree(HKEY root, const wchar_t* subkey) {
  return RegDeleteTreeW(root, subkey) == ERROR_SUCCESS;
}

bool DeleteRegistryValue(HKEY root, const wchar_t* subkey, const wchar_t* name) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(root, subkey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = RegDeleteValueW(key, name);
  RegCloseKey(key);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

// 让代理设置立刻生效，不必等应用重启。
void NotifyProxyChanged() {
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

bool HasProxyBackup() {
  DWORD saved = 0;
  return ReadRegistryDword(HKEY_CURRENT_USER, kProxyBackupKey, L"Saved", &saved) &&
         saved == 1;
}

// 接管系统代理：先把用户原有设置备份到我们自己的注册表键，再写入内核地址。
bool ApplySystemProxy(const std::wstring& server) {
  // 退出流程已经开始：拒绝接管。
  //
  // 调用方（Dart）是异步的，这一步可能恰好排在退出清理之后。若照常写入，就会
  // 把清理时刚还原好的代理重新指向一个即将死掉的端口——用户看到的现象是
  // 「关掉应用之后所有网站都打不开」。
  if (g_shutting_down) {
    return false;
  }

  DWORD previous_enable = 0;
  const bool had_enable = ReadRegistryDword(HKEY_CURRENT_USER,
                                            kInternetSettings, L"ProxyEnable",
                                            &previous_enable);
  std::wstring previous_server;
  const bool had_server = ReadRegistryString(
      HKEY_CURRENT_USER, kInternetSettings, L"ProxyServer", &previous_server);

  if (!HasProxyBackup()) {
    SetRegistryDword(HKEY_CURRENT_USER, kProxyBackupKey, L"Saved", 1);
    SetRegistryDword(HKEY_CURRENT_USER, kProxyBackupKey, L"ProxyEnable",
                     had_enable ? previous_enable : 0);
    SetRegistryString(HKEY_CURRENT_USER, kProxyBackupKey, L"ProxyServer",
                      had_server ? previous_server.c_str() : L"");
  }

  const bool ok = SetRegistryDword(HKEY_CURRENT_USER, kInternetSettings,
                                   L"ProxyEnable", 1) &&
                  SetRegistryString(HKEY_CURRENT_USER, kInternetSettings,
                                    L"ProxyServer", server.c_str());
  NotifyProxyChanged();
  return ok;
}

// 还原系统代理。没有备份时只关掉代理开关，不动用户的其它设置。
bool RestoreSystemProxy() {
  bool ok = true;
  if (HasProxyBackup()) {
    DWORD enable = 0;
    ReadRegistryDword(HKEY_CURRENT_USER, kProxyBackupKey, L"ProxyEnable",
                      &enable);
    std::wstring server;
    ReadRegistryString(HKEY_CURRENT_USER, kProxyBackupKey, L"ProxyServer",
                       &server);
    ok = SetRegistryDword(HKEY_CURRENT_USER, kInternetSettings,
                          L"ProxyEnable", enable);
    if (!server.empty()) {
      ok = SetRegistryString(HKEY_CURRENT_USER, kInternetSettings,
                             L"ProxyServer", server.c_str()) &&
           ok;
    } else {
      // 用户原本没有 ProxyServer 这个值。必须把它删掉而不是留着，
      // 否则会残留一个指向已退出内核的地址，误导其它读取该值的程序。
      DeleteRegistryValue(HKEY_CURRENT_USER, kInternetSettings,
                          L"ProxyServer");
    }
    // **只有还原成功才消费备份。**
    //
    // 反过来（无条件删）有一个很难查的后果：万一上面写注册表失败（权限受限、
    // 组策略锁定），备份被删掉了、代理却仍指着已经退出的内核。下次启动时
    // HasProxyBackup() 为假，兜底恢复无从下手，用户的网络就一直坏着——而且
    // 从注册表里看不出任何线索。留着备份，至少下次启动还能再试一次。
    if (ok) {
      DeleteRegistryTree(HKEY_CURRENT_USER, kProxyBackupKey);
      // RegDeleteTree 只删掉 ProxyBackup 这一层，创建它时顺带生成的
      // Software\XVPN 容器会留下来。虽然里面已经没有值、不会影响
      // HasProxyBackup，但退出后还在用户注册表里留一个空键没有必要，一并清掉。
      // 失败无所谓：说明这个键本来就不存在，或用户在里面放了别的东西。
      RegDeleteKeyW(HKEY_CURRENT_USER, L"Software\\XVPN");
    }
  } else {
    ok = SetRegistryDword(HKEY_CURRENT_USER, kInternetSettings, L"ProxyEnable",
                          0);
  }
  NotifyProxyChanged();
  return ok;
}

// 结束本进程的所有直接子进程。
//
// 内核是 Dart 侧用 Process.start 拉起来的子进程：窗口被关闭时 Dart 的
// dispose 不一定会执行，内核就会残留下来，一直占着 2080 / 2081 端口，
// 导致下一次启动绑定失败。这里按「父进程 == 自己」精确识别，不会误伤
// 用户机器上其它程序的 sing-box 实例。
void TerminateChildProcesses() {
  const DWORD self = GetCurrentProcessId();
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return;
  }
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ParentProcessID == self &&
          entry.th32ProcessID != self) {
        HANDLE child =
            OpenProcess(PROCESS_TERMINATE, FALSE, entry.th32ProcessID);
        if (child != nullptr) {
          TerminateProcess(child, 0);
          CloseHandle(child);
        }
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
}

// 建立内核子进程的作业对象，并把自己放进去。
//
// 放进同一个作业之后，Dart 用 Process.start 拉起的内核会自动成为作业成员；
// 本进程无论以什么方式结束（正常退出、崩溃、任务管理器强制结束、关机），
// 系统都会在最后一个作业句柄关闭时结束其中的进程。这比「退出时枚举子进程」
// 多覆盖了两条此前完全无人处理的路径。
//
// 刻意**不**在退出清理里 CloseHandle(g_kernel_job)：
// 本进程也在作业里，关掉最后一个句柄会立刻终止包括自己在内的所有成员，
// 那样就会在清理流程中途被系统打断。让它随进程结束由系统关闭即可。
void InitializeKernelJob() {
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    return;  // 建不出来就退回「退出时枚举子进程」那条路径。
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {};
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info,
                               sizeof(info))) {
    CloseHandle(job);
    return;
  }
  if (!AssignProcessToJobObject(job, GetCurrentProcess())) {
    // Windows 8 起支持嵌套作业；更老的系统或已被别的作业占用时会失败，
    // 此时不该让整个应用起不来，退回到原有的枚举式清理即可。
    CloseHandle(job);
    return;
  }
  g_kernel_job = job;
}

// 退出清理：还原系统代理 + 结束内核。幂等，可被多条退出路径重复调用。
//
// 三条路径都会走到这里：托盘「退出」与系统关闭窗口（WM_DESTROY）、
// 注销或关机（WM_QUERYENDSESSION / WM_ENDSESSION）。集中成一处是为了
// 「新增一条退出路径」时不会漏掉其中某一步——漏掉的代价是用户的网络出问题。
bool CleanupResources() {
  // 先置位再清理：让清理期间到达的 setSystemProxy 变成空操作。
  g_shutting_down = true;
  if (g_cleanup_done) {
    return true;
  }
  g_cleanup_done = true;

  const bool proxy_restored = RestoreSystemProxy();
  TerminateChildProcesses();
  return proxy_restored;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // 尽早建立内核作业对象：在这之后 Dart 拉起的 sing-box 才会自动加入作业，
  // 从而在本进程意外消失时被系统一并结束。
  InitializeKernelJob();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 自绘标题栏上的窗口按钮 + 系统代理接管：原生标题栏已被去掉，
  // 这些操作必须由这里完成。Dart 侧见 core/window_controls.dart 与
  // core/system_proxy.dart，两处都用这个名字。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.xvpn.xvpn/platform",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND handle = GetHandle();
        if (handle == nullptr) {
          result->Error("no_window", "窗口尚未创建");
          return;
        }
        const std::string& method = call.method_name();
        if (method == "minimize") {
          ShowWindow(handle, SW_MINIMIZE);
          result->Success();
        } else if (method == "toggleMaximize") {
          ShowWindow(handle, IsZoomed(handle) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(handle, WM_CLOSE, 0, 0);
          result->Success();
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(IsZoomed(handle) != 0));
        } else if (method == "startDragging") {
          // 拖动必须由界面触发：Flutter 视图是覆盖整个窗口的子窗口，
          // 系统会把鼠标命中测试交给它，顶层窗口的 WM_NCHITTEST 收不到消息，
          // 因此靠 HTCAPTION 自动拖动是无效的。这里主动把窗口交给系统去拖。
          ReleaseCapture();
          SendMessage(handle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
        } else if (method == "startResize") {
          // 同理，四边八向的缩放也由界面按下时触发。
          const std::string* edge =
              std::get_if<std::string>(call.arguments());
          if (edge == nullptr) {
            result->Error("bad_args", "startResize 需要一个边名");
            return;
          }
          WPARAM hit = 0;
          if (*edge == "left") {
            hit = HTLEFT;
          } else if (*edge == "right") {
            hit = HTRIGHT;
          } else if (*edge == "top") {
            hit = HTTOP;
          } else if (*edge == "topLeft") {
            hit = HTTOPLEFT;
          } else if (*edge == "topRight") {
            hit = HTTOPRIGHT;
          } else if (*edge == "bottom") {
            hit = HTBOTTOM;
          } else if (*edge == "bottomLeft") {
            hit = HTBOTTOMLEFT;
          } else if (*edge == "bottomRight") {
            hit = HTBOTTOMRIGHT;
          } else {
            result->Error("bad_args", "未知的边名：" + *edge);
            return;
          }
          ReleaseCapture();
          SendMessage(handle, WM_NCLBUTTONDOWN, hit, 0);
          result->Success();
        } else if (method == "setSystemProxy") {
          // 参数是 "host:port"。
          const std::string* endpoint = std::get_if<std::string>(call.arguments());
          if (endpoint == nullptr) {
            result->Error("bad_args", "setSystemProxy 需要 host:port");
            return;
          }
          const std::wstring server(endpoint->begin(), endpoint->end());
          result->Success(flutter::EncodableValue(ApplySystemProxy(server)));
        } else if (method == "clearSystemProxy") {
          result->Success(flutter::EncodableValue(RestoreSystemProxy()));
        } else if (method == "hasProxyBackup") {
          result->Success(flutter::EncodableValue(HasProxyBackup()));
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  InstallTrayIcon();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::InstallTrayIcon() {
  if (tray_installed_) return;
  HWND handle = GetHandle();
  if (handle == nullptr) return;

  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = handle;
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon =
      LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (tray_icon_.hIcon == nullptr) {
    tray_icon_.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  }
  wcscpy_s(tray_icon_.szTip, L"XVPN · 智能分流");
  tray_installed_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_installed_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_installed_ = false;
}

void FlutterWindow::ShowMainWindow() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;
  ShowWindow(handle, SW_SHOW);
  ShowWindow(handle, SW_RESTORE);
  SetForegroundWindow(handle);
}

void FlutterWindow::ShowTrayMenu() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;

  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kTrayMenuShow, L"显示主界面");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayMenuQuit, L"退出 XVPN");

  // 弹菜单前必须把窗口设为前台，并在收起后补一条 WM_NULL，
  // 否则菜单会「点了不消失」——这是托盘菜单的经典坑。
  SetForegroundWindow(handle);
  POINT cursor = {};
  GetCursorPos(&cursor);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, handle, nullptr);
  PostMessageW(handle, WM_NULL, 0, 0);
  DestroyMenu(menu);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 客户区尺寸与命中测试必须在我们这里先处理：交给 Flutter 引擎之后，
  // 引擎的默认处理会把系统标题栏重新加回来（客户区又缩回标题栏以下）。
  if (message == WM_NCCALCSIZE || message == WM_NCHITTEST) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  // 退出时必须还原系统代理并结束内核进程。否则用户关掉应用后，系统代理仍
  // 指向已经退出的内核（表现为「所有网站都打不开」），内核还会继续占着端口。
  // （进程被强杀时收不到这条消息，由事后两条兜底处理：作业对象保证内核不会
  // 变成孤儿，下次启动的 recoverIfNeeded 负责把代理还原回去。）
  if (message == WM_DESTROY) {
    CleanupResources();
  }

  // 注销 / 关机 / 重启：必须在系统真正结束进程**之前**还原代理。
  //
  // 这条路径此前是漏的，而它的后果比普通退出更严重：注册表里的代理设置会跨
  // 重启保留下来，于是机器重启后浏览器全部指向一个不存在的 127.0.0.1:2080，
  // 表现为「重启之后整个网络都不对」，而用户根本不会把它和 VPN 联系起来。
  //
  // 只看 WM_ENDSESSION 且要求 wparam 非零，**不**在 WM_QUERYENDSESSION 里清理：
  //   * WM_QUERYENDSESSION 只是「能不能关」的询问，任何一个应用都可以否决它，
  //     关机会被取消。在那里清理会把一个仍在运行的隧道留成「界面显示已连接、
  //     系统代理却没了」——用户以为在走隧道，实际全在直连；
  //   * WM_ENDSESSION 带非零 wparam 才是「确定要关了」，此时清理不会有假动作。
  //     （若关机被取消，会收到 wparam 为零的 WM_ENDSESSION，不清理。）
  // 万一连这条消息都没走到（系统强杀），下次启动的 recoverIfNeeded 仍是兜底。
  if (message == WM_ENDSESSION && wparam != 0) {
    CleanupResources();
    // 清理完就**立刻退出**，而不是等系统来结束我们。
    //
    // 这一步不是多余的：Dart 侧并不知道代理已经被撤掉、内核已经被结束，它的
    // 自愈逻辑会把「Clash API 读不到」判定成内核卡死，然后在系统真正杀掉本进程
    // 之前的几秒里**把内核实实在在地拉起来一次**。虽然在真实关机里那个内核最终
    // 会被作业对象收走，但这段时间白起一个进程没有意义，也让「到底收干净没有」
    // 变得难以断言。主动退出把这段窗口彻底关掉。
    RemoveTrayIcon();
    DestroyWindow(hwnd);
    return 0;
  }

  // 关闭主窗口 = 收进托盘，而不是退出程序。
  // 返回 0 会阻止默认的销毁流程；真正退出只能走托盘菜单的「退出 XVPN」。
  if (message == WM_CLOSE) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  // 托盘图标的鼠标事件。
  if (message == kTrayCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowMainWindow();
        return 0;
      case WM_RBUTTONUP:
        ShowTrayMenu();
        return 0;
      default:
        return 0;
    }
  }

  // 托盘菜单命令。
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kTrayMenuShow:
        ShowMainWindow();
        return 0;
      case kTrayMenuQuit:
        RemoveTrayIcon();
        // DestroyWindow 会触发 WM_DESTROY，由那里的清理逻辑统一完成
        // 「还原系统代理 + 结束内核子进程」，避免退出后网络异常。
        DestroyWindow(hwnd);
        return 0;
      default:
        break;
    }
  }

  // 最大化状态变化要**主动**告诉 Dart。
  //
  // 双击标题栏、Win+↑、贴边、从任务栏还原、系统快捷键……这些都由 Windows 直接
  // 处理，Dart 侧完全不知情，于是标题栏上的按钮会停在旧图标上：窗口已经最大化
  // 了，它还画着「最大化」的方框。用户按下去等于还原，图形与行为对不上。
  if (message == WM_SIZE && window_channel_) {
    const int maximized = IsZoomed(hwnd) ? 1 : 0;
    if (maximized != last_maximized_) {
      last_maximized_ = maximized;
      window_channel_->InvokeMethod(
          "maximizedChanged",
          std::make_unique<flutter::EncodableValue>(maximized == 1));
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
