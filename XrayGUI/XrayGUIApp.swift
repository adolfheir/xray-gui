import AppKit
import SwiftUI

@main
struct XrayGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appTheme.colorScheme)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Window("XrayGUI", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appTheme.colorScheme)
                .frame(minWidth: 680, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 560)
    }
}

/// Bridges AppKit termination into the app so every quit path runs cleanup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_: Notification) {
        // Single-instance guard: if another copy (same bundle id) is already running,
        // bring it to the front and exit immediately. `exit(0)` is used instead of
        // NSApp.terminate so applicationWillTerminate — which would tear down the OTHER
        // instance's proxy/core — does NOT run for this duplicate. Done in
        // willFinishLaunching so the duplicate never shows any UI.
        let current = NSRunningApplication.current
        let bundleID = current.bundleIdentifier ?? "com.xraygui.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier }
        if let existing = others.first {
            if #available(macOS 14.0, *) {
                existing.activate()
            } else {
                existing.activate(options: [.activateAllWindows])
            }
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Treat SIGTERM (`kill`/`pkill -TERM`, or scripts/run.sh) as a graceful-quit
        // request: route it through the normal terminate path so cleanup runs. The
        // default SIGTERM disposition would kill us instantly, skipping cleanup.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_: Notification) {
        // Runs for menu Quit, an Apple-Event `quit`, and the SIGTERM path above:
        // stop xray-core and restore the system proxy / tear down TUN before exit.
        AppState.terminateCleanup()
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: appState.isRunning ? "circle.fill" : "circle")
                .foregroundStyle(appState.isRunning ? .green : .secondary)
                .font(.system(size: 8))
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .medium))
        }
        // The status item's label appears once at launch — use it to auto-open the
        // main window the first time, so the app doesn't start as an invisible
        // menu-bar-only process.
        .onAppear {
            guard !appState.didShowInitialWindow else { return }
            appState.didShowInitialWindow = true
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
