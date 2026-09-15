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

## 八、真机部署与端到端复验

`scripts/deploy-android.ps1` 把这一节的手工步骤收成一条命令。下面写的是它为什么
必须写成那样——每一条都对应一个「看起来像玄学」的失败。

### 8.1 厂商的拦截页会吃掉 `adb install`

在 vivo / iQOO 的 ROM 上，安装非自家商店的应用会先弹
`com.android.packageinstaller.PackageInterceptActivity`：一页「安全守护提示您 /
外部来源应用 / 该应用来源于非 vivo 官方应用商店」，底下是「已了解应用的风险检测
结果」复选框与「继续安装」按钮。

后果不是「多一次点击」，而是 **`adb install` 永远不返回**——它没有超时，就是卡住。
`-g`（授予全部运行时权限）、`-t`（测试包）、以及伪装安装器
（`pm install -i com.bbk.appstore`）**都不影响这一页**：前两个管的是权限与包标记，
后一个管的是「谁装的」，而拦截页看的是「从哪来的」。

拦截页右上角的齿轮通向 `InstallSwitchActivity`，里面那一项才是开关：

```
设置 → 应用安装 → 应用安全验证 → 关
```

开着的时候，页面上会明说「继续安装第三方应用需身份验证，点击右上角设置可关闭
验证」——点下去还要过指纹或锁屏密码，无人值守做不到。关掉之后同一页只剩复选框与
「继续安装」两个动作，脚本可以代点。

**这一项没有对应的 `settings` 键**（不在 `global` / `secure` / `system` 任何一个
命名空间里），只能用手点一次。脚本会把路径打出来，但第一次仍然要人工过一遍。

`adb shell settings put` 能关掉的是另外几项，它们省掉的是**校验与等待**，不是拦截页：

| 键 | 值 | 作用 |
| --- | --- | --- |
| `global package_verifier_enable` | `0` | 安装时不再联网送检 |
| `global verifier_verify_adb_installs` | `0` | ADB 安装不送检 |
| `global vivo_update_intelligent_installation` | `0` | vivo 的「智能安装」 |
| `secure install_non_market_apps` | `1` | 允许非市场来源 |
| `global wait_for_debugger` | `0` | 被打开过会让应用启动即挂起 |

### 8.2 `pm install` 的退出不能当作「装完了」

vivo 的安装器**提交完会话之后不关掉它**（安装完成页留在前台），于是 `pm install`
这个客户端一直等下去。实测：包在 19:01:17 已经装好、启动器图标都出来了，而命令
仍然阻塞——以它的退出为准，每次安装都会等到超时，再被误报成失败。**把成功说成
失败比慢更糟。**

因此脚本以**设备上的事实**为准：`dumpsys package <包名>` 里的 `lastUpdateTime`
变了（覆盖安装）或包从无到有（首次安装）就算装完，`pm install` 的输出只在判定
失败时用来取原因。

同理，判断「当前是不是停在拦截页」也不能靠 Activity 名：`PackageInterceptActivity`
只出现在 `dumpsys window` 的输出里，而 `uiautomator dump` 的 XML 只有
`package="com.android.packageinstaller"` 与各控件文本。按名字认的症状是「界面明明
停在拦截页，脚本却一直以为没有」，最后超时。脚本按**内容**认（包名 + 只有拦截页
才有的文案）。

### 8.3 没有真实节点也能验「TUN 的 TCP 进不进内核」

第六节那个 `stack` 缺陷（TCP 进不了内核、界面显示已连接但什么都打不开）需要一条
真的能收到包的链路才看得出来。不必有公网节点，用仓库里已有的内核自建一个即可：

```powershell
# 1. 开发机上起一个 Shadowsocks 接入端（用的是随包分发的那份内核）
#    .build/singbox-server.json：inbounds 一条 shadowsocks，监听 127.0.0.1:8388
app\assets\bin\sing-box.exe run -c .build\singbox-server.json

# 2. 把手机的 8388 反向映射回开发机——不走 WiFi，因此不受防火墙与同网段影响
adb reverse tcp:8388 tcp:8388
```

然后把 `ss://aes-128-gcm:xvpn-lan-test@127.0.0.1:8388#LAN` 导进应用并连接。
（应用支持 `ACTION_SEND`，可以直接把链接分享给它：
`adb shell am start -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "<链接>" -n <包名>/net.lusida.xvpnclient.MainActivity`。）

判据在**接入端的日志**里，不在手机界面上——界面上的信号（延迟、圆环）在
`mixed` / `system` 这两种 stack 下同样是绿的，这正是当初误判的原因：

```
inbound/shadowsocks[ss-lan-test]: inbound connection from 127.0.0.1:2753
inbound/shadowsocks[ss-lan-test]: inbound connection to www.gstatic.com:443
```

出现 `connection to <域名>:443` 就说明 TUN 里的 TCP 真的被终结并转发出去了。
除了随包的那份内核，不需要任何额外的抓包或测试工具。

### 8.4 已复验的结论（vivo V1838A / Android 10，2026-09-15）

用的是 debug 变体（`net.lusida.xvpnclient.dev`），因为它可 `run-as`，
私有目录读得到。这一轮验证的每一项都对应一个「只有真机才暴露」的失败：

