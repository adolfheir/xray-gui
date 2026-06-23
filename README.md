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
- **Latency testing** — TCP ping per node, "Ping All", and sort-by-latency, with colour-coded badges.
- **Live traffic** — real-time up/down speed and totals via Xray's stats API (`xray api statsquery`).
- **Raw profiles** — power users can still point at hand-written JSON configs and edit/validate them in the built-in config editor.
- **Quality of life** — Launch at Login (`SMAppService`), update check against GitHub Releases, runtime language switch (System / English / 简体中文), filterable live logs.

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

1. A **code-signed** app + helper (Developer ID) whose `SMPrivilegedExecutables` / `SMAuthorizedClients` designated requirements match.
2. The privileged helper installed (Settings → TUN → **Install Helper**, via `SMJobBless`).
3. A **tun2socks** binary path set in Settings.

The helper launches tun2socks (which creates the utun), configures split-default routes, pins the proxy server IP(s) to the original gateway to avoid a routing loop, overrides DNS, and tears everything down cleanly on stop. On unsigned dev builds, helper install reports a clear "requires code signing" message; System Proxy and Manual modes work without signing.

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
│   │   ├── LatencyTester.swift               # TCP ping / URL test
│   │   ├── TrafficStatsManager.swift         # xray api stats polling
│   │   ├── UpdateChecker.swift               # GitHub Releases
│   │   ├── LaunchAtLogin.swift               # SMAppService
│   │   ├── XrayCoreManager.swift             # process lifecycle + crash-restart
│   │   ├── SystemProxyManager.swift          # networksetup + bypass
│   │   ├── HelperClient.swift                # XPC client + SMJobBless install
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
