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
    DeleteRegistryTree(HKEY_CURRENT_USER, kProxyBackupKey);
    // RegDeleteTree 只删掉 ProxyBackup 这一层，创建它时顺带生成的
    // Software\XVPN 容器会留下来。虽然里面已经没有值、不会影响 HasProxyBackup，
    // 但退出后还在用户注册表里留一个空键没有必要，一并清掉。
    // 失败无所谓：说明这个键本来就不存在，或用户在里面放了别的东西。
    RegDeleteKeyW(HKEY_CURRENT_USER, L"Software\\XVPN");
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

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
  // （进程被强杀时收不到这条消息，由下次启动时的兜底逻辑处理。）
  if (message == WM_DESTROY) {
    RestoreSystemProxy();
    TerminateChildProcesses();
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
