#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <tlhelp32.h>
#include <wininet.h>

#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "auto_start.h"
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


// 「我们改过、但还没还原」的痕迹是否存在。
bool HasProxyBackup() {
  DWORD saved = 0;
  return ReadRegistryDword(HKEY_CURRENT_USER, kProxyBackupKey, L"Saved", &saved) &&
         saved == 1;
}

// 消费掉备份（表示「我们不再持有系统代理的还原点」）。
//
// 优先整个删掉；但**删完必须回读确认**——`RegDeleteTreeW` 返回成功不等于值真的
// 没了（注册表写入可能被重定向或延迟落地）。若不做回读，后果是下一次启动又把一个
// 过期的备份当成「上次没退干净」，去还原一个早就不存在的状态。
//
// 删不掉时就地作废：把 `Saved` 置 0。`HasProxyBackup()` 正是按这个标记判断的，
// 因此作废与删除等价。
void ConsumeProxyBackup() {
  RegDeleteTreeW(HKEY_CURRENT_USER, kProxyBackupKey);
  if (!HasProxyBackup()) {
    // 删干净了，顺带收掉创建它时生成的容器键。
    // 失败无所谓：说明这个键本来就不存在，或用户在里面放了别的东西。
    RegDeleteKeyW(HKEY_CURRENT_USER, L"Software\\XVPN");
    return;
  }
  // 没删掉 —— 就地作废。
  SetRegistryDword(HKEY_CURRENT_USER, kProxyBackupKey, L"Saved", 0);
}

// 让 WinINET 重新读取代理设置。
//
// **只写注册表是不够的**：WinINET 把代理配置缓存在进程内，写完不通知它，正在
// 运行的浏览器不会立刻改用新代理。这两条 INTERNET_OPTION_* 就是官方的刷新信号
// （`InternetSetOptionW(..., INTERNET_OPTION_SETTINGS_CHANGED, ...)` 通知配置变了，
// `INTERNET_OPTION_REFRESH` 让它丢弃缓存重新读取）。
bool RefreshWinInetProxy() {
  const bool settings_changed =
      InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  const bool refreshed =
      InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return settings_changed || refreshed;
}

// 用 WinINET 接口把「每连接代理」设成给定值。server 为空表示直连（不设代理）。
//
// **还原也必须走这条**，不能只写注册表：只写注册表不会让正在运行的程序立刻改用
// 直连（它们的代理配置缓存在自己进程里），而还原失败留下的状态最坏——**内核已经
// 退出、代理还指着一个死端口**，机器上所有走系统代理的程序全部断网，而且从注册表
// 里看不出是 VPN 干的。
bool ApplyWinInetProxy(const std::wstring& server) {
  INTERNET_PER_CONN_OPTION_LISTW list = {};
  INTERNET_PER_CONN_OPTIONW options[2] = {};
  list.dwSize = sizeof(list);
  list.pszConnection = nullptr;  // nullptr = 局域网设置（默认连接）
  list.dwOptionCount = 2;
  list.pOptions = options;
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = server.empty()
                                 ? static_cast<DWORD>(PROXY_TYPE_DIRECT)
                                 : static_cast<DWORD>(PROXY_TYPE_DIRECT |
                                                      PROXY_TYPE_PROXY);
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<LPWSTR>(server.c_str());
  const bool set = InternetSetOptionW(
      nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list));
  const bool refreshed = RefreshWinInetProxy();
  return set || refreshed;
}



