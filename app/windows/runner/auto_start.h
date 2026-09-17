#ifndef RUNNER_AUTO_START_H_
#define RUNNER_AUTO_START_H_

#include <string>

namespace auto_start {

// 「随系统启动」的后端。
//
// 有两套，**必须按运行形态二选一**，不能只留一套：
//
//   * 未打包（绿色解压 / zip 分发）：HKCU\...\CurrentVersion\Run 写一个值。
//     这是本项目一直以来的做法。
//   * MSIX 包内：Run 键**写不进去**。打包应用的注册表写入会被重定向到包私有
//     视图（`HKCU\Software\Classes\ActivatableClasses\...` 之外的一切都进虚拟
//     存储），而 Windows **不会**为虚拟存储里的 Run 项创建登录启动项。于是
//     「开关拨过去了、写注册表也返回成功，下次开机却什么也没发生」——一个没有
//     任何报错的静默失败，正是本项目最不能接受的形态。打包形态只能用
//     `Windows.ApplicationModel.StartupTask`（配合清单里的 windows.startupTask
//     扩展），把启动项交给系统托管。
enum class Mode {
  // 未打包：写注册表 Run 键。
  kRegistry,
  // 已打包（MSIX）：走 StartupTask。
  kStartupTask,
};

// 当前进程处于哪种形态。判定依据是 GetCurrentPackageFullName：未打包时它返回
// APPMODEL_ERROR_NO_PACKAGE，包裹与否是系统给出的权威答案，不靠猜。
//
// 它在整个进程生命周期里不会变，但**不做缓存**：这个函数极便宜，而缓存一旦与
// 真实形态不符（例如将来加了「免安装包直接跑」的路径），错误会以「开关失灵」
// 的形式出现在用户机器上，而不是在这里。
Mode CurrentMode();

// 当前形态下后端是否可用。
//
// 打包形态里若拿不到 StartupTask 的激活工厂（清单没声明 windows.startupTask
// 扩展时正是如此），返回 false。此时界面必须把开关显示成**不可用**并说明原因，
// 而不是让用户拨一个不会有任何效果的开关。
//
// 它**是同步的**：只创建激活工厂，不等任何异步操作。
bool IsSupported();

// 读当前状态。**同步**——内部把异步操作等到完成（等待期间泵消息，见实现里
// 对三条错路的记录）。失败一律当作「没开」：把「读不出来」显示成「已开启」
// 会让用户以为已经生效，而那正是这一项最不该出现的错法。
bool QueryEnabled();

// 写状态。返回**回读到的最终状态**是否等于 [enabled]。
//
// 打包形态下 RequestEnableAsync 是异步的，且可能被系统拒绝
// （DisabledByPolicy）或需要用户去「设置 → 应用 → 启动」放行，因此返回值不是
// 「请求发出去了」，而是「回读确认已经是这个状态」。
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
