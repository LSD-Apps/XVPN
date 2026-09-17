// 见 auto_start.h 顶部的说明：这个是「随系统启动」的两套后端。
//
// 为什么手写「函数指针 + 上下文」而不是 std::function、为什么不用 C++/WinRT
// 的 winrt:: 投影：runner 的编译设置里有 `_HAS_EXCEPTIONS=0`
// （见 windows/CMakeLists.txt），而 C++/WinRT 的投影依赖异常报告失败。
// 这里用的是 SDK 原生的 **ABI 接口**（windows.applicationmodel.h / asyncinfo.h），
// 它们本身不需要异常——`_HAS_EXCEPTIONS=0` 下可以正常包含与实现。
//
// 所需运行库（RoGetActivationFactory / WindowsCreateString）来自 Windows 自带的
// combase，链接项为 runtimeobject.lib（见 windows/runner/CMakeLists.txt）。

#include "auto_start.h"

#include <windows.h>
#include <appmodel.h>
#include <asyncinfo.h>
#include <objidl.h>
#include <roapi.h>
#include <windows.applicationmodel.h>
#include <winstring.h>

#include <atomic>
#include <string>

namespace auto_start {

// 注册表 Run 键下面的值名。用户能在「任务管理器 → 启动」里看到它，
// 因此用产品名而不是可执行文件名。
constexpr const wchar_t kRunValueName[] = L"幽门";

constexpr const wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

const wchar_t kAutoStartFlag[] = L"--autostart";

// 清单 AppxManifest.xml 里 `windows.startupTask` 扩展的 TaskId。
// 两处必须逐字一致（清单见 app/packaging/AppxManifest.xml）。
constexpr const wchar_t kStartupTaskId[] = L"XVPNStartup";

namespace {

using ABI::Windows::ApplicationModel::IStartupTask;
using ABI::Windows::ApplicationModel::IStartupTaskStatics;
using ABI::Windows::ApplicationModel::StartupTaskState;
// 枚举取值是**命名空间作用域**的常量（`StartupTaskState_Enabled`），
// 不是 `StartupTaskState::Enabled` 那样的枚举类成员。
using ABI::Windows::ApplicationModel::StartupTaskState_Disabled;
using ABI::Windows::ApplicationModel::StartupTaskState_Enabled;
using ABI::Windows::ApplicationModel::StartupTaskState_EnabledByPolicy;
using ABI::Windows::Foundation::IAsyncOperation;

// MIDL 为 `IAsyncOperation<StartupTask*>` 生成的类型别名。**必须用宏形式的名字**
// （`__FIAsyncOperation_1_...`），不能写 `..._t`：后者是 typedef，在 using
// 声明里是语法错误。两个名字指向同一个类型。
using GetOperation =
    __FIAsyncOperation_1_Windows__CApplicationModel__CStartupTask;

// 引用计数 + 释放的样板。**刻意不引入 Microsoft::WRL::ComPtr**：那需要
// <wrl/client.h>，而 WRL 的头会连带一堆与 _HAS_EXCEPTIONS=0 冲突的定义。
template <typename T>
void SafeRelease(T** value) {
  if (*value != nullptr) {
    (*value)->Release();
    *value = nullptr;
  }
}

// 造 HSTRING。失败返回 nullptr，调用方一并把 nullptr 当作空串处理。
HSTRING MakeHString(const wchar_t* text) {
  HSTRING value = nullptr;
  const UINT32 length = static_cast<UINT32>(wcslen(text));
  if (FAILED(WindowsCreateString(text, length, &value))) {
    return nullptr;
  }
  return value;
}

// 取 Windows.ApplicationModel.StartupTask 的静态工厂。
//
// 拿不到只可能是一件事：当前包没有声明 `windows.startupTask` 扩展（清单漏了），
// 或进程根本没打包。两者都应当让界面把开关显示成不可用，而不是假装能用。
bool GetStartupTaskStatics(IStartupTaskStatics** statics) {
  *statics = nullptr;
  const HSTRING class_id =
      MakeHString(L"Windows.ApplicationModel.StartupTask");
  if (class_id == nullptr) {
    return false;
  }
  const HRESULT hr = RoGetActivationFactory(class_id,
                                            __uuidof(IStartupTaskStatics),
                                            reinterpret_cast<void**>(statics));
  WindowsDeleteString(class_id);
  return SUCCEEDED(hr) && *statics != nullptr;
}

// IAgileObject：回调要跨公寓时运行库会问一句「你是不是 agile」。空接口，
// 用同一个指针应答即可，这样不必真的实现 IMarshal 的封送。
constexpr GUID kGuidAgileObject = {
    0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};

// 完成回调：只做一件事——SetEvent 唤醒等待方。
//
// 只继承**一个**接口、不共享基类：这些接口是虚继承结构，多继承一个带
// IInspectable 的基类会让 vtable 错位。
//
// 两种实例化分别对应 `IAsyncOperation<StartupTask*>`（取任务对象）与
// `IAsyncOperation<StartupTaskState>`（启用请求的结果）。**不能用统一的
// `IAsyncOperationCompletedHandler<Y>` 模板去套**：SDK 只为具体类型生成了特化，
// 而 `IAsyncOperation<StartupTask*>` 那一支的特化名是
// `...CompletedHandler<StartupTask*>`，不是 `<IStartupTask*>`。
template <typename OperationT, typename HandlerInterfaceT>
class SignalHandler final : public HandlerInterfaceT {
 public:
  explicit SignalHandler(HANDLE done) : done_(done) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (IsEqualIID(iid, __uuidof(HandlerInterfaceT)) ||
        IsEqualIID(iid, __uuidof(IInspectable)) ||
        IsEqualIID(iid, __uuidof(IUnknown)) ||
        IsEqualIID(iid, kGuidAgileObject)) {
      // 交付 `this`：COM 对象指针与具体接口无关。
      *object = reinterpret_cast<IInspectable*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(++references_);
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining = static_cast<ULONG>(--references_);
    if (remaining == 0) {
      delete this;
    }
    return remaining;
  }

