# Android 端接入说明

本文记录安卓端内核的编译链路、libbox 的 API 面，以及 VpnService 的实现方案。
所有签名都由 `javap` 从实际编译出的 AAR 中读取，不是照抄文档。

## 一、为什么安卓端不能像 Windows 那样跑独立进程

Windows 端把 sing-box 作为**子进程**启动即可。安卓端不行，两条硬性限制：

1. **Android 10 起禁止执行应用数据目录下的可执行文件**（W^X 限制），
   把 `sing-box` 二进制放进 assets 再 chmod +x 是行不通的。
2. **VpnService 的 TUN 文件描述符只能在应用进程内创建**，
   外部进程拿不到那个 fd，内核就无法接管流量。

因此安卓端必须把 sing-box 作为**库**（libbox）嵌入应用进程，
由 Kotlin 侧实现 `VpnService` 并把 TUN 交给库。这正是官方 SFA 的做法。

## 二、编译链路

`scripts/build-libbox.ps1` 负责从 sing-box 源码编译出 `libbox.aar`。
编译过程中依次踩到四个坑，全部已解决：

| # | 现象 | 原因 | 解法 |
| --- | --- | --- | --- |
| 1 | `flutter`/`go` 命令找不到模块 | 没有模块上下文 | 先建一个临时模块再 `go get` |
| 2 | sing-box 要求 Go ≥ 1.25.5，本机 1.23.5 | 版本不足 | 设 `GOTOOLCHAIN=auto`，Go 自动从模块代理拉取所需工具链 |
| 3 | `gomobile@latest` 要求 Go ≥ 1.26 | 与上一条冲突 | 同上——`auto` 让各命令各自取所需，不要钉死版本 |
| 4 | `invalid reference to os.checkPidfdOnce` | Go 1.23+ 校验 linkname 引用内部符号 | 链接器开关 `-checklinkname=0` |

另外两个环境性陷阱：

* **不要设 `GOSUMDB=off`**——那会让工具链下载无法校验而直接失败。
* **`.ps1` 必须带 UTF-8 BOM**：本机只有 Windows PowerShell 5.1，
  它按 ANSI 解码脚本，中文注释会变成乱码并导致语法错误。
  用 `write`/`edit` 工具改完脚本后要重新补 BOM。

产物：`app/android/app/libs/libbox.aar`（约 25 MB，内含 70.9 MB 的
`libgojni.so`，仅 arm64-v8a）。放进 APK 后体积约 247 MB（debug）。

## 三、libbox 的 API 面

**Java 包名是 `libbox`**（编译时未指定 `-javapkg`，即为默认值），
因此 Kotlin 里是 `import libbox.*`。

### 需要实现的 `libbox.PlatformInterface`

这是个接口，下面是全部抽象方法。带 ★ 的是 VpnService 必须认真实现的：

```
★ int  openTun(TunOptions)                      创建 TUN，返回 fd
★ void autoDetectInterfaceControl(int fd)       用 VpnService.protect() 防止回环
★ void startDefaultInterfaceMonitor(InterfaceUpdateListener)
★ void closeDefaultInterfaceMonitor(InterfaceUpdateListener)
★ NetworkInterfaceIterator getInterfaces()      默认网络的接口列表
★ String localDNSTransport() / LocalDNSTransport localDNSTransport()
★ boolean underNetworkExtension()               安卓返回 false

  void clearDNSCache()
  void cancelNotification(String, int)
  void checkPlatformShell()
  BridgeSession createBridge(BridgeOptions)
  ConnectionOwner findConnectionOwner(int, String, int, String, int)
  boolean includeAllNetworks()
  String lookupSFTPServer()
  PlatformUser lookupUser(String)
  ShellSession openShellSession(...)
  String readSystemSSHHostKey()
  WIFIState readWIFIState()
  void registerMyInterface(String)
  void sendNotification(Notification)
  void startNeighborMonitor(NeighborUpdateListener)
  void closeNeighborMonitor(NeighborUpdateListener)
  String tailscaleHostname()
```

其余方法可以先给最小实现（返回 null / false / 空实现），
它们分别服务于 Tailscale、SSH、USB-IP、Bridge 等本 App 用不到的功能。

### `openTun` 收到什么

`libbox.TunOptions` 提供构建 `VpnService.Builder` 所需的全部信息：

