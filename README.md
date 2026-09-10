# XVPN

**导入一个 `.conf` 就能用的分流 VPN 客户端。** 不需要选节点、不需要填规则、
不需要理解什么是 geosite——把配置文件丢进来，剩下的交给程序。

国内域名与 IP 自动直连，其余流量走隧道；DNS 走两套解析，国内用国内 DNS、
国外走隧道解析，避免污染。

- 桌面端：Windows
- 移动端：Android
- 内核：[sing-box](https://github.com/SagerNet/sing-box) 1.14.0
- 界面：Flutter，两端共用一套代码与一套调色板

## 它做了什么（以及为什么不需要配置）

| 用户以为要做的 | 实际由程序完成 |
| --- | --- |
| 挑选流量走哪条路 | 内置 `geosite-cn` + `geoip-cn` 规则集，域名与 IP 双保险 |
| 配置 DNS 防污染 | 自动生成两套 DNS：国内直连解析、国外走隧道解析 |
| 理解 WireGuard 参数 | 解析 `.conf` 并翻译成内核配置，字段全部自动映射 |
| 每次换配置重设一遍 | 记忆多份配置，切换即重连 |

规则集随包分发，首次连接时解包到应用私有目录，之后可以「检查更新」增量刷新。

## 支持的协议

按内容自动识别，不靠扩展名。新增协议只需实现一个适配器，界面与内核层都不用改。

- WireGuard（`.conf`）
- OpenVPN（`.ovpn`）

详见 [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md)。

## 分流与检测

- **分流**：`rule_set: [geosite-cn, geoip-cn] → direct`，其余 `route.final = vpn`。
  域名列表负责绝大多数情况，IP 列表兜住 IP 直连与域名列表漏掉的站点。
- **DNS**：`dns-cn`（223.5.5.5 / 119.29.29.29，`detour: direct`）与
  `dns-remote`（配置里声明的 DNS，`detour: vpn`）分流解析。
- **检测**：解析内核日志区分两类失败——「判为直连却失败」说明规则可能没覆盖，
  「走了隧道却失败」说明节点有问题。结论直接显示在连接页，而不是只报一句
  「连接失败」。规则覆盖情况见 [`docs/RULES.md`](docs/RULES.md)。

## 运行

### 直接用

1. 启动程序。
2. 把 `.conf` / `.ovpn` 拖进窗口（Windows），或在手机上用文件管理器「打开方式」
   选择 XVPN。也可以点「选择配置文件」。
3. 首次连接时 Windows 会设置系统代理、Android 会请求 VPN 授权。

Windows 端关闭主窗口会收进系统托盘，连接不中断；要真正退出走托盘右键菜单的
「退出 XVPN」——退出时会还原系统代理并结束内核进程，不会留下断网的烂摊子。

### 从源码构建

需要 Flutter 3.44+、Visual Studio（Windows 端）、Android SDK + NDK（安卓端）。

```powershell
# 桌面端
cd app
flutter build windows

# 安卓端：先编译内核库，再打包
../scripts/build-libbox.ps1      # 产出 app/android/app/libs/libbox.aar
flutter build apk
```

`scripts/build-libbox.ps1` 会拉取 sing-box 源码并用 gomobile 编译出 `libbox.aar`；
编译链路上的坑（Go 工具链版本、linkname 校验、脚本编码）记在
[`docs/ANDROID.md`](docs/ANDROID.md)。

### 测试

```powershell
cd app
flutter analyze
flutter test
```

测试覆盖配置解析（WireGuard / OpenVPN）、内核配置生成、分流日志归因、
Clash API 解析与两端界面行为。

## 目录

```
app/lib/
  core/          内核接入：sing-box 进程（Windows）、libbox（Android）、
                 Clash API 观测、内核日志归因、规则集、系统代理
  protocols/     协议工厂：按内容识别协议，解析成统一的 ParsedProfile
  screens/       四个页面（连接 / 分流记录 / 配置文件 / 设置）+ 导入流程
  widgets/       公共组件与自绘标题栏、连接圆环
  theme.dart     双主题调色板（暗色 / 亮色），界面只通过 XV.* 取色
app/windows/     自绘无边框窗口、托盘、系统代理接管与还原
app/android/     VpnService 实现、VpnService 与 libbox 的桥接
design/          界面原型（HTML，设计基准）
docs/            协议、规则、安卓接入说明
scripts/         内核编译脚本
testdata/        用于测试的样例配置
```

## 实现要点

- **一套界面，两种布局**：以 900px 为界切换桌面侧栏与移动底部标签栏。
  桌面端的标题栏由 Flutter 自绘（去掉系统标题栏后与侧栏连成一体），
  运行计时、主题切换都在这一条上。
- **两端同一份观测代码**：Windows 读子进程日志，Android 读 `libbox` 回调，
  但连接观测都走内核的 Clash API（127.0.0.1:2081），分流记录、速率、
  延迟两端是同一套 Dart 代码。
- **主题可切换**：跟随系统 / 亮色 / 深色，标题栏按钮与设置页共用同一份状态。

## 背景调研

最初的技术可行性调研保留在 [`docs/RESEARCH.md`](docs/RESEARCH.md)：
为什么不能用现成的 WireGuard 插件做分流、为什么最终选择 sing-box 作为内核。
