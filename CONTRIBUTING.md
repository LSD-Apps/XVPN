# 贡献指南

感谢你有兴趣改进 XVPN。这份文档说明开发环境、项目约定，以及几处**容易踩的坑**。

在动手前，建议先读 [`README.zh-CN.md`](README.zh-CN.md) 的「这是什么，以及不是什么」——
本项目的定位会影响哪些改动是可以接受的。

---

## 一、开发环境

| 目标平台 | 需要 |
| --- | --- |
| 仅跑测试 / 改 Dart 代码 | Flutter 3.44+（含 Dart 3.12+） |
| Windows 桌面端 | 上面的 + Visual Studio 2022，需勾选「使用 C++ 的桌面开发」工作负载 |
| Android | 上面的 + Android SDK、NDK；内核库见下 |

```powershell
git clone <仓库地址>
cd XVPN/app
flutter pub get
flutter analyze      # 必须无任何问题
flutter test         # 必须全绿
```

### 关于内核二进制

- **Windows**：`app/assets/bin/sing-box.exe`（约 78 MB，随仓库分发）。
  桌面端以**子进程**方式运行它。
- **Android**：`app/android/app/libs/libbox.aar`（约 26 MB）。
  由 [`scripts/build-libbox.ps1`](scripts/build-libbox.ps1) 用 gomobile
  从 sing-box 源码编译。**只有改到内核相关行为时才需要重新编译**；
  否则仓库里已有的 `.aar` 够用。

编译链路上的坑（Go 工具链版本、linkname 校验、PowerShell 脚本编码）
记在 [`docs/ANDROID.md`](docs/ANDROID.md)。

---

## 二、项目约定

### 注释：解释「为什么」，不解释「是什么」

这是本项目最看重的一条。代码本身已经说清了「做了什么」，
注释的价值在于记录**当时为什么这么选**——尤其是那些看起来奇怪、
但其实是踩过坑之后才那么写的地方。

比如这条：

```dart
// detour 必须显式指向 direct：路由规则**不作用于** DNS 服务器自己的出站连接，
// 只写路由规则的话这些查询会跟着 final 一起走隧道，实测表现为
// 「解析国内域名也超时」。这不是推测，是通过「只改 detour、其它不动」
// 的对照实验确认的。
```

反面例子（不要这样写）：

```dart
// 设置 detour 为 direct
'detour': 'direct',
```

**如果一处改动是因为某个具体的失败现象才那么写的，把那个现象写进注释。**
这能省掉后来者（包括几个月后的你）一次重新试错的成本。

### 测试：断言行为，不断言实现

测试要能抓住「功能坏了」，而不是「代码结构变了」。
因此断言文案、宽度、高度、顺序这类**用户可见的事实**，
而不是内部字段名或方法调用次数。

一个真实例子：`test/platform_parity_test.dart` 断言
「桌面与移动的设置页都包含某几块」——它抓出过三处真实缺失
（移动端没有删除入口、某张卡片只有桌面端有、某个操作两端都没有入口）。

### 「界面承诺了什么，代码就必须真的做什么」

本项目明确不接受**假功能**。历史上清理过这些：

| 假功能 | 问题 |
| --- | --- |
| 设置页的「检查更新」 | 只把显示的日期改成「今天」，并没有真的下载 |
| 「TUN 虚拟网卡」选项 | 桌面端选了不生效，界面上却写着「接管全部程序」 |
| 「开机自动启动」开关 | 只存了个布尔值，从未落到系统启动项 |
| 统计里只有一个「本次累计」 | 无法回答「这些流量有多少真的走了隧道」 |

**新增界面元素时请自问**：这个控件/文案背后有没有真实的实现？
如果没有，宁可不加，也不要加一个拨了没反应的开关。

### 两端一致性

布局是分开写的（桌面侧栏 + 独立页 / 移动底部标签 + 并入设置页），
但**呈现结构必须一致**：

- 能力可以按平台不同（桌面系统代理 / 安卓 VpnService 的 TUN），
  但两端都要把「用什么接管、有什么限制」讲清楚；
- 该有的操作两端都要有。历史上移动端一度只能增配置不能删。

新增界面元素时，请同时在 `test/platform_parity_test.dart` 里补一条断言。

---

## 三、新增一个协议

