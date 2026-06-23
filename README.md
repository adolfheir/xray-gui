# XrayGUI

A native macOS menu-bar client for [Xray-core](https://github.com/XTLS/Xray-core), built with SwiftUI for macOS 13+. Import nodes from share links or subscriptions, switch routing modes, test latency, watch live traffic — all in English or 简体中文.

## Features

- **Share-link import** — paste or import from clipboard. Parses `vmess://`, `vless://`, `trojan://`, `ss://` (SIP002 + legacy + SS-2022), `ssr://`, `socks://`, `http(s)://`, `hysteria2://`/`hy2://`, `tuic://` (as exported by Shadowrocket, v2rayN/v2rayNG, Xray clients, and Clash sub-converters). Protocols Xray can't run (SSR/Hysteria2/TUIC) are still stored but clearly marked unsupported.
- **Subscriptions** — add a URL, auto-decode Base64/plaintext, parse all nodes, track `subscription-userinfo` (used/total traffic, expiry), and auto-update on an interval.
- **Config generation** — the app builds a complete Xray JSON config from the selected node + your routing/inbound settings, then validates it with `xray run -test` before launching. Full transport coverage: TCP/WS/gRPC/HTTP2/QUIC/mKCP/HTTPUpgrade/XHTTP, with TLS / REALITY / XTLS and uTLS fingerprints.
- **Proxy modes**
  - **System Proxy** — sets HTTP/HTTPS/SOCKS on every network service via `networksetup`, with a LAN/loopback bypass list.
  - **TUN** — full-device routing via a privileged helper + a `tun2socks` bridge (split-default routes, server-IP pinning to avoid loops, DNS override, clean teardown).
  - **Manual** — run Xray only; configure your apps yourself.
- **Routing** — presets (Global / Bypass Mainland China / Direct / Custom) plus an editable custom-rule table (domain/IP/port/network → proxy/direct/block), `geoip`/`geosite` support, LAN bypass, ad-blocking, and split DNS.
- **Latency & speed testing** — per-node **real through-proxy** measurement: each test spins up a throwaway Xray instance for that node and probes end-to-end, so the number reflects the node actually working (not just a TCP handshake to its IP). "Ping All" (bounded concurrency) + sort-by-latency, plus an on-demand **download-speed test** (Mbps) per node, all colour-coded.
- **Live traffic** — real-time up/down speed and totals via Xray's stats API (`xray api statsquery`).
- **One-click core download** — fetch the matching `xray-core` (and a `tun2socks` bridge) straight from GitHub releases in **Settings**, no manual download/unzip.
- **Raw profiles** — power users can still point at hand-written JSON configs and edit/validate them in the built-in config editor.
- **Quality of life** — Launch at Login (`SMAppService`), update check against GitHub Releases, runtime language switch (System / English / 简体中文), filterable live logs.

## Install (from a Release)

1. Download `XrayGUI-<version>-macOS.zip` from the [Releases](https://github.com/adolfheir/xray-gui/releases) page and unzip it.
2. Move **`XrayGUI.app`** into `/Applications`.
3. **First launch — clear the Gatekeeper block.** The app is not notarized (no paid Apple Developer ID), so macOS refuses it with *"XrayGUI is damaged or can't be opened"* — especially on Apple Silicon, which requires every arm64 binary to carry at least an ad-hoc signature. Run these two commands once:

   ```bash
   # remove the "downloaded from the internet" quarantine
   xattr -cr /Applications/XrayGUI.app
   # ad-hoc re-sign the app + embedded helper so Apple Silicon will run it
   codesign --force --deep --sign - /Applications/XrayGUI.app
   ```

   Then open it normally (or right-click → **Open**). The icon appears in the **menu bar** — the app has no Dock window by design.
4. **Get an Xray binary.** XrayGUI does not bundle the core. Easiest: **Settings → Xray Core → Download from GitHub** fetches the matching build and installs it automatically. (Manual alternative: download `xray` for macOS from [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases) — `darwin-arm64` for Apple Silicon, `darwin-amd64` for Intel — unzip, then browse to the `xray` executable and click **Test**.)
5. **Add nodes and connect.** Open the menu-bar icon → **Open Main Window**:
   - **Subscriptions** tab → add your subscription URL (auto-fetches nodes), or
   - **Nodes** tab → **Import from Clipboard** to paste `vmess:// / vless:// / trojan:// / ss://` links.
   - **Overview** tab → pick a node, choose **System Proxy** mode, and click **Start**.
   - Optionally set split routing in the **Routing** tab (e.g. *Bypass Mainland China*).

> **Notes**
> - `System Proxy` and `Manual` modes work with the unsigned release. **TUN mode does NOT work on the unsigned download** — it needs a root privileged helper, and modern macOS (AMFI + Background Task Management) refuses to launch an ad-hoc-signed privileged daemon via *any* mechanism (`SMAppService`, the legacy `SMJobBless`, or even a manually-`launchctl`-bootstrapped LaunchDaemon — the daemon is killed and its files removed, even after a reboot). TUN therefore requires a **Developer ID–signed build** plus a `tun2socks` binary (Settings → TUN). The helper code is already wired for `SMAppService`, so a signed build needs no code changes.
> - macOS may still show a Gatekeeper prompt the very first time — choose **Open**. If you re-download a new version, run the two commands again on the new copy.

## Requirements

- macOS 13.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Xray binary from [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases) (extract `xray` from the `darwin-arm64`/`darwin-amd64` zip)
- *(optional, TUN only)* a `tun2socks`-compatible binary (e.g. [xjasonlyu/tun2socks](https://github.com/xjasonlyu/tun2socks))

## Build & Run

```bash
brew install xcodegen
cd /path/to/xray-gui
xcodegen generate
open XrayGUI.xcodeproj   # build & run the XrayGUI scheme
```

The privileged helper is built automatically and embedded at `Contents/Library/LaunchServices/com.xraygui.helper`.

## Configuration

1. **Settings → Xray Core** — Browse to your `xray` binary, click Test to confirm.
2. **Nodes / Subscriptions** — Add a subscription URL, or import share links from the clipboard.
3. **Overview** — pick a node, choose a mode, and Start. Routing and ports live in the Routing and Settings tabs.

### System Proxy mode

Sets HTTP/HTTPS/SOCKS proxies on all network services to `127.0.0.1` at the configured ports (defaults: HTTP 10809, SOCKS 10808) and applies a bypass list for loopback and private LAN ranges. No `sudo` needed for an unsigned, non-sandboxed app.

### TUN mode

TUN routes the whole device through Xray. It requires:

1. A **Developer ID–signed** app + helper. macOS enforces code signing on privileged daemons; an ad-hoc/unsigned helper is rejected by AMFI/BTM and will not launch (see the install Notes above). This is a hard platform requirement, not a config option.
2. The privileged helper installed (Settings → TUN → **Install Helper**, registered via `SMAppService`, macOS 13+).
3. A **tun2socks** binary — set its path in Settings, or fetch it via **Download from GitHub**.

The helper launches tun2socks (which creates the utun), configures split-default routes, pins the proxy server IP(s) to the original gateway to avoid a routing loop, overrides DNS, and tears everything down cleanly on stop. On unsigned builds, **Install Helper** registers the job but launchd refuses to start it (code-signing wall); System Proxy and Manual modes work without signing.

## Architecture

```
xray-gui/
├── project.yml                       # XcodeGen config (app embeds the helper)
├── Shared/
│   ├── XPCProtocol.swift             # privileged-helper XPC contract
│   └── TunConfig.swift               # TUN start parameters (app ↔ helper)
├── XrayGUI/
│   ├── AppState.swift                # @MainActor single source of truth + orchestration
│   ├── Models/                       # ProxyNode, Subscription, RoutingSettings, ConfigBuildOptions, Profile, LogEntry
│   ├── Services/
│   │   ├── ShareLink/ShareLinkParser.swift   # all share-link formats → ProxyNode
│   │   ├── ConfigBuilder.swift               # ProxyNode + settings → Xray JSON
│   │   ├── SubscriptionManager.swift         # fetch + decode + parse
│   │   ├── LatencyTester.swift               # TCP ping / URL latency / download-speed
│   │   ├── NodeLatencyProbe.swift            # throwaway-instance real through-proxy probe
│   │   ├── TrafficStatsManager.swift         # xray api stats polling
│   │   ├── XrayCoreDownloader.swift          # fetch xray-core + geo data from GitHub
│   │   ├── Tun2socksDownloader.swift         # fetch tun2socks bridge from GitHub
│   │   ├── UpdateChecker.swift               # GitHub Releases
│   │   ├── LaunchAtLogin.swift               # SMAppService (login item)
│   │   ├── XrayCoreManager.swift             # process lifecycle + crash-restart
│   │   ├── SystemProxyManager.swift          # networksetup + bypass
│   │   ├── SystemProxyGuard.swift            # restore proxy if changed externally
│   │   ├── NetworkMonitor.swift / PowerEventMonitor.swift  # reconnect on net/sleep
│   │   ├── HelperClient.swift                # XPC client + SMAppService daemon install
│   │   └── TunManager.swift                  # TUN orchestration (server-IP resolve)
│   ├── Support/Localization.swift            # runtime language switching
│   ├── Resources/{en,zh-Hans}.lproj/         # Localizable.strings
│   └── Views/                                # Components + Overview/Nodes/Subscriptions/Routing/Profiles/Logs/Settings/ConfigEditor + MenuBar
└── XrayHelper/                       # root helper: TUN interface, routes, DNS, tun2socks bridge
```

## CI/CD

- **CI** (`.github/workflows/ci.yml`) — on every PR/push: `xcodegen generate` + universal `xcodebuild` of app **and** embedded helper, plus a non-blocking SwiftFormat lint.
- **Release** (`.github/workflows/release.yml`) — on a `v*` tag: inject the version into Info.plist, build a universal Release `.app`, zip with a SHA-256 checksum, and publish a GitHub Release.

## Notes

- Not sandboxed — required for `Process()`, `networksetup`, and XPC to the privileged helper. Hardened Runtime is enabled; the helper disables library validation.
- Logs are capped at 2000 lines in memory; generated configs live in `~/Library/Application Support/XrayGUI/`.
