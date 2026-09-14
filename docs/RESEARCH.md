# 为什么选择 sing-box（立项取舍）

> **不是**用户教程。怎么用请看 [`USER_GUIDE.zh-CN.md`](USER_GUIDE.zh-CN.md)。  
> 本文只保留立项时的**结论**；早期草稿调研正文已删除，避免与现行文档口径打架。

可选路线曾有两条：

1. **直接用 WireGuard Flutter 插件** + `AllowedIPs` / 地区 IP 表  
   实现简单，但只能按 IP 分流：同一 IP 上混有应直连与应走隧道的服务时无法区分，
   且 IP 表要自己维护——与「导入配置即可用」冲突。
2. **自接规则引擎（sing-box / 同类）**  
   可按域名分流，规则集可随包分发并更新。

本项目选择 **sing-box 作内核**，且**不采用**把完整客户端绑死的现成 Flutter 封装：
需要自己控制配置生成、分流与 DNS，才能保证桌面与安卓行为一致。
接入层在 `app/lib/core/`。

iOS 不在范围内（须走 Network Extension，与 Android `VpnService` 不同路径）。

协议字段与规范化坑见 [`PROTOCOLS.md`](PROTOCOLS.md)；规则实测见 [`RULES.md`](RULES.md)。