```
boolean getAutoRoute()          int getMTU()
boolean getStrictRoute()        int getHTTPProxyServerPort()
String  getHTTPProxyServer()
StringBox getDNSMode()
RoutePrefixIterator getInet4Address() / getInet6Address()
RoutePrefixIterator getInet4RouteAddress() / getInet4RouteExcludeAddress() / getInet4RouteRange()
RoutePrefixIterator getInet6RouteAddress() / getInet6RouteExcludeAddress() / getInet6RouteRange()
StringIterator getDNSServerAddress()
StringIterator getIncludePackage() / getExcludePackage()
StringIterator getHTTPProxyBypassDomain() / getHTTPProxyMatchDomain()
```

`RoutePrefix` 提供地址与掩码长度，用来调 `builder.addAddress()` /
`builder.addRoute()` / `builder.excludeRoute()`。

### 入口方法：CommandServer 架构

**没有 `libbox.BoxService`**，实际是「命令服务」架构（已用 `javap` 确认并编译通过）：

```kotlin
// 1. 全局初始化：告诉内核数据放哪里。每个进程只做一次。
val options = SetupOptions().apply {
    basePath = filesDir.absolutePath
    workingPath = filesDir.absolutePath
    tempPath = cacheDir.absolutePath
    fixAndroidStack = true       // 安卓上必须开
    logMaxLines = 300
}
Libbox.setup(options)

// 2. 命令服务：内核的宿主，需要我实现 CommandServerHandler
val server = Libbox.newCommandServer(handler, platformInterface)
server.start()

// 3. 启动内核（传入完整配置 JSON）
//    OverrideOptions 不能传 null——见下面第八节第 1 条，会直接段错误。
val overrides = OverrideOptions().apply { autoRedirect = false }
server.startOrReloadService(configJson, overrides)

// 4. 停止
server.closeService(); server.close()
```

`CommandServerHandler` 需要实现 7 个方法：`serviceReload`、`serviceStop`、
`setSystemProxyEnabled`、`getSystemProxyStatus`、`connectSSHAgent`、
`writeDebugMessage`、`triggerNativeCrash`。其中 **`writeDebugMessage`
是安卓端失败归因的唯一日志来源**——Windows 端读子进程 stderr，
安卓端只能靠这个回调，因此要把它转发给 Dart。

### 编译器纠正过的四处签名

以下都是编译报错后才修正的，写代码时不要凭直觉：

| 项 | 错误写法 | 正确写法 |
| --- | --- | --- |
| `RoutePrefix` 取地址 | `prefix.address` | **`prefix.address()`**（是方法不是属性） |
| `excludeRoute` | `excludeRoute(addr, mask)` | **`excludeRoute(IpPrefix(inetAddress, mask))`** |
| `SystemProxyStatus` 可用性 | `isAvailable = false` | **`available = false`** |
| gomobile 迭代器 | 只实现 `hasNext`/`next` | `StringIterator` **还要实现 `len()`**；`NetworkInterfaceIterator` 则**没有** `len()` |

另外 `PlatformInterface` 除业务方法外还有四个能力开关，必须显式实现：
`usePlatformAutoDetectInterfaceControl()`（返回 true）、
`usePlatformBridge()`、`usePlatformShell()`、`useProcFS()`（后三个返回 false）。

### 界面进程侧的两个约束

* **VPN 授权只能在 Activity 里申请**，且 `FlutterActivity` 的继承链上不保证有
  `registerForActivityResult`，用经典的 `startActivityForResult` +
  `onActivityResult` 更稳。
* **规则集要先解包**：安卓的 assets 在 APK 内，内核需要真实路径，
  因此由 Dart 从 `rootBundle` 读出后写入 `filesDir/rulesets`。
  可写目录路径通过通道 `filesDir` 向原生索取，不额外引入 `path_provider`。

## 四、集成步骤

1. **Gradle**（已完成）：`implementation(files("libs/libbox.aar"))`。
   注意 AAR 必须放在**模块的 libs 目录**（`android/app/libs/`），
   放在 `android/libs/` 会因相对路径解析失败而报
   `ExtractAarTransform ... 系统找不到指定的路径`。
2. **AndroidManifest**：声明服务与权限。
   ```xml
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
   <application>
     <service android:name=".XvpnVpnService"
              android:permission="android.permission.BIND_VPN_SERVICE"
              android:exported="false">
       <intent-filter><action android:name="android.net.VpnService"/></intent-filter>
     </service>
   </application>
   ```
3. **Kotlin**：`XvpnVpnService : VpnService(), PlatformInterface`
   —— 负责建立 TUN、实现 PlatformInterface、用 libbox 启动内核。
4. **通道**：`MethodChannel("com.xvpn.xvpn/platform")` 增加
   `vpnConnect(configJson)` / `vpnDisconnect()` / `vpnStatus`。
5. **Dart**：新增 `AndroidVpnCore implements VpnCore`，与 `SingBoxRunner`
   同接口，`main.dart` 按平台分发（当前安卓仍走演示内核）。