// 接管系统代理：先把用户原有设置备份到我们自己的注册表键，再写入内核地址。
//
// ## 为什么必须以「回读到的系统真实状态」为准，而不是写入调用的返回值
//
// `RegSetValueExW` 返回 `ERROR_SUCCESS` 只说明这次调用被受理了，不说明系统里
// 的值真的变成了我们写的那样（写入可能落到别处、或延迟落地）。实测过这个后果：
//
//     应用自己回读 HKCU\...\Internet Settings\ProxyEnable → 1
//     外部 reg query 同一个键                              → 0x0
//
// 也就是说「写成功了」是假的：系统代理**从来没有真正设置过**。而界面上的
// 「系统代理已自动设置」是按内核连上了就打的勾，于是用户看到的是「连上了、
// 代理也设好了」，实际所有流量都在直连——一个完全没有报错的静默失效，
// 而用户以为流量走了隧道（对 VPN 来说这是最严重的一类错法）。
//
// 因此这里除了写注册表，还走 WinINET 官方接口，并**以它的结果为准**；对不上就
// 返回 false，让上层如实报出「无法设置系统代理」。宁可说一句实话，也不要显示
// 一个假装生效的勾。
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
  // 除了写注册表，再用 WinINET 官方接口设一遍，并**以它的结果为准**。
  //
  // 为什么不能只写注册表：`RegSetValueExW` 返回 `ERROR_SUCCESS` 只说明这次调用
  // 被受理了，不说明系统里的值真的变了（实测见过「应用自己回读是 1、外部
  // reg query 是 0」），而正在运行的程序也不会因此立刻改用新代理——WinINET 把
  // 代理配置缓存在进程内，得靠 INTERNET_OPTION_SETTINGS_CHANGED / REFRESH 通知
  // 它重新读取。
  //
  // 后果就是最坏的一类错法：界面打勾说「系统代理已自动设置」，实际所有流量都在
  // 直连——没有报错、看不出异常，而用户以为流量走了隧道。
  const bool applied = ApplyWinInetProxy(server);
  return ok && applied;
}

// 还原系统代理。没有备份时只关掉代理开关，不动用户的其它设置。
bool RestoreSystemProxy() {
  bool ok = true;
  std::wstring restore_server;  // 空 = 直连
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
      // 用户原本有代理：还原成他那一个。
      if (enable != 0) restore_server = server;
    } else {
      // 用户原本没有 ProxyServer 这个值。必须把它删掉而不是留着，
      // 否则会残留一个指向已退出内核的地址，误导其它读取该值的程序。
      DeleteRegistryValue(HKEY_CURRENT_USER, kInternetSettings,
                          L"ProxyServer");
    }
    // 走 WinINET 让**系统**也真的改过来（见 ApplyWinInetProxy 的说明）。
    ok = ApplyWinInetProxy(restore_server) && ok;
    // **只有还原成功才消费备份。**
    //
    // 反过来（无条件删）有一个很难查的后果：万一上面写注册表失败（权限受限、
    // 组策略锁定），备份被删掉了、代理却仍指着已经退出的内核。下次启动时
    // HasProxyBackup() 为假，兜底恢复无从下手，用户的网络就一直坏着——而且
    // 从注册表里看不出任何线索。留着备份，至少下次启动还能再试一次。
    if (ok) {
      // 消费掉备份。它会**回读确认**，删不掉就地作废——见 ConsumeProxyBackup
      // 的说明。
      ConsumeProxyBackup();
    }
  } else {
    ok = SetRegistryDword(HKEY_CURRENT_USER, kInternetSettings, L"ProxyEnable",
                          0) &&
         ApplyWinInetProxy(std::wstring());
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

// ---------------------------------------------------------------- 托盘图标

// Dart 侧的状态文案是 UTF-8（含中文），必须走 MultiByteToWideChar 转宽字符。
//
// 之前的 setSystemProxy 参数是 "host:port"（纯 ASCII），可以直接
// std::wstring(begin(), end()) 逐字节扩展；换成状态文案后用那种写法会得到乱码。
std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr,
                                       0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), size);
  return wide;
}

