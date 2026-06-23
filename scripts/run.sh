#!/usr/bin/env bash
#
# run.sh — build, ad-hoc sign, and launch XrayGUI for local debugging.
#
#   scripts/run.sh            # regenerate (if needed) + build Debug + launch
#   scripts/run.sh --clean    # clean build first
#   scripts/run.sh --release  # build the Release configuration instead of Debug
#   scripts/run.sh --logs     # after launch, stream the app's logs to the terminal
#   scripts/run.sh --gen      # force `xcodegen generate` before building
#
# XrayGUI is a menu-bar app that also auto-opens its main window on launch (no Dock
# icon). Use System Proxy mode for local debugging — TUN mode needs a Developer
# ID-signed helper + tun2socks.
#
# Each run STOPS any already-running instance first (graceful SIGTERM, then SIGKILL),
# so this doubles as a "restart" command.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Stop any running XrayGUI: SIGTERM (give it a chance to clean up), wait up to ~3s,
# then SIGKILL. If an instance was actually running, also reset the system proxy as a
# safety net so an abruptly-killed instance never leaves the Mac routing into a dead
# port. No-op when nothing is running.
stop_xraygui() {
  pgrep -x XrayGUI >/dev/null || return 0
  echo "▸ asking XrayGUI to quit (graceful — it restores the proxy itself)…"
  # IPC: send a Quit Apple Event. The app's applicationWillTerminate runs its own
  # cleanup (stop xray + restore system proxy / TUN) before exiting.
  osascript -e 'tell application id "com.xraygui.app" to quit' >/dev/null 2>&1 \
    || pkill -TERM -x XrayGUI 2>/dev/null || true
  for _ in $(seq 1 12); do
    pgrep -x XrayGUI >/dev/null || { echo "  ✓ quit"; return 0; }
    sleep 0.25
  done
  # Did not exit in time — force kill, then reset the proxy ourselves as a fallback.
  echo "▸ force-killing + resetting system proxy (fallback)…"
  pkill -KILL -x XrayGUI 2>/dev/null || true
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | grep -v '^\*' \
  | while IFS= read -r svc; do
      networksetup -setwebproxystate "$svc" off 2>/dev/null || true
      networksetup -setsecurewebproxystate "$svc" off 2>/dev/null || true
      networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
    done
}

CONFIG="Debug"
CLEAN=0
STREAM=0
FORCE_GEN=0
for arg in "$@"; do
  case "$arg" in
    --clean)   CLEAN=1 ;;
    --release) CONFIG="Release" ;;
    --logs)    STREAM=1 ;;
    --gen)     FORCE_GEN=1 ;;
    -h|--help)
      sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

command -v xcodegen >/dev/null || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }

# 0) Stop any running instance first (this makes the script double as "restart").
stop_xraygui

# 1) Always (re)generate the Xcode project. XcodeGen globs sources at generation
#    time, so this guarantees newly-added .swift files are picked up — skipping it
#    is the classic "cannot find type … in scope" build failure. It takes <1s.
echo "▸ xcodegen generate"
xcodegen generate >/dev/null

# 2) Build (ad-hoc signed → runs on Apple Silicon without the Gatekeeper "damaged" error).
if [ "$CLEAN" = 1 ]; then
  echo "▸ clean"
  xcodebuild clean -project XrayGUI.xcodeproj -scheme XrayGUI -configuration "$CONFIG" -derivedDataPath build >/dev/null 2>&1 || true
fi

echo "▸ building ($CONFIG)…"
LOG="$(mktemp -t xraygui-build)"
if ! xcodebuild \
      -project XrayGUI.xcodeproj \
      -scheme XrayGUI \
      -configuration "$CONFIG" \
      -derivedDataPath build \
      -destination 'platform=macOS' \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGNING_ALLOWED=YES \
      ENABLE_HARDENED_RUNTIME=NO \
      build >"$LOG" 2>&1; then
  echo "✗ BUILD FAILED:"
  grep -E "error:" "$LOG" | head -30
  echo "  (full log: $LOG)"
  exit 1
fi
echo "✓ build succeeded"

APP="$(find build/Build/Products/"$CONFIG" -name "XrayGUI.app" -maxdepth 2 | head -1)"
[ -n "$APP" ] || { echo "✗ could not locate built XrayGUI.app"; exit 1; }

# 3) Launch a fresh instance (the old one was already stopped in step 0).
echo "▸ launching: $APP"
open "$APP"
echo "  → the main window opens automatically; the menu-bar icon stays for quick toggle."
echo "  → generated config: ~/Library/Application Support/XrayGUI/current-config.json"
echo "  → reset all settings: defaults delete com.xraygui.app"

# 4) Optionally stream logs.
if [ "$STREAM" = 1 ]; then
  echo "▸ streaming logs (Ctrl-C to stop)…"
  log stream --level info --predicate 'process == "XrayGUI"'
fi
