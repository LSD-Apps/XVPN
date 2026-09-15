# testdata

这些文件只用于解析测试与文档示意。

- 主机名是 RFC 2606 保留域名（`example.net` 等），**不能连通**。
- 密钥、密码、证书块、UUID 都是占位值。
- **不是节点清单，也不是可订阅的接入服务。** 本项目不提供服务器。

| 文件 | 示意 |
| --- | --- |
| `wg-hk-01.conf` | WireGuard |
| `sample.ovpn` | OpenVPN |
| `hysteria2-config.yaml` / `hysteria2-node.txt` | Hysteria2 |
| `ss-node.txt` | Shadowsocks `ss://` |
| `vmess-example.txt` | VMess `vmess://` |
| `vless-example.txt` | VLESS `vless://` |
| `trojan-example.txt` | Trojan `trojan://` |
| `subscription-example.txt` | 多条分享链接（自备订阅示意） |

真实地址与凭据必须换成你自己有权使用的。法律边界见 [`docs/LEGAL.md`](../docs/LEGAL.md)。