架构上这一步是刻意的低耦合：**界面与内核配置生成都不认识具体协议**。
界面只读 `ParsedProfile` 的展示字段，配置生成只调用
`VpnProtocolAdapter.buildEndpoint()`。因此新增协议不会牵动 UI 与分流逻辑。

### 三步

**第 1 步**：在 [`app/lib/protocols/vpn_protocol.dart`](app/lib/protocols/vpn_protocol.dart)
的 `VpnProtocol` 加枚举值，并补上 `label`、`fileExtensions`，
把 `isImportable` 改为 `true`。

**第 2 步**：新建两个文件。

- `<协议>_conf.dart`：纯文本解析器 + 实现 `ParsedProfile` 的视图类。
  **只做文本处理，不依赖任何平台能力**——这样它可以被完整单元测试。
- `<协议>_adapter.dart`：实现 `VpnProtocolAdapter` 的五个成员：
  `canParse`（按**内容**识别，不要只看扩展名）、`parse`、`buildEndpoint`、
  `placement`、`tunMtu`。

  后两个容易被漏掉，但都必须显式给出：

  - `placement` 决定生成的片段进 `endpoints` 还是 `outbounds`。sing-box 1.11
    起把协议分成两类（带隧道地址的是 `endpoints`，流式代理是 `outbounds`），
    放错位置内核直接拒绝启动；
  - `tunMtu` 决定安卓端 TUN 入站的 MTU，沿用内核默认的 9000 会造成分片。

**第 3 步**：把适配器注册进 `VpnProtocolFactory.adapters`。

完成后：导入流程自动接受新扩展名（文件选择器的过滤列表取自注册表），
「配置文件」页自动展示新协议标注与 `details` 里的字段。

### 关键要求

**① 按内容识别协议，不靠扩展名。**
`.conf` 既可能是 WireGuard 也可能是 OpenVPN。判断依据必须是指令特征：
WireGuard 看 `[Interface]` + `PrivateKey`，OpenVPN 看内联证书块或
`remote` + `client/dev/proto` 组合。

**② 参数必须规范化。**
这是最容易踩的坑，值得单独强调：写错参数会让内核**直接启动失败**，
而错误信息完全面向开发者，用户只看到「连不上」。

真实例子（见 [`app/lib/protocols/protocol_tuning.dart`](app/lib/protocols/protocol_tuning.dart)）：

- sing-box 要求 OpenVPN 的 `data_ciphers` 用**大写规范名**。
  写 `aes-256-gcm` 会得到
  `ClientOptions.DataChannel.Ciphers[0] must use a canonical OpenVPN cipher name`
  并 FATAL。**认不出的名字要直接剔除**——剔除只让协商范围变小，
  原样传会让内核起不来。
- `auth` 摘要名同理（`sha256` 会让内核失败，必须 `SHA256`）。

因此：**新增协议时，先把生成出的配置喂给真实内核验证。**

```powershell
cd app
dart run tool/build_singbox_config.dart <你的配置> build\out.json
assets/bin/sing-box.exe check -c build\out.json
```

**③ 为每条实测结论写测试。**
`test/protocol_tuning_test.dart` 里每条断言都对应一次真实的 `sing-box check`
结果。新增协议请照此办理——这些坑的共同点是「错误信息面向开发者、
用户完全看不出原因」，回归一次就是一次用户侧的疑难故障。

---

## 四、改内核配置生成

[`app/lib/core/singbox_config.dart`](app/lib/core/singbox_config.dart) 是所有
协议共用的部分：DNS 分流、路由规则、入站与观测接口。

改动时请特别注意**规则顺序**，它决定了优先级：

```
sniff（嗅探，必须在最前，后面按域名判定的规则都依赖它）
hijack-dns
自动纠正学到的规则      ← 必须在规则库之前，否则规则库会先判成直连
ip_is_private → direct
geosite-cn / geoip-cn → direct
route.final → vpn
```

改完务必用真实内核验证两种协议：

```powershell
cd app
dart run tool/build_singbox_config.dart ..\testdata\wg-hk-01.conf build\wg.json
assets/bin/sing-box.exe check -c build\wg.json
dart run tool/build_singbox_config.dart ..\testdata\sample.ovpn build\ovpn.json
assets/bin/sing-box.exe check -c build\ovpn.json
```

