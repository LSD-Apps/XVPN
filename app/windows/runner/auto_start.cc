// 见 auto_start.h 顶部的说明：这是「随系统启动」唯一的后端——HKCU 下的 Run 键。
//
// 它只有几十行，但每一条判断都对应一个真实踩过的坑，改动前请先读注释：
//   * 写入的命令必须给可执行文件路径加引号（路径里有空格时，Run 项会被拆成
//     「命令 + 参数」，开机时闪一个找不到文件的错误框）；
//   * 「开着」的判据是「Run 键里的值确实指向我们自己」，不是「值存在」
//     （残留的旧路径会让界面显示成已开启，而每次开机都在报错）；
//   * 删除时「本来就没有这个值」也算成功（用户要的结果已经成立）。

#include "auto_start.h"

#include <windows.h>

#include <string>

namespace auto_start {

// 注册表 Run 键下面的值名。用户能在「任务管理器 → 启动」里看到它，
// 因此用产品名而不是可执行文件名。
constexpr const wchar_t kRunValueName[] = L"幽门";

constexpr const wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

const wchar_t kAutoStartFlag[] = L"--autostart";

namespace {

std::wstring ExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD written =
        GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (written == 0) {
      return std::wstring();
    }
    if (written < path.size()) {
      path.resize(written);
      return path;
    }
    // 长路径（>= MAX_PATH）时返回值等于缓冲区长度，扩容再试。
    path.resize(path.size() * 2);
  }
}

bool RegistryIsEnabled() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  wchar_t buffer[2048] = {};
  DWORD size = sizeof(buffer);
  DWORD type = 0;
  const LSTATUS status = RegQueryValueExW(
      key, kRunValueName, nullptr, &type, reinterpret_cast<BYTE*>(buffer),
      &size);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS || type != REG_SZ) {
    return false;
  }
  // 存在**且确实指向我们自己**才算开着。只判「值存在」会让一个残留的、指向旧
  // 安装路径（甚至已被删除的目录）的启动项在界面上显示成「已开启」，而它每次
  // 开机都在报错——用户看到开关是开的，实际什么也没启动。
  const std::wstring expected = QuotedExecutablePath();
  return !expected.empty() && _wcsicmp(buffer, expected.c_str()) == 0;
}

bool RegistrySetEnabled(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE,
                      nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }

  LSTATUS status = ERROR_SUCCESS;
  if (enabled) {
    const std::wstring command = QuotedExecutablePath() + L" " + kAutoStartFlag;
    if (command.size() <= 1) {
      // QuotedExecutablePath 拿不到路径时只返回一对引号，写进去等于写了个空命令。
      RegCloseKey(key);
      return false;
    }
    status = RegSetValueExW(
        key, kRunValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, kRunValueName);
    // 本来就没有这个值也是成功：用户要的结果（开机不启动）已经成立。
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

}  // namespace

// ---------------------------------------------------------------- 对外接口

std::wstring QuotedExecutablePath() {
  const std::wstring path = ExecutablePath();
  if (path.empty()) {
    return std::wstring();
  }
  return L"\"" + path + L"\"";
}

bool IsSupported() {
  // 只需要一个可写的 HKCU，没有额外前提。因此「随系统启动」在 Windows 上总是
  // 可用；这个函数保留下来是为了通道契约（Dart 侧问一次能力，而不是按平台猜）。
  return true;
}

bool QueryEnabled() {
  return RegistryIsEnabled();
}

bool SetEnabled(bool enabled) {
  const bool ok = RegistrySetEnabled(enabled);
  // 回读而不是直接用写入结果：写成功与「开机真的会启动」之间还隔着「值确实
  // 指到我们自己」这一步，而这里要回答的就是后者。
  return ok && (RegistryIsEnabled() == enabled);
}

}  // namespace auto_start