  HRESULT STDMETHODCALLTYPE Invoke(OperationT*, AsyncStatus) override {
    if (done_ != nullptr) {
      SetEvent(done_);
    }
    // 不在这里删自己：Invoke 返回后运行库还要用这个对象（至少还要走它的
    // vtable），在里面 delete 就是 use-after-free。对象由创建处释放。
    return S_OK;
  }

  // 不是 WinRT 运行时类型：没有 IID 表、没有类名。
  //
  // **不写 override**：MIDL 生成的 handler 接口经虚继承拿到 IInspectable，
  // MSVC 因此不把这三条当基类方法（C3668）。签名仍要与接口一致。
  HRESULT STDMETHODCALLTYPE GetIids(ULONG* count, IID** iids) {
    if (count != nullptr) *count = 0;
    if (iids != nullptr) *iids = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetRuntimeClassName(HSTRING* name) {
    if (name != nullptr) *name = nullptr;
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetTrustLevel(TrustLevel* level) {
    if (level != nullptr) *level = BaseTrust;
    return S_OK;
  }

 private:
  ~SignalHandler() = default;
  std::atomic<ULONG> references_{1};
  HANDLE done_ = nullptr;
};

using TaskSignalHandler = SignalHandler<
    IAsyncOperation<ABI::Windows::ApplicationModel::StartupTask*>,
    __FIAsyncOperationCompletedHandler_1_Windows__CApplicationModel__CStartupTask>;

using StateSignalHandler = SignalHandler<
    IAsyncOperation<StartupTaskState>,
    ABI::Windows::Foundation::IAsyncOperationCompletedHandler<StartupTaskState>>;

// 等一个异步操作完成。
//
// **只挂 `put_Completed`，不去问 `get_Status`。** 这一处踩过很深的坑：
// 为了「顺便看一眼进度」而手写 `IAsyncOperation<T>` 的 vtable，结果整个 ABI
// 复述是错的——SDK 里
//
//     struct IAsyncOperation_impl<TResult> : IInspectable
//
// 只有 `put_Completed` / `get_Completed` / `GetResults` **三个自有方法**，
// 根本没有 `IAsyncInfo` 的 `get_Status`（出处：windows.foundation.collections.h）。
// 于是「按自己以为的顺序调 get_Status」直接访问冲突（0xc0000005）。
// 结论：**不要复述异步接口的 vtable**，用 SDK 给的具体类型，只调确实存在的方法。
//
// 完成信号由事件给出，因此不需要轮询。`MsgWaitForMultipleObjectsEx` 是为了让
// 完成通知能派发到本线程（STA 上它常常以 sent 消息进来，只 PeekMessage 取不到）。
template <typename OperationT, typename HandlerInterfaceT>
void WaitForOperation(OperationT* operation) {
  if (operation == nullptr) {
    return;
  }
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (done == nullptr) {
    return;
  }
  auto* handler = new SignalHandler<OperationT, HandlerInterfaceT>(done);
  // 把派生类上转成接口指针交给 put_Completed。它的形参类型正是
  // `HandlerInterfaceT*`，因此这里既不需要 QueryInterface 也不需要 reinterpret。
  operation->put_Completed(static_cast<HandlerInterfaceT*>(handler));

  const DWORD deadline = GetTickCount() + 5000;
  for (;;) {
    if (WaitForSingleObject(done, 0) == WAIT_OBJECT_0) {
      break;
    }
    if (static_cast<long>(GetTickCount() - deadline) >= 0) {
      break;
    }
    // 等事件，同时把消息派发出去。
    MsgWaitForMultipleObjectsEx(1, &done, 50, QS_ALLINPUT,
                                MWMO_INPUTAVAILABLE);
    MSG msg = {};
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  // put_Completed 自己 AddRef 了一份（运行库负责释放）；这里释放创建时那一份。
  handler->Release();
  CloseHandle(done);
}

bool IsEnabledState(StartupTaskState state) {
  // Enabled / EnabledByPolicy 才算开着。DisabledByUser 与 DisabledByPolicy 都是
  // 「系统层面不启动」，界面必须如实显示为关。
  return state == StartupTaskState_Enabled ||
         state == StartupTaskState_EnabledByPolicy;
}

// 取 `StartupTask.GetAsync(TaskId)` 得到的任务对象。失败返回 nullptr。
IStartupTask* GetStartupTask() {
  IStartupTaskStatics* statics = nullptr;
  if (!GetStartupTaskStatics(&statics)) {
    return nullptr;
  }
  HSTRING task_id = MakeHString(kStartupTaskId);
  if (task_id == nullptr) {
    SafeRelease(&statics);
    return nullptr;
  }
  GetOperation* operation = nullptr;
  const HRESULT started = statics->GetAsync(task_id, &operation);
  WindowsDeleteString(task_id);
  SafeRelease(&statics);
  if (FAILED(started) || operation == nullptr) {
    return nullptr;
  }
  WaitForOperation<GetOperation,
                  __FIAsyncOperationCompletedHandler_1_Windows__CApplicationModel__CStartupTask>(operation);
  IStartupTask* task = nullptr;
  // 只有等到了完成通知才取结果；未完成时 GetResults 返回 E_PENDING。
  const HRESULT got = operation->GetResults(&task);
  SafeRelease(&operation);
  return FAILED(got) ? nullptr : task;
}

bool StartupTaskIsEnabled() {
  IStartupTask* task = GetStartupTask();
  if (task == nullptr) {
    return false;
  }
  StartupTaskState state = StartupTaskState_Disabled;
  const HRESULT got = task->get_State(&state);
  SafeRelease(&task);
  // 失败当作「没开」：把「读不出来」显示成「已开启」会让用户以为已经生效。
  return SUCCEEDED(got) && IsEnabledState(state);
}

// 写状态。`RequestEnableAsync` 也是异步的，等它完成后**回读**真实状态——
// 请求被受理不等于系统真的启用了它（可能被策略拒绝、也可能要用户去
// 「设置 → 应用 → 启动」放行）。
bool StartupTaskSetEnabled(bool enabled) {
  IStartupTask* task = GetStartupTask();
  if (task == nullptr) {
    return false;
  }
  bool applied = false;
  if (enabled) {
    IAsyncOperation<StartupTaskState>* enable = nullptr;
    const HRESULT requested = task->RequestEnableAsync(&enable);
    if (SUCCEEDED(requested) && enable != nullptr) {
      WaitForOperation<IAsyncOperation<StartupTaskState>,
                     ABI::Windows::Foundation::IAsyncOperationCompletedHandler<
                         StartupTaskState>>(enable);
      SafeRelease(&enable);
      applied = StartupTaskIsEnabled();
    }
  } else {
    // Disable() 是同步的。
    applied = SUCCEEDED(task->Disable()) && !StartupTaskIsEnabled();
  }
  SafeRelease(&task);
  return applied;
}

// ---------------------------------------------------------------- 注册表后端

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

Mode CurrentMode() {
  // 判定依据是 GetCurrentPackageFullName：未打包时它返回
  // APPMODEL_ERROR_NO_PACKAGE，包裹与否是系统给出的权威答案，不靠猜。
  //
  // 用长度探测而不是先分配：缓冲区不足时它返回 ERROR_INSUFFICIENT_BUFFER 并
  // 回填所需长度，一次调用即可判定。
  UINT32 length = 0;
  const LONG status = GetCurrentPackageFullName(&length, nullptr);
  return status == APPMODEL_ERROR_NO_PACKAGE ? Mode::kRegistry
                                             : Mode::kStartupTask;
}

std::wstring QuotedExecutablePath() {
  const std::wstring path = ExecutablePath();
  if (path.empty()) {
    return std::wstring();
  }
  return L"\"" + path + L"\"";
}

bool IsSupported() {
  if (CurrentMode() == Mode::kRegistry) {
    // 未打包形态只需要可写的 HKCU，没有额外前提。
    return true;
  }
  // 打包形态：清单里有没有声明 windows.startupTask，看激活工厂能否拿到。
  IStartupTaskStatics* statics = nullptr;
  const bool ok = GetStartupTaskStatics(&statics);
  SafeRelease(&statics);
  return ok;
}

bool QueryEnabled() {
  return CurrentMode() == Mode::kRegistry ? RegistryIsEnabled()
                                          : StartupTaskIsEnabled();
}

bool SetEnabled(bool enabled) {
  if (CurrentMode() == Mode::kRegistry) {
    const bool ok = RegistrySetEnabled(enabled);
    // 回读而不是直接用写入结果：写成功与「开机真的会启动」之间还隔着「值确实
    // 指到我们自己」这一步，而这里要回答的就是后者。
    return ok && (RegistryIsEnabled() == enabled);
  }
  return StartupTaskSetEnabled(enabled);
}

}  // namespace auto_start