---

## 五、提交

### 提交信息

用中文，说明**问题与原因**，而不只是「改了什么」。
好的提交信息能让 reviewer 不读 diff 就理解动机。

```
修掉手工指定项三栏挤压导致输入框过窄的问题

现象：设置页「手工指定」那一行并排放着输入框、走向选择器与「添加」按钮，
窄屏上留给输入框的位置太窄，域名还没输完就看不见了。

原因与量化
- 选择器自然宽度实测 125.25px，按钮最小 88px，两处 8px 间距，共约 238px。
- 而手机设置页卡片的内容宽度只有 326px 上下……

改法
- 按可用宽度分两种排布……
```

### 提交前检查

- [ ] `flutter analyze` 无任何问题
- [ ] `flutter test` 全绿
- [ ] 改了协议或内核配置生成 → 已用 `sing-box check` 验证两种协议
- [ ] 改了界面 → 两端都看过（或补了一致性测试）
- [ ] 新增界面元素 → 背后有真实实现，不是占位
- [ ] 注释解释了「为什么」，而不是复述代码

---

## 六、不要做的事

- **不要提交假功能。** 见上文「界面承诺了什么，代码就必须真的做什么」。
- **不要在未验证的情况下断言内核行为。** 本项目所有协议相关的断言都实测过；
  请不要引入「看文档觉得应该是这样」的代码。文档与实现的差异正是踩坑的来源。
- **不要引入不必要的依赖。** 本项目刻意保持依赖精简
  （例如没有用 `shared_preferences`、没有用 `yaml`）。
  新增依赖前请说明为什么标准库做不了。
- **不要提交第三方组件而漏掉声明。** 新增任何第三方代码或数据，
  请同步更新 [`NOTICE.md`](NOTICE.md)。
- **不要暗示与 sing-box 官方有关联。** 见 `NOTICE.md` 里的上游附加条款。
- **不要把真实会话数据写进代码。** 这条是**曾经真的踩过**的坑：
  调试是对着真实服务器做的，而注释、文档与测试夹具的价值恰恰在于「这就是我
  真实现场看到的那一行」——于是真实域名、真实对端公钥的短标识被整行抄进了
  生产源码的文档注释和 4 个测试文件，随一次提交进了**公开**仓库。

  问题不在「忘了检查」，而在于这条路径上没有任何一步会问「这行里有没有不该
  外传的东西」。因此规则要前置到动手那一刻：

  * 日志片段、内核输出、密钥、域名、IP —— **一律换成合成值**再粘进代码；
  * 需要「看起来像真的」时用保留值：域名 `example.net` / `vpn.example.net`，
    IP 用 RFC 5737 的 `203.0.113.0/24`，密钥用递增字节的 base64
    （`AQIDBAUGBwgJ…`、`ISIjJCUmJygp…`）；
  * 确实要引用真实证据时，在注释里写明「示例值，非真实服务器」，
    这样下一个人不会把它当成可用的样本继续复制。

  公钥这类「按设计就是公开」的数据同样要处理：它本身不是秘密，但它是一个
  **稳定指纹**，能把公开仓库与某台具体服务器绑定起来。

  自查一条命令就够（在提交前跑）：

  ```powershell
  # 把 <你的域名> 换成本地测试用的那个
  git grep -I -n -e "<你的域名>" -e "<你配置里的任何密钥片段>" -- .
  ```

---

## 七、报告问题

提 issue 时请附上：

1. **现象**：你做了什么、期望什么、实际发生什么；
2. **诊断信息**：应用内「零配置接管状态」卡片的内容
   （启动自检结论、DNS 结论、流量分布）——它们通常已经指出了问题方向；
3. **配置的脱敏版本**：**请务必删掉私钥、证书、服务器真实地址、账号密码**；
4. 平台与版本（设置页侧栏底部有版本号）。

**注意**：本项目的检测能力会区分「判为直连却失败」（规则问题）与
「走了隧道却失败」（节点问题）。如果你的报告里带上这两条结论，
定位速度会快很多。

---

## 八、许可

本项目采用 **GPL-3.0-or-later**（受内核许可约束，原因见 [`NOTICE.md`](NOTICE.md)）。

提交贡献即表示你同意以同一许可发布你的贡献。