const flutter::EncodableValue* MapValue(const flutter::EncodableMap& map,
                                        const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::string MapString(const flutter::EncodableMap& map, const char* key) {
  const flutter::EncodableValue* value = MapValue(map, key);
  if (value == nullptr) {
    return std::string();
  }
  const std::string* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

// 取一个布尔字段。字段缺失时返回 [fallback]——Dart 侧按需附带这些键，
// 「没带」与「false」必须区分得开。
bool MapBool(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const flutter::EncodableValue* value = MapValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const bool* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

// 用 32 位 BGRA 像素造一个 HICON。
HICON IconFromPixels(int width, int height,
                     const std::vector<uint32_t>& pixels) {
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  // 负高度 = top-down，像素顺序与 pixels 一致（左上角在前）。
  bmi.bmiHeader.biHeight = -height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  HDC screen = GetDC(nullptr);
  void* bits = nullptr;
  HBITMAP color =
      CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (screen != nullptr) {
    ReleaseDC(nullptr, screen);
  }
  if (color == nullptr || bits == nullptr) {
    if (color != nullptr) {
      DeleteObject(color);
    }
    return nullptr;
  }
  memcpy(bits, pixels.data(), pixels.size() * sizeof(uint32_t));

  // 颜色位图自带 alpha 时掩码全 0：是否透明完全由 alpha 决定。
  //
  // 掩码显式传一块零缓冲而不是 CreateBitmap(..., nullptr)：后者的文档写的是
  // 「内容未定义」，虽然实测会清零，但这里不值得把图标能不能画出来押在
  // 一个未定义行为上。1bpp 的行跨距按 16 像素对齐。
  const size_t mask_stride = ((static_cast<size_t>(width) + 15) / 16) * 2;
  const std::vector<uint8_t> empty_mask(mask_stride * height, 0);
  HBITMAP mask = CreateBitmap(width, height, 1, 1, empty_mask.data());
  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmColor = color;
  info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(color);
  if (mask != nullptr) {
    DeleteObject(mask);
  }
  return icon;
}

// 把图标去饱和，做「未连接」用的灰色变体。失败返回 nullptr。
//
// 用 GetIconInfo + GetDIBits 直接读图标的 32 位像素，而不是把图标
// DrawIconEx 到一块 DIB 上再处理：后者在部分系统/图标格式下不会写入 alpha
// 通道，得到的是一张**全透明**的图标——托盘上会直接看不见图标，而不是变灰。
//
// 读到的 alpha 若全为 0（图标本身没有 alpha 通道），同样返回 nullptr 交给调用方
// 退回彩色图标：最坏情况是「没变灰」，而不是「图标消失」。
HICON CreateDesaturatedIcon(HICON source) {
  ICONINFO info = {};
  if (!GetIconInfo(source, &info)) {
    return nullptr;
  }

  HICON result = nullptr;
  BITMAP bitmap = {};
  if (info.hbmColor != nullptr &&
      GetObjectW(info.hbmColor, sizeof(bitmap), &bitmap) != 0) {
    const int width = bitmap.bmWidth;
    const int height = bitmap.bmHeight;
    if (width > 0 && height > 0) {
      std::vector<uint32_t> pixels(static_cast<size_t>(width) * height, 0);
      BITMAPINFO bmi = {};
      bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      bmi.bmiHeader.biWidth = width;
      bmi.bmiHeader.biHeight = -height;
      bmi.bmiHeader.biPlanes = 1;
      bmi.bmiHeader.biBitCount = 32;
      bmi.bmiHeader.biCompression = BI_RGB;

      HDC screen = GetDC(nullptr);
      const int scanned = GetDIBits(screen, info.hbmColor, 0, height,
                                    pixels.data(), &bmi, DIB_RGB_COLORS);
      if (screen != nullptr) {
        ReleaseDC(nullptr, screen);
      }

      if (scanned == height) {
        bool has_alpha = false;
        for (uint32_t& pixel : pixels) {
          const uint32_t alpha = pixel & 0xFF000000u;
          if (alpha != 0) {
            has_alpha = true;
          }
          const int blue = static_cast<int>(pixel & 0xFFu);
          const int green = static_cast<int>((pixel >> 8) & 0xFFu);
          const int red = static_cast<int>((pixel >> 16) & 0xFFu);
          // Rec.601 亮度权重，与 GDI 的去饱和（ColorMatrix）口径一致。
          const int luminance =
              (red * 299 + green * 587 + blue * 114) / 1000;
          pixel = alpha | (static_cast<uint32_t>(luminance) << 16) |
                  (static_cast<uint32_t>(luminance) << 8) |
                  static_cast<uint32_t>(luminance);
        }
        if (has_alpha) {
          result = IconFromPixels(width, height, pixels);
        }
      }
    }
  }

  // GetIconInfo 会创建两张位图，用完必须由我们释放。
  if (info.hbmColor != nullptr) {
    DeleteObject(info.hbmColor);
  }
  if (info.hbmMask != nullptr) {
    DeleteObject(info.hbmMask);
  }
  return result;
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
        } else if (method == "setTrayState") {
          // 托盘状态由 Dart 在状态变化时推来一次（见 core/system_tray.dart），
          // 原生不轮询、也不自己查更新。
          const flutter::EncodableMap* state =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (state == nullptr) {
            result->Error("bad_args", "setTrayState 需要一个状态表");
            return;
          }
          ApplyTrayState(*state);
          result->Success();
        } else if (method == "autoStartSupported") {
          // 界面据此决定「开机自动启动」那个开关是可用还是灰着。
          //
          // 这里由原生回答而不是 Dart 按平台猜：能不能做这件事取决于原生后端
          // 在当前平台上的实现（Windows 有注册表 Run 键；Linux 尚未落地）。
          // 这是运行期的事实，只有原生知道。
          result->Success(flutter::EncodableValue(auto_start::IsSupported()));
        } else if (method == "getAutoStart") {
          // 读的是**系统里的真实状态**，不是 Dart 存档里的镜像：用户可能在
          // 「任务管理器 → 启动」或「设置 → 应用 → 启动」里改过，存档里的值
          // 此时已经不对了。
          //
          // 同步回：读一个注册表值即可，不会阻塞。
          result->Success(flutter::EncodableValue(auto_start::QueryEnabled()));
        } else if (method == "setAutoStart") {
          const bool* enabled = std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("bad_args", "setAutoStart 需要一个布尔值");
            return;
          }
          const bool supported = auto_start::IsSupported();
          if (supported) {
            // 落地之后再回：返回值是**回读确认的最终状态**，不是「请求发出了」。
            // 直接回 true 会让界面显示一个「开了但其实没开」的开关。
            const bool applied = auto_start::SetEnabled(*enabled);
            // 让托盘菜单的勾与设置页的开关跟上同一个事实。
            tray_auto_start_ = applied;
            NotifyAutoStartChanged();
            result->Success(flutter::EncodableValue(applied));
          }
          else {
            result->Success(flutter::EncodableValue(false));
          }
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
  tray_icon_.hIcon = NormalTrayIcon();
  // 首帧之前 Dart 还没推来状态，先用品牌名占位；一旦收到 setTrayState
  // （很快，外壳 initState 就会推一次）就会换成「幽门 <版本> · <状态>」。
  wcscpy_s(tray_icon_.szTip, L"幽门 · 智能分流");
  tray_installed_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_installed_) {
    // Vista+ 用 VERSION_4：气泡与点击回调行为更稳定；失败也不影响托盘本身。
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_installed_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_installed_ = false;
  }
  // 无论通知区那一项是否真的加成功，句柄都在这里释放：NIM_ADD 失败时
  // 上面那两个图标仍然是已加载的，不能泄漏。
  DestroyTrayIcons();
}

int FlutterWindow::TrayIconSize() {
  // 通知区图标要按当前 DPI 选尺寸。清单里声明了 PerMonitorV2（见
  // runner.exe.manifest），系统不会替我们缩放，因此必须自己算：100% 是
  // 16px，150% 是 24px，200% 是 32px。
  //
  // DPI 取自窗口所在显示器，用的是 runner 里已有的
  // FlutterDesktopGetDpiForMonitor（见 win32_window.cpp），不额外依赖
  // GetDpiForWindow / GetSystemMetricsForDpi 这类需要较新 SDK 才声明的 API。
  constexpr int kBaseSize = 16;  // 100% DPI 下 SM_CXSMICON 的值。
  HWND handle = GetHandle();
  UINT dpi = 0;
  if (handle != nullptr) {
    dpi = FlutterDesktopGetDpiForMonitor(
        MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST));
  }
  if (dpi == 0) {
    dpi = 96;
  }
  const int size = MulDiv(kBaseSize, static_cast<int>(dpi), 96);
  return size > 0 ? size : kBaseSize;
}

