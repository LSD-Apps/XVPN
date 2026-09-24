# XVPN (幽门)

[![Tests](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/LSD-Apps/XVPN)](https://github.com/LSD-Apps/XVPN/releases/latest)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

**A split-tunnel VPN client that just takes your `.conf`.**

Import your own WireGuard / OpenVPN / Hysteria2 / Shadowsocks / VMess / VLESS / Trojan profile. Traffic matched by the
bundled rule sets goes **direct**; everything else uses **your** tunnel. No nodes,
no bundled subscription addresses, no accounts.

| | |
| --- | --- |
| Desktop | Windows · Linux |
| Mobile | Android |
| Core | [sing-box](https://github.com/SagerNet/sing-box) 1.14.0 |
| UI | Flutter (shared state & palette) |
| License | [GPL-3.0-or-later](LICENSE) |

<sub>English · [简体中文](README.zh-CN.md) · [User guide](docs/USER_GUIDE.md) · [Privacy](privacy.html) · [Legal](docs/LEGAL.md) · [Docs index](docs/README.md) · [Authors](AUTHORS) · [Contributing](CONTRIBUTING.md) · [License](LICENSE)</sub>

> Once installed, the launcher, taskbar and Android VPN notification show the name
> **幽门**; the repository, the executable and the release assets keep the name
> `XVPN`. Same software — assets are not renamed so that already-installed builds
> can still find their upgrade package. Author: LUSIDA (<https://www.lusida.net>).

## What this is — and is not

**Is:** a config client. You supply a lawful profile; the app translates it for the
core, splits traffic, and attributes failures (local vs server vs rule).

**Is not:** a VPN service. It ships **no** servers, nodes, or subscription
addresses, and no accounts. It does **not** implement cryptography (that is sing-box).

→ Full walkthrough: [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)  
→ Legal boundary: [`docs/LEGAL.md`](docs/LEGAL.md)

## Get started

1. Prepare a lawful endpoint (your server, or an org-issued client profile).
2. Export a client config (`.conf` / `.ovpn` / YAML or a share link such as `ss://` / `vless://`).
3. Install from [Releases](https://github.com/LSD-Apps/XVPN/releases/latest) —
   Windows: run the `.msix` installer; Linux: unzip into a per-user directory
   (`~/.local/opt/xvpn`); Android: unzip and install the APK inside. In-app
   updates then need no admin rights on Windows.
4. Import → connect → confirm rates / status (see the user guide for UI map & troubleshooting).

Desktop uses the **system proxy** (no admin); Android uses **VpnService**.  
Quit via tray **Quit XVPN** so the proxy is restored. Linux notes and package
dependencies: [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) (Day-to-day / Linux).
Auto-update details: [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) (Install).

**Protocols** (detected by content): WireGuard, OpenVPN, Shadowsocks, VMess, VLESS, Trojan, Hysteria2 — details in
[`docs/PROTOCOLS.md`](docs/PROTOCOLS.md).

**Multi-node, bring your own**: paste your own subscription URL, or a list of share
links / Clash `proxies:` / sing-box `outbounds[]`. Same node appearing in two sources
stays one entry. Node region is judged from `cn-ip.bin` when the server is an IP.

## Disclaimer

This is a **client**. You bring a lawful profile and server. The project does not
provide network access and does not warrant legality in your jurisdiction.
Intended uses, what this repository will not accept, and GitHub alignment:
[`docs/LEGAL.en.md`](docs/LEGAL.en.md) · [中文](docs/LEGAL.md).

## Where to read next

| Audience | Doc |
| --- | --- |
| New users | [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) · [中文](docs/USER_GUIDE.zh-CN.md) |
| Rules / DNS / learning | [`docs/RULES.md`](docs/RULES.md) |
| Self-heal & probes | [`docs/RESILIENCE.md`](docs/RESILIENCE.md) |
| Privacy / security | [`PRIVACY.md`](PRIVACY.md) · [`SECURITY.md`](SECURITY.md) |
| Legal notice | [`docs/LEGAL.en.md`](docs/LEGAL.en.md) · [中文](docs/LEGAL.md) |
| Release & Play listing | [`docs/RELEASE.md`](docs/RELEASE.md) · [`docs/STORE_LISTING.md`](docs/STORE_LISTING.md) |
| Full map | [`docs/README.md`](docs/README.md) |

## Build & test

Flutter 3.44+. Windows: VS with C++ desktop workload. Android: SDK + NDK.
Linux: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`.

```powershell
cd app
flutter build windows                    # or: flutter build linux --release
pwsh ../scripts/build-libbox.ps1         # Android core AAR, then:
flutter build apk

flutter analyze
flutter test
```

Desktop cores ship under `app/assets/bin/` (see [`NOTICE.md`](NOTICE.md)).
Android toolchain notes: [`docs/ANDROID.md`](docs/ANDROID.md).
Contributor conventions: [`CONTRIBUTING.md`](CONTRIBUTING.md).

After updating bundled `.srs` rule sets, regenerate the DNS geo index:

```powershell
pwsh scripts/build-cn-ip-index.ps1
```

## License

**GPL-3.0-or-later** — required because Android links GPL sing-box into the same
process. Keep `LICENSE`, [`NOTICE.md`](NOTICE.md), and
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) when redistributing; do not use
the sing-box name or imply affiliation.

Copyright **LUSIDA** · [www.lusida.net](https://www.lusida.net) · maintainer
[LSD2024](https://github.com/LSD2024) / [LSD-Apps](https://github.com/LSD-Apps)
— [`AUTHORS`](AUTHORS).
