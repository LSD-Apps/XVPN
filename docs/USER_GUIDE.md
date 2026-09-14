# XVPN User Guide

For first-time users: from “I have my own server” to “connected in the client, and I understand split tunnelling.”

When you finish, you should be able to: **prepare a config → import → connect → confirm routing → classify failures**.

| Section | You get |
| --- | --- |
| [Before you start](#before-you-start-three-things-to-get-straight) | Product boundary and lawful-use premise |
| [What you need](#what-you-need) | Pre-flight checklist |
| [What the file looks like](#what-the-file-looks-like-redacted) | Redacted shapes for three protocols |
| [Full path](#one-full-path-your-server--split-tunnel-client) | Seven steps |
| [UI map](#ui-map-five-pages) | What each page is for |
| [Day-to-day](#day-to-day) | Switch profiles, rules, quit |
| [Troubleshooting](#when-it-fails-or-one-site-misbehaves) | Three failure classes |
| [FAQ](#faq) | Common questions |
| [Next](#where-to-go-next) | Advanced and legal docs |

中文：[`USER_GUIDE.zh-CN.md`](USER_GUIDE.zh-CN.md) · Legal: [`LEGAL.md`](LEGAL.md) · Index: [`README.md`](README.md)

---

## Before you start: three things to get straight

### 1. What XVPN is

A **client** on your device. It reads a config **you** supply, builds an encrypted tunnel to **your** server, and decides which flows go through the tunnel and which go direct.

### 2. What XVPN is not

| It is not | So this guide will not |
| --- | --- |
| A VPN / proxy operator | Provide servers, nodes, subscriptions, or accounts |
| A “find me a line” marketplace | Recommend or help obtain third-party access services |
| A server installer | Teach you how to buy a host, or replace each protocol’s official server docs |

**You must bring a lawful server and client config.** This software only connects and splits traffic.

### 3. Lawful use is your responsibility

Confirm that you own or are authorised to use the server, and that your use complies with the laws and terms of your jurisdiction and the server’s location. Typical uncontroversial uses: remote admin of your own machines, encrypted access to a company or lab network, VPN profiles formally issued by your organisation.

Full notice: [`LEGAL.md`](LEGAL.md). Everything below assumes a lawful config and purpose.

---

## What you need

1. **A server you may use**, **or** a ready-made **client config** from your admin (if you already have the file, start at Step 3).
2. If self-hosting: a **server** install of one of the following, per **upstream** docs:
   - [WireGuard](https://www.wireguard.com/quickstart/)
   - [OpenVPN](https://openvpn.net/community-resources/)
   - [Hysteria2](https://v2.hysteria.network/)
3. The matching **client config** (next section).
4. Windows, Linux, or Android.
5. A build from [Releases](https://github.com/LSD-Apps/XVPN/releases) (or build from source).

> Server install, firewall, certificates → official docs or your organisation’s runbooks.  
> **This repository covers the client only.**

---

## What the file looks like (redacted)

Examples use documentation addresses (`192.0.2.0/24`, `example.com`).  
**Do not paste these into production**; replace keys and hosts with yours.

### WireGuard (typically `.conf`)

```ini
[Interface]
PrivateKey = <client private key>
Address = 10.0.0.2/32
DNS = 192.0.2.53

[Peer]
PublicKey = <server public key>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
```

### OpenVPN (typically `.ovpn`)

Usually includes `client`, `remote`, and inline `<ca>` / `<cert>` / `<key>` blocks.  
Detected by content; prefer the `.ovpn` suffix. Never publish certs/keys.

### Hysteria2 (typically `.yaml` / `.yml`)

```yaml
server: vpn.example.com:443
auth: <password>
tls:
  sni: vpn.example.com
```

Share links and sing-box outbound JSON are also accepted when that is what your server export gives you.

**Security:** redact secrets before asking for help in public issues.

---

## One full path: your server → split-tunnel client

### Step 1 — Prepare the tunnel service on the server

Run a WireGuard, OpenVPN, or Hysteria2 **server** (one is enough).

**Done when:** another machine already connects with that protocol’s official client or CLI.  
If the server fails, XVPN will not fix it.

### Step 2 — Export a client config

| Protocol | You typically get | How XVPN accepts it |
| --- | --- | --- |
| WireGuard | `wg-quick`-style `.conf` | Content-detected; prefer `.conf` |
| OpenVPN | Client `.ovpn` | Content-detected; prefer `.ovpn` |
| Hysteria2 | YAML; or share link / JSON | Content-detected |

Org-issued files: skip server install; go to Step 3.

### Step 3 — Install XVPN

Download from [Releases](https://github.com/LSD-Apps/XVPN/releases/latest), install, launch. No account.

### Step 4 — Import

| Platform | How |
| --- | --- |
| Windows | Drag / pick file / paste |
| Linux | Pick file / paste |
| Android | “Open with” XVPN, or pick / paste in-app |

**If import fails:** the file may be a subscription URL, zip, or README instead of a single client profile; OpenVPN may lack cert blocks; WireGuard may lack `PrivateKey` / `Peer`; chat apps may have mangled newlines.

### Step 5 — Connect

| Platform | OS prompt | Takeover |
| --- | --- | --- |
| Windows / Linux | System proxy (no admin) | Apps that honour the proxy |
| Android | VPN permission | `VpnService` (TUN) |

**Clean quit:** tray → **Quit XVPN** restores the proxy and stops the core. Closing the window usually trays without disconnecting.

### Step 6 — What split tunnelling means here

> **Flows matching the bundled “domestic site / domestic IP” rule sets go direct; everything else uses your tunnel.**

| Mode (Split rules page) | Behaviour |
| --- | --- |
| Smart split | Rule sets + your domain rules (default) |
| All via tunnel | Ignore rule sets (often needs reconnect; follow in-app copy) |
| All direct | No tunnel (handy while debugging) |

### Step 7 — Confirm it works

1. Connected; rates or session bytes move.  
2. Read the status / self-check card.  
3. Try one **direct** destination and one that should use the **tunnel**.  
4. On failure, read attribution before changing the wrong layer.

---

## UI map: five pages

| Page | One line | Typical actions |
| --- | --- | --- |
| **Connect** | Link up; status and traffic | Connect/disconnect; self-check; attribution |
| **Split records** | Recent flows; direct vs tunnel | Filter; see why a host used the tunnel |
| **Profiles** | Your saved configs | Import, switch, delete |
| **Split rules** | Modes, rule sets, domain pins | Mode, updates, allow-lists, learned rules |
| **Settings** | Theme, logging, … | Preferences that are not routing logic |

Desktop uses a sidebar; narrow / Android uses a bottom bar. Same structure.

---

## Day-to-day

| Goal | Where |
| --- | --- |
| Switch profile | Profiles |
| See direct vs tunnel | Split records |
| Pin a domain | Split rules |
| Smart / all-tunnel / all-direct | Split rules → mode |
| Refresh bundled rule sets | Split rules → check for updates |
| Theme, logs | Settings |

**Desktop scope:** system proxy — browsers and most GUI apps. Games / some CLI may ignore it. Android uses the system VPN. See [`PROTOCOLS.md`](PROTOCOLS.md).

**Linux:** GNOME-family and KDE for proxy; other DEs error honestly. Tray needs a StatusNotifierItem host. Prefer `secret-tool` for credentials; if missing, plain-text storage is disclosed on import.

| Feature | Dependency | Debian/Ubuntu | Fedora / Arch |
| --- | --- | --- | --- |
| System proxy (GNOME) | `gsettings` | `libglib2.0-bin` | `glib2` |
| System proxy (KDE) | `kwriteconfig5/6`, `dbus-send` | `kde-cli-tools`, `dbus` | `kde-cli-tools`, `dbus` |
| Secrets | `secret-tool` | `libsecret-tools` | `libsecret` |

---

## When it fails or one site misbehaves

| What you see | Likely cause | What to do |
| --- | --- | --- |
| Direct and tunnel both fail | Local network / DNS / host firewall | Fix local first |
| Direct works, tunnel fails | Server, ports, keys, process | Upstream server docs/logs |
| Most sites fine, a few odd | Rule coverage / mis-judgement | Attribution + Split rules |
| Import never works | Not a client profile | Compare “What the file looks like” |
| Only non-browser apps bypass | Desktop proxy scope | Current desktop limitation |

When filing an issue: symptoms, status-card conclusions, **redacted** config, OS and version. Deeper behaviour: [`RESILIENCE.md`](RESILIENCE.md).

---

## FAQ

**Q: No server, only a third-party subscription URL?**  
A: This project does not operate subscription marketplaces. A lawful **single** WG / OpenVPN / Hysteria2 client profile can be imported. A bare subscription URL is outside the current design.

**Q: Must the server run all three protocols?**  
A: No.

**Q: Does the app upload data?**  
A: No. See [`PRIVACY.md`](../PRIVACY.md).

**Q: Force everything through the tunnel?**  
A: Split rules → all via tunnel (reconnect if the UI says so).

**Q: Where are server install commands?**  
A: Official WireGuard / OpenVPN / Hysteria2 docs, not this repo.

**Q: I changed a rule but behaviour is unchanged?**  
A: Many domain pins hot-reload within ~10s while connected; **mode** changes often need a reconnect. Check Split records for the rule that actually matched.

**Q: Relation to sing-box?**  
A: Independent project; no affiliation. See [`NOTICE.md`](../NOTICE.md).

---

## Where to go next

| Goal | Doc |
| --- | --- |
| Legal boundary | [`LEGAL.md`](LEGAL.md) |
| Privacy | [`../PRIVACY.md`](../PRIVACY.md) |
| Protocol pitfalls | [`PROTOCOLS.md`](PROTOCOLS.md) |
| Rule design & measurements | [`RULES.md`](RULES.md) |
| Resilience & probes | [`RESILIENCE.md`](RESILIENCE.md) |
| Build / contribute | [`../README.md`](../README.md), [`../CONTRIBUTING.md`](../CONTRIBUTING.md) |
| Full index | [`README.md`](README.md) |

中文版：[`USER_GUIDE.zh-CN.md`](USER_GUIDE.zh-CN.md).