HICON FlutterWindow::NormalTrayIcon() {
  if (tray_icon_normal_ != nullptr) return tray_icon_normal_;
  const int size = TrayIconSize();
  // 按 DPI 显式选尺寸加载：LoadIconW 只会给出系统默认的图标尺寸，
  // 在 150% / 200% 缩放下托盘会拿到一张被放大的模糊图。
  tray_icon_normal_ = static_cast<HICON>(
      LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                 IMAGE_ICON, size, size, 0));
  tray_normal_owned_ = tray_icon_normal_ != nullptr;
  if (tray_icon_normal_ == nullptr) {
    // 资源图标取不到时退回系统默认图标。它是共享句柄，**不能** DestroyIcon。
    tray_icon_normal_ = LoadIconW(nullptr, IDI_APPLICATION);
  }
  return tray_icon_normal_;
}

HICON FlutterWindow::GreyTrayIcon() {
  if (tray_icon_grey_ != nullptr) return tray_icon_grey_;
  const HICON source = NormalTrayIcon();
  if (source == nullptr) return nullptr;
  tray_icon_grey_ = CreateDesaturatedIcon(source);
  return tray_icon_grey_;
}

void FlutterWindow::DestroyTrayIcons() {
  if (tray_icon_normal_ != nullptr && tray_normal_owned_) {
    DestroyIcon(tray_icon_normal_);
  }
  tray_icon_normal_ = nullptr;
  tray_normal_owned_ = false;
  if (tray_icon_grey_ != nullptr) {
    DestroyIcon(tray_icon_grey_);
  }
  tray_icon_grey_ = nullptr;
}

