#ifndef RUNNER_AUTO_START_H_
#define RUNNER_AUTO_START_H_

#include <string>

// 「随系统启动」的后端。
//
// 只有一套：HKCU\...\CurrentVersion\Run 写一个值（绿色解压 / zip 分发）。
// 用户能在「任务管理器 → 启动」或「设置 → 应用 → 启动」里看到并随时改它，
// 因此**状态的事实来源在系统里**——每次启动与每次切换都由原生回读，Dart 侧
// 只保存一份供界面显示的镜像（见 app/lib/core/auto_start.dart）。
namespace auto_start {

// 当前形态下后端是否可用。
//
// 它**是同步的**：只回答「这个平台能不能做这件事」，不碰任何异步操作。
bool IsSupported();

// 读当前状态。**同步**。
//
// 失败一律当作「没开」：把「读不出来」显示成「已开启」会让用户以为已经生效，
// 而那正是这一项最不该出现的错法。
bool QueryEnabled();

// 写状态。返回**回读到的最终状态**是否等于 [enabled]。
//
// 不是「请求发出去了」，而是「回读确认已经是这个状态」：写进去的值可能不指向
// 我们自己（见实现里的判据），那种情况下界面不该显示成已开启。
bool SetEnabled(bool enabled);

// 把当前进程的可执行文件路径写成 `"C:\...\xvpn.exe"`（含引号）。
//
// 路径里可能有空格，不加引号时注册表 Run 项会被拆成「命令 + 参数」，
// 而前半截多半根本不存在——表现为开机时闪一个找不到文件的错误框。
std::wstring QuotedExecutablePath();

// 「开机自启」启动应用时附加的命令行开关。
//
// 只用一个明示的开关，不做「静默启动」之类的推断：将来若要支持「自启时不显示
// 主窗口」，判断条件是命令行的显式事实，而不是环境里那些不可靠的旁证。
extern const wchar_t kAutoStartFlag[];

}  // namespace auto_start

#endif  // RUNNER_AUTO_START_H_
