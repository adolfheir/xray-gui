# XrayGUI

A native macOS menu bar app for managing [Xray-core](https://github.com/XTLS/Xray-core) proxy. Built with SwiftUI targeting macOS 13+.

## Features

- Menu bar icon with quick start/stop toggle
- Multiple proxy modes: System Proxy (HTTP/SOCKS via `networksetup`), TUN (via privileged helper), Manual
- Profile management: add/select/delete JSON config files, open in editor, reveal in Finder
- Live log output with level filtering and search
- Settings: xray binary path, HTTP/SOCKS proxy ports, TUN helper installation
- Single source of truth via `AppState` — no sandboxing, full process control

## Requirements

- macOS 13.0 or later
- [Xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Xray binary from [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases)
  - Download the `darwin-arm64` or `darwin-amd64` zip, extract `xray`

## Setup

```bash
# 1. Install xcodegen if needed
brew install xcodegen

# 2. Generate the Xcode project
cd /path/to/xray-gui
xcodegen generate

# 3. Open in Xcode
open XrayGUI.xcodeproj
```

Build and run the `XrayGUI` scheme. The app appears in the menu bar.

## Configuration

1. **Set Xray binary path** — open Settings tab, click Browse and select your `xray` executable, or paste the path directly. Click Test to verify.
2. **Add a profile** — go to the Profiles tab, click the `+` button, browse for your JSON config file.
3. **Select the profile** in Overview or Profiles, then click Start.

### System Proxy mode

When System Proxy mode is active, XrayGUI calls `networksetup` to set HTTP and SOCKS5 proxies on all network services to `127.0.0.1` at the configured ports (defaults: HTTP 10809, SOCKS 10808). No `sudo` required for unsigned, non-sandboxed apps.

### TUN mode

TUN mode uses a privileged helper (`XrayHelper`) installed at `/Library/PrivilegedHelperTools/com.xraygui.helper` via `SMJobBless`. This requires:

1. Both the app and helper must be **code-signed** with a valid Developer ID.
2. The `SMPrivilegedExecutables` key in `XrayGUI/Info.plist` and `SMAuthorizedClients` in `XrayHelper/Info.plist` must match the signing identity.
3. Click **Install Helper** in Settings — this triggers the macOS authorization prompt.

For local development without signing, TUN mode will show a "requires code signing" message. System Proxy and Manual modes work without signing.

## Project Structure

```
xray-gui/
├── project.yml                    # XcodeGen config
├── Shared/
│   └── XPCProtocol.swift         # XPC protocol shared by app + helper
├── XrayGUI/
│   ├── Extensions.swift           # Int.nonZero helper
│   ├── AppState.swift             # @MainActor ObservableObject, single source of truth
│   ├── XrayGUIApp.swift           # @main entry, MenuBarExtra + Window scenes
│   ├── Models/
│   │   ├── Profile.swift
│   │   └── LogEntry.swift
│   ├── Services/
│   │   ├── XrayCoreManager.swift  # Process lifecycle, stdout/stderr piping
│   │   ├── SystemProxyManager.swift
│   │   └── HelperClient.swift     # NSXPCConnection to privileged helper
│   └── Views/
│       ├── MenuBarContentView.swift
│       └── MainWindow/
│           ├── MainWindowView.swift
│           ├── OverviewView.swift
│           ├── ProfilesView.swift
│           ├── LogsView.swift
│           └── SettingsView.swift
└── XrayHelper/
    ├── main.swift                 # NSXPCListener entry point
    └── Helper.swift               # XPC service: TUN, routes, DNS
```

## Notes

- The app is **not sandboxed** — required for `Process()`, `networksetup`, and XPC to the privileged helper.
- Hardened Runtime is enabled; disable library validation is set for the helper.
- Log entries are capped at 2000 lines in memory.
- Launch at Login is stubbed — implement using `SMAppService` once the app has a stable bundle ID and is signed.