void FlutterWindow::UpdateTrayIcon() {
  std::wstring tooltip = L"幽门";
  if (!tray_version_.empty()) {
    tooltip += L" " + tray_version_;
  }
  if (!tray_status_.empty()) {
    tooltip += L" · " + tray_status_;
  }
  // 已连接时附上下行/上行速率，最小化到托盘后仍能一眼看到「现在有没有在跑」。
  if (tray_connected_ && (!tray_down_rate_.empty() || !tray_up_rate_.empty())) {
    tooltip += L" · ↓" + tray_down_rate_ + L" ↑" + tray_up_rate_;
  }
  if (!tray_update_.empty()) {
    tooltip += L" · 发现新版本 v" + tray_update_;
  }
  // szTip 是定长数组（含结尾 0 共 128 个宽字符）。用 _TRUNCATE 而不是报错：
  // tooltip 少了尾巴也不该让整次图标更新失败。
  wcsncpy_s(tray_icon_.szTip, tooltip.c_str(), _TRUNCATE);

  // 只有「已连接」用彩色图标；未连接 / 连接中 / 建立隧道中一律灰掉，
  // 让「现在是不是真的在隧道里」在最小化到托盘后也能一眼看到。
  //
  // 灰度图标做不出来时（图标没有 alpha 通道等）退回彩色图标：宁可「没灰」，
  // 也不能把 hIcon 留成一个刚被 DestroyTrayIcons 释放掉的悬空句柄。
  HICON desired = tray_connected_ ? NormalTrayIcon() : GreyTrayIcon();
  if (desired == nullptr) {
    desired = NormalTrayIcon();
  }
  if (desired != nullptr) {
    tray_icon_.hIcon = desired;
  }
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;

  // Shell_NotifyIcon 会把图标**复制**一份，因此这里换掉/释放旧句柄是安全的。
  if (tray_installed_) {
    Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
  }
}