## 五、与 Windows 端的差异

| | Windows | Android |
| --- | --- | --- |
| 内核形态 | 独立进程 `sing-box.exe` | 库 `libbox.aar` |
| 流量接管 | 系统代理（免管理员） | VpnService + TUN |
| 配置来源 | 生成 JSON 写盘后传给进程 | 生成 JSON 直接传给内核 |
| 观测接口 | Clash API（HTTP） | Clash API（同端口，走进程内） |
| 规则库 | 落到本地目录 | 需要先从 assets 解包到 files 目录 |

分流规则、DNS 策略、配置生成这三块**完全共用**——它们都在
`SingBoxConfigBuilder` 里，与平台无关。这是协议工厂与内核抽象分层的收益。

## 六、真机联调时踩到的五个崩溃点

首次在真机上点「连接」时，进程在系统授权弹窗点「允许」之后**直接消失**——
没有 Java 异常、没有 tombstone、`adb shell pidof` 为空。原因是 libbox 的 Go 侧
有五处「传 nil 就 panic」的地方，而 Go 的 panic 在 gomobile 里表现为整个进程
段错误退出，Dart 与 Kotlin 的 try/catch 都拦不住。

排查手段：`adb logcat -c` 清缓冲后复现，再 `adb logcat -d | Select-String 'panic:'`
——Go 会把完整堆栈（含 sing-box 源码文件与行号）打到 `E Go` 标签下。

| # | 崩溃点 | 现象 | 解法 |
| --- | --- | --- | --- |
| 1 | `CommandServer.startOrReloadService(config, null)` | `panic` 于 `command_server.go`，`options.AutoRedirect` 空指针 | 传一个真实的 `OverrideOptions`，走 TUN 时 `autoRedirect = false` |
| 2 | `NetworkInterface.addresses` 里放裸地址 | `panic: netip.ParsePrefix("fe80::…"): no '/'` | 每一项必须是 **`地址/前缀长度`**，且 IPv6 要去掉 `%scope`（前缀语法不允许 zone） |
| 3 | `NetworkInterface.flags` 留 0 | 不崩溃，但内核把整张网卡列表判为「未启用」全部丢弃 | 至少带上 `FlagUp(1)`；建议按 `net.Flags` 填全（up=1 running=2 loopback=4 p2p=8 multicast=16） |
| 4 | `findConnectionOwner(...)` 返回 null | `panic` 于 `service.go`，`result.UserId` 空指针 | **查不到时必须抛异常**，内核会把异常当成「查不到」继续跑；返回 null 则必崩 |
| 5 | `Libbox.setup()` 被调用两次 | 用户「断开→连接」时全局状态被重置 | 用进程级标记挡掉重复调用 |

同类风险的通用判据：**`PlatformInterface` 上声明为可空返回的方法，如果 Go 包装层
直接解引用，就一律不能用 null 表示「不支持」**。已确认返回 null 安全的是
`readWIFIState()`（包装层有 nil 判断）与 `localDNSTransport()`
（`config.go` 里有 `!= nil` 判断）；`lookupUser()` 与
`createBridge()`/`openShellSession()` 一旦被调用就会解引用，因此本 App 把这些能力
开关全部关掉（`usePlatformBridge/usePlatformShell/useProcFS` 返回 false），
并让 `lookupUser()` 抛异常而不是返回 null。

另外两处与崩溃无关但会影响可用性的实现细节：

* `getInterfaces()` 要**跳过 VPN 网络**（`NET_CAPABILITY_NOT_VPN` 为 false 的，
  包括我们自己的 tun0），内核要的是物理出口；默认网络排在最前，
  内核按 `index` 找默认出口时才能命中。
* `InterfaceUpdateListener.updateDefaultInterface` 的 `isConstrained` 对应
  系统的 `NET_CAPABILITY_NOT_RESTRICTED`，**不是**「是不是 VPN」——
  写错会让内核把默认网卡当成受限网络。

## 七、界面状态的接管

安卓的隧道活在前台服务里，**界面进程被系统回收后隧道仍然在跑**
（用户从最近任务里划掉应用，`FlutterEngine` 随 Activity 销毁，但前台服务让进程
继续存活）。此时重新打开应用，Dart 侧是全新状态，如果不做处理就会显示
「未连接」而流量其实还在走隧道。

因此 `AndroidVpnCore.resumeIfRunning()` 在启动时会查原生 `status`，
`running == true` 就把状态接过来并重新开始轮询；`main.dart` 在 `initState`
里调用它。这条路径同时负责重新注册内核日志回调——否则失败归因会失效。