| 项 | 判据 | 结果 |
| --- | --- | --- |
| 内置规则集解包 | `files/rulesets/` 下 4 份 `.srs` + `cn-ip.bin` | 齐（`RuleSetStore.builtins` 派生生效） |
| 规则集大小回填 | `config.json` 里四项 `sizeBytes` 非 0 | 55614 / 34074 / 522610 / 37462 |
| 凭据加密 | `credentials.key` 是 80 字符 base64 = 12 IV + 32 DEK + 16 tag | 60 字节密文，无明文 |
| 默认网络不误判 | `diag.log` 的「上报默认接口」 | `wlan0 index=30`，不是 `tun0` |
| 网卡列表 | 「内核请求网卡列表，返回 N 张」 | 3 张，且不含 `tun0` |
| TUN 的 TCP | 接入端日志出现 `connection to …:443` | 通过 |
| 自愈重启的授权框 | 重建时 `openTun ok` 的 fd 变了、且无 `ConfirmDialog` | fd 109 → 104，未弹框 |
| 界面被回收后接管 | 隧道在跑时销毁 Activity，重开应用 | 显示「已连接」、延迟与流量续上 |

最后一项验的是第七节的 `AndroidVpnCore.resumeIfRunning()`。做法是把 `always_finish_activities`
打开（开发者选项里那个「不保留活动」），让「离开应用」真的销毁 Activity：
`tun0` 与前台服务都还在、进程号也没变，重开应用后界面显示的是**已连接**而不是
「未连接」——这正是第七节点名要避免的那个状态。验完把该设置改回 0。

`AndroidVpnCore` 每个连接生命周期内的证据都可以用
`powershell -File scripts/deploy-android.ps1 -NoBuild -Evidence` 重新打一份。

### 8.5 协议矩阵：七个协议逐个真机连通

「协议能解析」与「协议能连上」是两件事。解析有单测与 `sing-box check` 兜底，
但握手、加密、传输层只有真机能验。这一轮把矩阵补齐到 **6/7**：

| 协议 | 接入端 | 结果 | 判据（接入端日志） |
| --- | --- | --- | --- |
| Shadowsocks | `inbounds[].type=shadowsocks` | ✅ | `inbound connection to www.gstatic.com:443` |
| VMess | `inbounds[].type=vmess` | ✅ | `[u] inbound connection to …:443` |
| VLESS | `inbounds[].type=vless` | ✅ | `[u] inbound connection to …:443` |
| Trojan | `inbounds[].type=trojan` + 自签 TLS | ✅ | 同上（TLS 握手在内核里完成） |
| Hysteria2 | `inbounds[].type=hysteria2` + 自签 TLS | ✅ | `inbound packet connection to 1.1.1.1:53` |
| WireGuard | `endpoints[].type=wireguard` | ✅ | `peer(…) - received handshake initiation` |
| OpenVPN | **没有可用的服务端** | ⚠️ 部分 | 见下 |

TCP 类协议同时验到了 **UDP 也走隧道**：每个协议下都出现
`inbound packet connection to 1.1.1.1:53`，即内核劫持的 DNS 查询确实经隧道发出。

**两件搭环境时必须知道的事：**

1. **`adb reverse` 只支持 TCP**（`adb reverse udp:…` 直接报
   `unknown socket specification`）。而 Hysteria2 与 WireGuard 都是 **UDP**，
   因此它们**不能**走 8.3 那条回环捷径，必须让手机经局域网连开发机。
   这要求开发机对该端口有入站放行——本机上 `app/assets/bin/sing-box.exe`
   已有两条启用的入站 Allow 规则（Public 配置文件），所以能直接听。
   手机连不上时先看这个，而不是先怀疑内核。
2. **sing-box 没有 wireguard / openvpn 接入端**。WireGuard 要写成
   `endpoints[]` 里的一条 `type: wireguard`（带 `listen_port` 与 `peers`，
   此时它就是服务端）；OpenVPN 在 sing-box 里**只有 `openvpn-client` 端点**，
   没有服务端实现，所以用随包内核搭不出 OpenVPN 接入端。
   用 `nc` 发垃圾包可以快速确认某个接入端是活的：TCP 那四个各会报
   `bad header` / `unknown version` / `TLS handshake: unexpected EOF` 之类，
   而 QUIC 类的会**静默丢弃**——因此 UDP 探针不能用来判断「包有没有到」。

**OpenVPN 为什么只算部分验证。** 本机没有 OpenVPN 服务端（`openvpn` 未安装，
装它要管理员权限），而 sing-box 又不提供，所以握手跑不完。可验证的部分已经验证：

* `.ovpn` 被正确解析，并生成了结构完整的 `openvpn-client` 端点（内联 CA、
  `control_wrap` 的 `tls_auth` 与 `direction: client`、`server_name`、
  `remote_certificate_tls`）；
* **随包分发给安卓的 libbox 确实带 `with_openvpn`**：内核接受了这个端点并
  `startOrReloadService ok`。这一条值得单独记下来——若那次构建漏了该标签，
  OpenVPN 对所有用户就是「导得进、连不上」，而界面只会说「没能连上服务器」。

**未验证的是握手之后的隧道**。不要把它当成已验证。

顺带记下一条用来切换被测配置的捷径：内核与界面读的都是 `files/config.json`，
把它改成只剩目标配置、并把 `activeProfileId` 置空即可——`AppState` 在存档里的
active id 找不到时会**回落到第一条**（`app_state.dart` 的加载分支）。比在界面上
翻配置列表快得多，也不必碰 UI。