void FlutterWindow::ApplyTrayState(const flutter::EncodableMap& state) {
  tray_version_ = Utf8ToWide(MapString(state, "version"));
  tray_status_ = Utf8ToWide(MapString(state, "status"));
  tray_update_ = Utf8ToWide(MapString(state, "updateVersion"));
  tray_down_rate_ = Utf8ToWide(MapString(state, "downRate"));
  tray_up_rate_ = Utf8ToWide(MapString(state, "upRate"));
  tray_connected_ = MapBool(state, "connected", false);
  tray_auto_start_supported_ = MapBool(state, "autoStartSupported", false);
  tray_auto_start_ = MapBool(state, "autoStart", false);
  UpdateTrayIcon();
}


void FlutterWindow::NotifyAutoStartChanged() {
  if (!window_channel_) return;
  window_channel_->InvokeMethod(
      "autoStartChanged",
      std::make_unique<flutter::EncodableValue>(tray_auto_start_));
}

void FlutterWindow::ShowMainWindow() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;
  ShowWindow(handle, SW_SHOW);
  ShowWindow(handle, SW_RESTORE);
  SetForegroundWindow(handle);
}

void FlutterWindow::NotifyRunningInBackground() {
  if (!tray_installed_) return;

  // 文案分两档：已连接时强调隧道未断——这正是用户最容易误以为「关窗=断开」
  // 的时刻；未连接时只说明进程还在，避免「后台运行」听起来像还在代理流量。
  const wchar_t* body = tray_connected_
      ? L"已收至系统托盘，隧道仍在后台保持连接。点击托盘图标可打开，右键可退出。"
      : L"已收至系统托盘，程序仍在后台运行。点击托盘图标可打开，右键可退出。";

  tray_icon_.uFlags = NIF_INFO | NIF_ICON | NIF_MESSAGE | NIF_TIP;
  wcsncpy_s(tray_icon_.szInfoTitle, L"幽门", _TRUNCATE);
  wcsncpy_s(tray_icon_.szInfo, body, _TRUNCATE);
  tray_icon_.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);

  // 立刻清掉气泡字段：否则随后 UpdateTrayIcon（已连接时约每秒一次）再
  // NIM_MODIFY 时，若仍带着 NIF_INFO / 旧正文，会反复弹出。
  tray_icon_.szInfo[0] = L'\0';
  tray_icon_.szInfoTitle[0] = L'\0';
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
}

