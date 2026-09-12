# XVPN

[![Tests](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/LSD-Apps/XVPN)](https://github.com/LSD-Apps/XVPN/releases/latest)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

**A split-tunnel VPN client that just takes your `.conf`.**

No node picking, no rule writing, no need to know what a geosite is — drop in your
config file and the app handles the rest: traffic matched by the bundled rule sets
goes direct, everything else goes through the tunnel, and DNS is cross-validated by
two separate resolvers.

| | |
| --- | --- |
| Desktop | Windows · Linux |
| Mobile | Android |
| Core | [sing-box](https://github.com/SagerNet/sing-box) 1.14.0 |
| UI | Flutter — one state layer and one palette shared by both platforms |
| License | [GPL-3.0-or-later](LICENSE) (required by the bundled core — see below) |

<sub>English · [简体中文](README.zh-CN.md) · [Privacy](privacy.html) · [Contributing](CONTRIBUTING.md) · [License](LICENSE)</sub>

## What this is — and what it is not

**It is** a config parser and split-tunnel client. You hand it a WireGuard,
OpenVPN or Hysteria2 config; it translates that config into something the core
understands, decides which traffic goes direct and which goes through the tunnel,
and checks whether that decision was wrong.

**It is not** a VPN service. This project ships **no** nodes, servers,
subscriptions, or accounts, and it does **not** implement cryptography — that is
provided by sing-box.

So you need to **bring your own config** (your own server, your company intranet,
or a service you obtained yourself). This is a deliberate design decision; the
reasoning is in [`docs/RELEASE.md`](docs/RELEASE.md).

## What it does for you

| What you might expect to configure | What the app does instead |
| --- | --- |
| Choose which traffic goes where | Bundled `geosite-cn` + `geoip-cn` rule sets — domain and IP, belt and braces |
| Set up DNS with a consistency check | Generates two resolvers: a direct resolver for rule-set matches, an in-tunnel resolver for the rest |
| Understand WireGuard / OpenVPN / Hysteria2 parameters | Parses the config and maps every field to the core; invalid or outdated parameters are corrected automatically |
| Reconfigure on every switch | Remembers multiple profiles; switching reconnects |

Rule sets ship with the app, are unpacked to the app's private directory on first
connect, and can be refreshed incrementally via "Check for updates".

## Supported protocols

Detected by **content**, not by file extension. Adding a protocol means
implementing one adapter — the UI and core layer stay untouched.

- WireGuard (`.conf`)
- OpenVPN (`.ovpn`)
- Hysteria2 (`hysteria2://` share link, the official `config.yaml`, or a sing-box outbound `.json`)

See [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md) (Chinese).

## When something goes wrong

The client heals what it can and tells you the rest:

- The core is restarted automatically after a crash, a dead tunnel, or a wedged
  process — with retry limits, so a genuinely broken node fails fast instead of
  looping.
- If ports 2080/2081 are taken, it picks free ones instead of failing to start.
- The status card shows a failure breakdown (rule miss vs. node problem), the raw
  kernel log, and a per-domain lookup that gathers what is actually known about one
  hostname.

Behaviour, limits, and the measurements behind them are documented in
[`docs/RESILIENCE.md`](docs/RESILIENCE.md) (Chinese).

## Quick start

1. Launch the app.
2. Drag your `.conf` / `.ovpn` into the window (Windows), or use your phone's file
   manager "Open with" → XVPN. You can also pick a file or paste the config text.
3. On first connect, Windows / Linux sets the system proxy; Android asks for VPN
   permission.

On Windows and Linux, closing the window minimizes the app to the system tray
without dropping the connection (on Linux this needs a StatusNotifierItem host —
without one, closing quits). To actually quit, use the tray menu's "Quit XVPN" — it
restores the system proxy and stops the core process, so you are never left with a
broken network.

> **On traffic takeover:** desktop uses the system proxy (no admin rights, works
> immediately for browsers and most apps); Android uses the VpnService TUN (the
> only option there). Desktop TUN would need the wintun driver or a privileged
> helper plus admin rights, which are not bundled, so the settings page
> deliberately **does not offer** that option — see "Directions not supported" in
> [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md).

### Linux desktop

Linux follows the same path as Windows: the core runs as a child process and only
the system proxy is configured. **No root, no privileges.** It therefore also
tunnels **only apps that honour the system proxy** (browsers and most desktop
apps); games and CLI tools have to wait for the TUN phase.

- **Desktop environments:** GNOME-family (gsettings) and KDE (kioslaverc + KIO
  reload) only. Other environments (XFCE, sway, i3, …) expose no common interface,
  so the app reports "could not set the system proxy" instead of pretending.
- **Secrets:** the system keyring (libsecret's `secret-tool`) is preferred. If it
  is missing, credentials are stored **in plain text** and the import form says so
  — the app never claims encryption it does not have.
- **Window:** under X11 the title bar is custom-drawn like on Windows; under
  Wayland move/resize are unreliable, so the custom buttons are hidden and native
  decorations are used.

Runtime dependencies (usually already installed; a missing one only degrades the
matching feature, it never crashes the app):

| Feature | Dependency | Debian/Ubuntu | Fedora / Arch |
| --- | --- | --- | --- |
| System proxy (GNOME) | `gsettings` | `libglib2.0-bin` | `glib2` / `glib2` |
| System proxy (KDE) | `kwriteconfig5/6`, `dbus-send` | `kde-cli-tools`, `dbus` | `kde-cli-tools`, `dbus` |
| Secret storage | libsecret's `secret-tool` | `libsecret-tools` | `libsecret` / `libsecret` |

## Diagnostics

The hard part of a split-tunnel client is not connecting — it is telling apart
three failures that look identical but need opposite responses:

| Symptom | Conclusion | What to do |
| --- | --- | --- |
| Direct connection fails, tunnel works | Local network or DNS problem | Don't blame your node |
| Direct works, tunnel fails | Node/server problem | Changing rules will not help |
| Both work, a few sites fail | Rule coverage gap | The app learns this automatically |

### Automatic correction — the app learns

Two long-tail cases aren't covered by the bundled rule sets, and both look like
"the site won't open and the user has no idea why":

- A host judged direct that resolves to an address inside `geoip-cn` but is not
  actually reachable that way (for example a service fronted by a CDN in the rule
  set's range) → judged direct, and it **fails outright**. The rule set can't fix
  this — it matched *correctly*.
- A domain whose direct-resolved answer differs from the in-tunnel answer, so the
  routing decision was based on an address the app cannot trust.

The app observes the shared consequence: **judged direct, but the connection
failed**. It records such domains, and after 3 consecutive failures switches them
to the tunnel at **highest priority** — injected *before* `geosite-cn` /
`geoip-cn`, otherwise the rule set would judge it direct first.

Learned rules persist, decay, and can be revoked:

- A single **successful direct connection** (bytes actually transferred) resets the
  failure streak; two successes revoke a learned rule — counter-evidence beats
  guessing.
- User-specified rules always take precedence and are never rewritten.
- The "Automatic correction" card in settings lists each rule's **evidence**
  (failure count, reason, bytes tunnelled) and lets you revoke any of them.

### DNS monitoring and cross-validation

sing-box's `/connections` snapshot filters DNS traffic out **server-side**
(`metadata.OutboundType != C.TypeDNS`), so DNS behaviour never shows up in the
connection list — it has to be probed.

1. UDP queries straight to the direct resolvers, timed, to spot a slow or dead one.
2. The Clash API's `/proxies/vpn/delay` makes the core **actually resolve through
   the tunnel**, giving the latency you really feel.
3. **Cross-validation**: the same domain is resolved by the direct resolver and by
   the core's `/dns/query`; the two answer sets are compared and geolocated against
   the `geoip-cn` prefix index.

| Direct answer | vs tunnel answer | Verdict | Action |
| --- | --- | --- | --- |
| Inside `geoip-cn` | Different | Dual deployment | Domain-based routing is correct, no action |
| Outside `geoip-cn` | Completely different | Answers inconsistent | Force through the tunnel (one failure is enough) — a bad answer cannot drive routing |
| Inside `geoip-cn` | Same | Consistent | No action |
| All failed | — | Direct resolution broken | Suggest checking local resolution |

**With no geolocation data, the app does not conclude "inconsistent"** — it would
rather miss one automatic correction than push healthy traffic into the tunnel.
Latency statistics use a rolling-window median rather than a mean: one 3-second
timeout drags the mean from 20 ms past 100 ms, while the median barely moves.

### Statistics

- Bytes are counted **per outbound**, answering "how much of this actually went
  through the tunnel";
- Per-connection upload/download bytes come from the core's exact counters, not
  estimates;
- The "matched rule" column normalises the core's descriptive string
  (`rule_set=[geosite-cn geoip-cn] => route`) into something readable.

### Performance under load

A few targeted choices keep the UI smooth with thousands of connections:

- Split records and failure records use a **fixed-capacity ring buffer** (O(1)
  insert). The original `List.insert(0, x)` shifted all 500 existing entries on
  every insert.
- Filter results are **cached** by (filter, query, records version), so a frame
  reads the same list instance instead of recomputing it every second.
- The set of already-reported connections is bounded and **grows with the actual
  connection count**. The original cleared itself past 2000 entries — at that moment
  every live connection was re-reported, producing bursts of duplicates.
- The observation engine **reuses one HttpClient** (it used to open and tear down a
  TCP connection every second) and guards against re-entry, so slow probes cannot
  pile up timers.
- Cumulative traffic and the connection list are handled separately: the former
  updates every second, the latter builds objects only for genuinely new
  connections. Extracting one new connection out of two thousand is a single pass
  with almost no allocation.

## Platform parity

Desktop and mobile layouts are written separately (desktop sidebar + standalone
pages / mobile bottom tabs + pages folded into settings), but the **presentation
structure must match**: information that matters is explained on both sides, and
operations exist on both sides.

[`app/test/platform_parity_test.dart`](app/test/platform_parity_test.dart) encodes
that principle as assertions. It has already caught several real gaps: no way to
delete a profile on mobile, one card existing only on desktop, and a "retest"
action that existed on neither side (`AppState.refreshDns` / `runSelfCheck` were
written but never called by any UI).

Capabilities themselves may differ per platform — system proxy on desktop,
VpnService TUN on Android — but both sides explain what is used and what its
limitations are.

## Building from source

Requires Flutter 3.44+, Visual Studio (Windows, with the "Desktop development with
C++" workload), and Android SDK + NDK (for Android). For Linux you additionally
need `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`.

```powershell
# Desktop
cd app
flutter build windows

# Linux desktop
cd app
flutter build linux --release

# Android: build the core library first, then package
pwsh scripts/build-libbox.ps1      # produces app/android/app/libs/libbox.aar
cd app; flutter build apk
```

The desktop core binary ships with the repository: `app/assets/bin/sing-box.exe`
on Windows and `app/assets/bin/sing-box` on Linux (both sing-box 1.14.0; origin
and licence in [`NOTICE.md`](NOTICE.md)). The build scripts place them next to the
executable.

`scripts/build-libbox.ps1` fetches the sing-box source and compiles `libbox.aar`
with gomobile. The pitfalls along that toolchain (Go version, linkname checks,
script encoding) are documented in [`docs/ANDROID.md`](docs/ANDROID.md) (Chinese).

## Testing

```powershell
cd app
flutter analyze
flutter test
```

Coverage includes config parsing (WireGuard / OpenVPN / Hysteria2), parameter normalisation,
core config generation, split-log attribution, Clash API parsing, DNS message
codec and cross-validation, the auto-correction table, startup self-check, tunnel
warm-up and health verdicts, WireGuard handshake state, MTU validation, platform
parity, and UI behaviour.

**Protocol behaviour in this project is verified, not guessed.**
Every assertion in `test/protocol_tuning_test.dart` corresponds to a real
`sing-box check` result — for example, "cipher names must be canonical uppercase;
lowercase makes the core fail to start". To reproduce:

```powershell
cd app
dart run tool/build_singbox_config.dart ..\testdata\sample.ovpn build\ovpn.json
assets/bin/sing-box.exe check -c build\ovpn.json
```

### Updating rule sets and the `geoip-cn` prefix index

"Check for updates" in settings genuinely fetches new `.srs` files from upstream.
After a rule set update, the `geoip-cn` prefix index used for DNS cross-validation
must be regenerated (it is derived from `geoip-cn.srs`):

```powershell
pwsh scripts/build-cn-ip-index.ps1
```

## Repository layout

```
app/lib/
  core/          Core integration: sing-box process (Windows), libbox (Android),
                 observation engine, Clash API parsing, DNS client and monitoring,
                 `geoip-cn` prefix index, auto-correction table, startup self-check,
                 core log attribution, rule sets, system proxy
  protocols/     Protocol factory: detects protocol by content, parses into a
                 unified ParsedProfile, normalises parameters into what the core accepts
  screens/       Four pages (connect / split records / profiles / settings) + import flow
  widgets/       Shared components, custom title bar, connect ring, auto-route card
  theme.dart     Dual-theme palette (dark / light); the UI only reads colours via XV.*
app/tool/        Dev tools: generate core config, validate config, build `geoip-cn` prefix index
app/windows/     Custom borderless window, tray, system proxy takeover and restore
app/linux/       Custom borderless window (Wayland fallback), window channel and
                 tray (libayatana-appindicator3, dlopen at runtime — no tray if
                 absent); packaging/ holds the .desktop file and hicolor icons
app/android/     VpnService implementation, VpnService ↔ libbox bridge
design/          Brand assets and UI mockups
docs/            Protocols, rules, self-healing and diagnostics, Android
                 integration, release and platform compliance, store listing
scripts/         Core build script, `geoip-cn` prefix index generator
testdata/        Sample configs used by tests
```

## Implementation notes

- **One UI, two layouts**: switches between a desktop sidebar and a mobile bottom
  tab bar at 900 px. The desktop title bar is drawn by Flutter (so it merges with
  the sidebar after the system title bar is removed), and holds the session timer
  and theme switch.
- **One observation implementation for both platforms**: Windows reads subprocess
  logs, Android reads `libbox` callbacks, but connection observation, rate
  statistics, failure attribution, DNS monitoring, and startup self-check all go
  through the single `CoreMonitor` — they used to be written twice, and one side
  had already fallen behind.
- **Control height has a single source**: `XvControlMetrics.height`. In one row, the
  text field, button, and segmented control were previously 41 / 32 / 36 px —
  and 41 wasn't chosen by anyone, it was just the natural height of a `TextField`.
- **Protocol adapters only translate; normalisation is its own layer**: getting
  cipher names, digest names, or MTU wrong makes the core **fail to start**, with
  errors written for developers. `protocol_tuning.dart` normalises parameters into
  what the core accepts and drops anything it doesn't recognise.
- **Themeable**: follow system / light / dark, shared between the title bar button
  and the settings page.

## Privacy

**XVPN collects nothing.** No accounts, no analytics, no ads, no trackers, no crash
reporting, no backend. Your configs and credentials are stored only on your device.
Split records live in memory and are gone when the app closes.

Full text: [`PRIVACY.md`](PRIVACY.md) (Chinese). Because the app is open source,
every claim in it can be verified against the code — for example, "no analytics
SDK" means the dependency list genuinely contains none.

## License

**GPL-3.0-or-later.**

This is not a preference but a consequence of the dependency: the project uses
[sing-box](https://github.com/SagerNet/sing-box) (GPL-3.0-or-later) as its core, and
on Android that core is **linked into the same process** as a native library, which
forms a combined work under the GPL.

- Full text: [`LICENSE`](LICENSE)
- Third-party components, the upstream additional terms (sing-box restricts the use
  of its name), rule set provenance, and export-control notes: [`NOTICE.md`](NOTICE.md)
- Aggregated licences of the Go modules statically linked into the core binaries:
  [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)

If you redistribute, keep `LICENSE`, `NOTICE.md` and `THIRD-PARTY-NOTICES.md`,
provide a way to obtain the corresponding sing-box source, and **do not** use the
sing-box name or imply any affiliation with the upstream project.

## Usage notice

This project is a **client tool** and provides no nodes or services. You are
responsible for ensuring that the configs and services you use comply with the laws
of your jurisdiction. Release engineering, platform compliance and the release
checklist are documented in [`docs/RELEASE.md`](docs/RELEASE.md) (Chinese).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) (Chinese). The short version: explain *why*
in comments and commit messages, verify protocol behaviour against a real
`sing-box check`, and don't ship UI that promises something the code doesn't do.

## Security

XVPN handles your credentials and decides where all your traffic goes, so security
reports are taken seriously. Report vulnerabilities **privately** via
[GitHub Security Advisories](https://github.com/LSD-Apps/XVPN/security/advisories/new);
see [`SECURITY.md`](SECURITY.md) for scope and supported versions. Release history is
in [`CHANGELOG.md`](CHANGELOG.md).
