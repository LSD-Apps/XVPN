# 发布与平台合规

本文记录 XVPN 的**发布工程**与**平台合规**要点：

- 产品定位（客户端工具，不是 VPN 服务）；
- 应用商店的平台合规要求（Google Play 的 `VpnService` 与 Data safety、App Store）；
- 出口管制提示；
- 发布前就绪清单；
- 构建与发布流水线（触发方式、附件命名契约、Secrets、本地打包）。

> **免责声明**：本文整理的是发布工程事实与公开的平台政策，**不构成法律意见**。
> 涉及实际发行决策，请咨询持牌律师；平台政策引用截至 2026 年 2 月，请复核时效性。
> 面向用户的法律与使用声明集中在 [`LEGAL.md`](LEGAL.md)。

---

## 一、产品定位（与法律声明对齐）

发布与上架口径必须以「**配置客户端，不是 VPN 服务**」为准。  
完整表述（做/不做、使用者责任）见 [`LEGAL.md`](LEGAL.md)，此处不重复展开。

一句话提醒：不提供节点/订阅/账号；用户自备合法配置与服务器。

---

## 二、平台合规

### 2.1 Google Play

Android 的 `VpnService` 政策有**强制要求**
（见 [Play Console 帮助](https://support.google.com/googleplay/android-developer/answer/12564964)）：

- `VpnService` 只允许用于**核心 VPN 功能**或特定豁免场景
  （家长控制、应用用量统计、设备安全、网络工具、浏览器、运营商服务）；
- **必须在 Play 商店列表里清楚说明**使用了 `VpnService`；
- **必须加密**设备到隧道端点之间的全部数据；
- **禁止**为变现而重定向或操纵其它应用的流量；
- 需要填写权限声明表。

本项目符合第 1、3 条，但**第 2 条是上架前就绪项**，不是上架后补。
第 4 条与本项目无关——流量走向完全由用户自己的配置决定，且本项目无任何变现动机。

上架材料（应用说明中的 `VpnService` 用途声明、声明表单答案、权限声明、
Data safety 答案）见 [`STORE_LISTING.md`](STORE_LISTING.md)。

### 2.2 App Store

Apple 对 VPN 应用依 Guideline 5.4 审核，需要 `NEVPNManager` 与相应 entitlement。

**注意：本项目目前没有 iOS 工程**，iOS 是新增工作量而非配置项
（`design/brand/README.md` 也已明确声明未完成 iOS 接入）。

### 2.3 区域限制

不同国家和地区的应用商店对 VPN 类应用有各自的上架政策。建议**首轮只发政策
明确、材料齐备的市场**，其余按区域逐一核对后再放开。

---

## 三、出口管制

依据：

- 加密软件属 ECCN 5D002。**公开可用（publicly available）+ 标准密码学**
  的源码**不受 EAR 约束**；
- 2021 年起，邮件通报义务**只适用于「非标准密码学」**（专有或未公开的
  算法与协议）。标准算法（ChaCha20-Poly1305、AES-GCM 等）已无需通报。

详见 [Linux Foundation 出口管制指引](https://bestpractices.linuxfoundation.org/regulatory/export/non-standard-cryptography.html)
与 [Stanford 关于强加密出口管制的说明](https://doresearch.stanford.edu/resources/tools-documents/strong-encryption-export-controls)。

**关键前提**：公开可用例外只覆盖**源码公开**的形态。若只分发编译好的二进制
而源码不公开，就不再享有例外，需要自行评估合规。

**因此：保持仓库源码公开。** 这同时满足出口管制豁免条件，也是这个产品建立
信任的必要条件——一个处理你全部流量的软件，闭源基本没人敢装。

> 另外：本项目**不实现**加密，密码学来自 sing-box（上游开源项目），
> 本项目只做配置生成与分流决策。这也降低了自身的管制暴露面。

---

## 四、发布前就绪清单

### 已完成

- [x] **法律与使用声明**：[`LEGAL.md`](LEGAL.md)（产品定位、使用者责任、文档边界）
- [x] **用户上手教程**：[`USER_GUIDE.zh-CN.md`](USER_GUIDE.zh-CN.md) /
      [`USER_GUIDE.md`](USER_GUIDE.md)（自备/自建服务端 → 客户端分流；服务端指向官方文档）
- [x] **文档索引分轨**：[`README.md`](README.md)（用户 / 进阶 / 维护者）
- [x] **作者与署名**：[`AUTHORS`](../AUTHORS)、[`.mailmap`](../.mailmap)；提交禁止助手 `Co-authored-by`（见 [`CONTRIBUTING.md`](../CONTRIBUTING.md)）
- [x] **GPL-3.0-or-later** 许可（受内核约束）+ 第三方声明（`LICENSE` / `NOTICE.md`）
- [x] 明确「是客户端工具、不提供节点」的定位（[`LEGAL.md`](LEGAL.md)、README、使用指南）
- [x] 源码公开（满足出口管制豁免条件，也已推送到远程仓库）
- [x] **版本号单一来源**：界面此前硬编码 `v0.1.0`、pubspec 是 `1.0.0+1`，
      两者不一致（用户看到的版本与安装包不符）。现已统一到 `lib/version.dart`，
      由构建期 `--dart-define=XVPN_VERSION=` 注入，并由 `test/version_test.dart`
      断言它与 `pubspec.yaml` 不会脱节
- [x] 规则库与 `geoip-cn` 前缀索引可从上游复现（`scripts/build-cn-ip-index.ps1`）
- [x] 内核可从源码复现构建（`scripts/build-libbox.ps1`）
- [x] 测试全绿（`flutter analyze` 无问题、`flutter test` 全通过）
- [x] 协议行为经真实内核 `sing-box check` 验证，不是推测
- [x] 两端一致性有测试守住（`test/platform_parity_test.dart`）
- [x] **隐私政策已发布到公开 URL**：
      <https://lsd-apps.github.io/XVPN/privacy.html>（GitHub Pages，HTTP 200 已实测）。
      源文件 [`../PRIVACY.md`](../PRIVACY.md) 含逐项数据清单——包括
      「应用会主动联网的目标与内容」这一节（回环 Clash API、固定的延迟探测
      地址、直连公共 DNS 的健康探测、仅在点击时访问的规则库 CDN）
- [x] **VpnService 用途声明**：见 [`STORE_LISTING.md`](STORE_LISTING.md)
      第二节（声明表单用）+ 第一节（商店说明用，政策强制要求写在说明里）
- [x] **Data safety / 权限声明 / 内容分级的答案**：见 `STORE_LISTING.md`
- [x] **贡献指南**：[`CONTRIBUTING.md`](../CONTRIBUTING.md)
- [x] **双语 README**：[README.md](../README.md) 为英文（GitHub 默认渲染英文，有利于被检索与收录）、[README.zh-CN.md](../README.zh-CN.md) 为中文，两者互为语言切换
- [x] **GitHub 仓库已发布**：<https://github.com/LSD-Apps/XVPN>
      （描述、15 个 topics、许可证识别、Pages、CITATION.cff、llms.txt 均已就位）
- [x] **GitHub Releases**：已发布首个 tag，并已接上 **GitHub Actions 自动构建三端产物**（见下文「五、构建与发布流水线」）
- [x] **分发物随附许可与声明**：`.github/workflows/release.yml` 与
      `scripts/build-release.ps1` 把 `LICENSE`、`NOTICE.md` 与
      `THIRD-PARTY-NOTICES.md` 放进 Windows / Linux 压缩包根；Android APK 内含
      `assets/licenses/` 下的同名文件。CI 在打包后**断言**这些条目确实存在，
      避免「复制了但没进包」。
- [x] **应用内「开源许可」界面**：设置页「关于」卡片新增入口，用
      `showLicensePage` 展示 Flutter 自动聚合的依赖许可，并用
      `LicenseRegistry.addLicense` 额外注册本项目的 `LICENSE`、`NOTICE.md` 与
      `THIRD-PARTY-NOTICES.md`（见 `app/lib/core/licenses.dart`）。
      三份文本作为 Flutter assets 声明在 `assets/legal/`，其副本与仓库根文件的
      一致性由 `app/test/legal_assets_test.dart` 逐字节断言、并叠加 CI 的
      「复制根文件后断言 git 无差异」双重把关。
      **注意**：Android APK 内的 `assets/licenses/*` 是 **Android native assets**，
      Dart 的 `rootBundle` 读不到；界面读的是 `assets/legal/` 下的 **Flutter assets**
      副本，两者用途不同。
- [x] **内核静态依赖的第三方声明**：由
      [`scripts/build-third-party-notices.ps1`](../scripts/build-third-party-notices.ps1)
      对三个实际分发目标执行 `go list -deps` 求出真实链接的 Go 模块并集，生成
      [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md)（sing-box v1.14.0 下
      111 个模块，含许可标识与全文），随产物与 APK 分发，应用内也能读到。
- [x] **标准开源文件齐备**：[`CHANGELOG.md`](../CHANGELOG.md)（Keep a Changelog）、
      [`SECURITY.md`](../SECURITY.md)（私密漏洞报告）、
      [`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)（Contributor Covenant v2.1）；
      `CITATION.cff` 已按 CFF 1.2.0 校正（补 Linux 平台与关键词）
- [x] **第三方声明补全**：`NOTICE.md` 已补「内核静态内嵌的 Go 依赖」披露（并指向
      聚合声明 `THIRD-PARTY-NOTICES.md`），并按上游证据更正规则库许可结论
      （sing-geosite / sing-geoip 默认分支为 GPL-3.0-or-later）

### 发布前需补齐

- [ ] 在 Play Console 填写 VpnService 声明表单（文案已备好）
- [ ] 在 Play Console 填写 Data safety 与权限声明（答案已备好）
- [ ] **截图与图标已准备**（应与应用内实际界面一致）
- [ ] **`CONTRIBUTING.md` 目前是中文**；若面向海外贡献者，建议补一份英文版
- [ ] **iOS 工程**（若要做 iOS）
- [ ] **Android 发行签名密钥**：未配置时 release 构建会**直接失败**（不再回退
      debug 密钥），因此正式分发前必须由维护者按「五、构建与发布流水线」
      创建 secrets。密钥本身无法提交进仓库。
- [x] **Release 附件**：已由 `.github/workflows/release.yml` 自动附上
      Windows / Linux 压缩包、Android APK 与 `SHA256SUMS.txt`
- [x] **发布脚本**：构建一律带 `--dart-define=XVPN_VERSION=<ver>`，
      CI 与本地脚本都会先把 tag/输入与 `pubspec.yaml` 校验一致后再构建

### 建议的发布顺序

1. 在 Play Console 补齐四项表单（文案已备好，隐私政策 URL 已可用）；
2. 创建 `ANDROID_KEYSTORE_*` secrets，然后推一个 tag 让 CI 自动产出并附上三端产物；
3. 再上 **Google Play**（Android 是主力场景，且政策路径明确）；
4. iOS 视投入产出决定。

---

## 五、构建与发布流水线

发布由 [`.github/workflows/release.yml`](../.github/workflows/release.yml) 在
GitHub Actions 上完成：一条 tag 推送产出 Windows / Linux / Android 三端产物，
打上校验和后挂到 GitHub Release。应用内「检查更新」直接消费这份 Release，
因此**附件命名是契约**——改名字要同时改 CI、`scripts/build-release.ps1`
和更新器三处。

### 5.1 触发方式

| 方式 | 用途 | 版本来源 |
| --- | --- | --- |
| push tag（`v*`） | 正式发布 | tag 名去掉前导 `v` |
| 手动 `workflow_dispatch` | 补发 / 验证 | 输入 `version`；留空取 `app/pubspec.yaml` |

两种方式都会把版本与 `app/pubspec.yaml` 的 `version:`（去掉 `+build` 后缀）
**比对，不一致直接失败**。版本号唯一来源是 pubspec：想发 `v1.2.0` 就得先把
pubspec 写成 `1.2.0+<build>`。

> 为什么在这里「失败」而不是取其一：界面显示的版本来自构建期注入
> `--dart-define=XVPN_VERSION=`（见 `app/lib/version.dart`），它必须与安装包
> 实际版本一致，否则用户反馈问题时给出的版本号是错的。

### 5.2 附件命名契约（exact）

| 附件 | 内容 |
| --- | --- |
| `XVPN-<ver>-windows-x64.zip` | Windows release bundle 目录的**内容**（`xvpn.exe`、`sing-box.exe`、`data/` 等位于压缩包根），另含 `LICENSE`、`NOTICE.md` 与 `THIRD-PARTY-NOTICES.md` |
| `XVPN-<ver>-linux-x64.zip` | Linux release bundle 目录的内容（`xvpn`、`sing-box`、`data/` 等），另含 `LICENSE`、`NOTICE.md` 与 `THIRD-PARTY-NOTICES.md` |
| `XVPN-<ver>-android-arm64.apk` | **裸 APK**——更新器需要它才能调起系统安装器；内含 `assets/licenses/` 下的 `LICENSE`、`NOTICE.md` 与 `THIRD-PARTY-NOTICES.md` |
| `XVPN-<ver>-android-arm64.zip` | 装着上面那份 APK 的 zip，让三端都有一个 zip 入口 |
| `SHA256SUMS.txt` | 上面四个文件的 SHA-256（`sha256sum -c` 可直接校验） |

`<ver>` 是 tag 去掉前导 `v`，例如 tag `v1.0.0` → `<ver>` = `1.0.0`。

两个 zip 都采用「bundle 目录内容在压缩包根」的布局，解压即可就地覆盖安装目录。
不要改成「外面再套一层目录名」——这是更新器的解压约定。

### 5.3 需要的 Actions Secrets

在 GitHub 仓库 `Settings → Secrets and variables → Actions` 新建：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 发行 keystore 文件的 base64（见下） |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 口令 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 该别名对应的口令 |

生成 keystore（只需做一次，**务必备份**——丢了就再也无法覆盖安装旧版本）。
本仓库已生成一份 4096 位、有效期约 30 年的发行密钥库，口令由持有者单独保存：

```bash
keytool -genkeypair -v -storetype JKS \
  -keystore app/android/keystore/xvpn-release.jks -alias xvpn \
  -keyalg RSA -keysize 4096 -validity 10950 \
  -dname "CN=XVPN, OU=LUSIDA, O=LUSIDA, C=CN"
# Linux/macOS
base64 -w0 app/android/keystore/xvpn-release.jks > release.keystore.b64
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('app/android/keystore/xvpn-release.jks')) |
  Set-Content -NoNewline release.keystore.b64
```

把 `release.keystore.b64` 的全部内容填进 `ANDROID_KEYSTORE_BASE64`。

**本机可选**：Gradle 也支持 Flutter 官方约定的 `app/android/key.properties`
（已 gitignore），键名 `storeFile / storePassword / keyAlias / keyPassword`，
`storeFile` 相对 `app/android/` 解析。`app/android/keystore/` 同样已忽略，
把 `.jks` 放进去即可。CI 用的是上面四个环境变量，两者二选一，CI 优先。

**release 不再回退 debug**：签名材料缺失时不再用 debug 密钥凑合，而是在 Gradle
任务图阶段**直接失败**并打印中文指引（`app/android/app/build.gradle.kts` 末尾的
「发行签名守卫」）。原因：debug 密钥是**每台机器现生成**的，不同 runner 产出的 APK
签名不同，用户无法覆盖安装后续版本，自动更新会失败；发一个签名不一致的「正式版」
比构建失败严重得多。因此正式分发**必须**配置这四个 secret。

### 5.4 内核（sing-box）从哪来

三端必须来自同一版本，版本写在**唯一一个文件** [`scripts/sing-box-version.txt`](../scripts/sing-box-version.txt)
（当前 `v1.14.0`），CI 直接读它：

- Windows / Linux：从 `SagerNet/sing-box` 官方 release 下载对应平台压缩包，
  放到 `app/assets/bin/sing-box[.exe]`，随后由 `app/windows/CMakeLists.txt`
  或打包步骤放到可执行文件旁（与既有「外部进程」模型一致）。
- Android：`app/android/app/libs/libbox.aar`。仓库里已提交一份；默认直接使用，
  只有勾选 `rebuild_libbox`（或需要换版本）时才由
  [`scripts/build-libbox.sh`](../scripts/build-libbox.sh) 从源码用 gomobile 重编。

CI 在下载后会执行 `sing-box version` 并校验版本号与 `with_openvpn / with_quic /
with_gvisor / with_clash_api / with_naive_outbound` 等构建标签，缺标签会**构建期
失败**而不是等运行期用户点「连接」才报错。官方 release 二进制实测包含这些标签，
因此无需自建；若上游某天砍掉某个标签，这条检查会挡下来（届时需要按
[`docs/ANDROID.md`](ANDROID.md) 的标签集自建桌面端二进制）。

### 5.5 本地打包（Windows 开发机）

```powershell
pwsh scripts/build-release.ps1            # 只构建 Windows
pwsh scripts/build-release.ps1 -Android   # Windows + Android APK
```

产物写入 `dist/` 并生成 `SHA256SUMS.txt`。脚本在
`app/assets/bin/sing-box.exe` 缺失时**直接报错**（不会打出一个连不上的包）。
Linux 只能在 Linux 上编译，因此本地脚本**不含** Linux（见 `scripts/build-release.ps1`
顶部注释）；Linux 一律交给 CI。

---