void FlutterWindow::ShowTrayMenu() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;

  // 弹菜单之前**回读一次系统里的真实状态**，而不是直接用 tray_auto_start_。
  //
  // 为什么必须回读：`tray_auto_start_` 只在两个时刻被赋值——Dart 推来托盘载荷，
  // 或本进程自己切换完。而这一项的事实**在系统里**：用户随时能在
  // 「任务管理器 → 启动」或「设置 → 应用 → 启动」里改它，应用完全不知情。
  // 实测踩到过：系统里已经是「关」，而应用里的镜像还停在「开」——于是托盘菜单
  // 的勾与真实状态相反，用户点它一下反而什么都没变（因为它以为要关，
  // 而系统本来就已经关了）。这正是「托盘点了没对接上」的那种体感。
  //
  // 回读之后若与镜像不一致，顺手把镜像和 Dart 都校准过来，让设置页也跟着对齐。
  if (tray_auto_start_supported_) {
    const bool live = auto_start::QueryEnabled();
    if (live != tray_auto_start_) {
      tray_auto_start_ = live;
      NotifyAutoStartChanged();
    }
  }

  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;

  // 菜单结构（与 Linux 托盘对齐）：
  //   显示主界面
  //   ──
  //   开机自动启动（复选；后端不可用时灰掉）
  //   ──
  //   <连接状态>（灰，纯信息；有则显示）
  //   幽门 <版本>（灰，纯信息；有则显示）
  //   发现新版本…（可点；有更新才显示，不依赖版本项是否出现）
  //   ──
  //   退出幽门
  //
  // 「发现新版本」必须可点：它承载的是可操作信息。此前版本项与更新项绑在
  // 同一个 if (version) 里——版本字段偶发缺失时，更新入口会一起消失。
  AppendMenuW(menu, MF_STRING, kTrayMenuShow, L"显示主界面");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  {
    // 复选菜单项：勾选状态来自 Dart 推送的托盘载荷，用户在设置页拨开关后
    // 下一次推送就会同步到这里——两处永远是同一个事实。
    //
    // 后端不可用时**灰掉而不是隐藏**：隐藏会让「为什么没有这一项」无从解释，
    // 灰掉配合 tooltip 之外的一句说明至少表明它存在但当前形态用不了。
    UINT flags = MF_STRING;
    if (!tray_auto_start_supported_) {
      flags |= MF_GRAYED;
    } else if (tray_auto_start_) {
      flags |= MF_CHECKED;
    }
    AppendMenuW(menu, flags, kTrayMenuAutoStart, L"开机自动启动");
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  if (!tray_status_.empty()) {
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, tray_status_.c_str());
  }
  if (!tray_version_.empty()) {
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0,
                (L"幽门 " + tray_version_).c_str());
  }
  if (!tray_update_.empty()) {
    AppendMenuW(menu, MF_STRING, kTrayMenuUpdate,
                (L"发现新版本 v" + tray_update_ + L"（打开更新界面）")
                    .c_str());
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayMenuQuit, L"退出幽门");

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
  // 返回 0 会阻止默认的销毁流程；真正退出只能走托盘菜单的「退出幽门」。
  if (message == WM_CLOSE) {
    const bool was_visible = IsWindowVisible(hwnd) != FALSE;
    ShowWindow(hwnd, SW_HIDE);
    // 仅首次收进托盘时气泡提示：用户已在托盘里时再关一次（例如脚本）不刷屏。
    if (was_visible) {
      NotifyRunningInBackground();
    }
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
      case kTrayMenuAutoStart: {
        if (!tray_auto_start_supported_) {
          return 0;
        }
        // 同步切换；返回值是**回读确认的最终状态**，不是「请求发出去了」。
        const bool wanted = !tray_auto_start_;
        const bool applied = auto_start::SetEnabled(wanted);
        // 用回读到的值更新勾：点下去的意图与系统最终接受的可能是两回事
        // （策略拒绝、需要用户去系统设置里放行）。
        tray_auto_start_ = applied;
        // 让设置页的开关跟上同一个事实，否则同一边显示为开、另一边显示为关。
        NotifyAutoStartChanged();
        return 0;
      }
      case kTrayMenuUpdate:
        // 先把窗口亮出来，再让 Dart 切到设置页的「版本更新」卡片。
        // 两步都做：只切页而不显示窗口的话，用户点的东西"没反应"
        // （窗口还在托盘里）；只显示窗口而不切页的话，用户还得自己找。
        ShowMainWindow();
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "trayOpenUpdate",
              std::make_unique<flutter::EncodableValue>());
        }
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

  // 换到不同 DPI 的显示器之后，缓存的托盘图标是旧尺寸的。丢掉重建并按新
  // DPI 更新一次通知区。
  //
  // **不 return**：窗口自身的缩放与定位还要交给基类
  // （Win32Window::MessageHandler 的 WM_DPICHANGED 分支）。
  if (message == WM_DPICHANGED) {
    DestroyTrayIcons();
    UpdateTrayIcon();
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
