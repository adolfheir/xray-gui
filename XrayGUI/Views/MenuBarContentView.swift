import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("XrayGUI")
                        .font(.headline)
                    Text(appState.isRunning ? "Running" : "Stopped")
                        .font(.caption)
                        .foregroundStyle(appState.isRunning ? .green : .secondary)
                }
                Spacer()
                Button(action: toggleXray) {
                    Image(systemName: appState.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(appState.isRunning ? .red : .green)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Mode selection
            VStack(alignment: .leading, spacing: 4) {
                Text("MODE")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)

                ForEach(ProxyMode.allCases, id: \.self) { mode in
                    Button(action: { switchMode(mode) }) {
                        HStack {
                            Image(systemName: mode.icon)
                                .frame(width: 16)
                            Text(mode.rawValue)
                            Spacer()
                            if appState.proxyMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(appState.proxyMode == mode ? Color.accentColor.opacity(0.1) : Color.clear)
                    .cornerRadius(6)
                    .padding(.horizontal, 4)
                }
            }

            if !appState.profiles.isEmpty {
                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PROFILE")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    ForEach(appState.profiles) { profile in
                        Button(action: { selectProfile(profile) }) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .frame(width: 16)
                                Text(profile.name)
                                    .lineLimit(1)
                                Spacer()
                                if appState.selectedProfile?.id == profile.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(appState.selectedProfile?.id == profile.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                        .padding(.horizontal, 4)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            // Actions
            VStack(spacing: 0) {
                MenuBarButton("Open Main Window", icon: "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuBarButton("Quit", icon: "power") {
                    if appState.isRunning {
                        XrayCoreManager.shared.stop()
                        SystemProxyManager.shared.disableSystemProxy()
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        .frame(width: 260)
        .padding(.bottom, 4)
    }

    private func toggleXray() {
        if appState.isRunning {
            XrayCoreManager.shared.stop()
            if appState.proxyMode == .systemProxy {
                SystemProxyManager.shared.disableSystemProxy()
            }
        } else {
            guard let profile = appState.selectedProfile else {
                appState.errorMessage = "No profile selected. Add a profile first."
                return
            }
            do {
                try XrayCoreManager.shared.start(configPath: profile.configPath)
                if appState.proxyMode == .systemProxy {
                    SystemProxyManager.shared.enableSystemProxy()
                }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    private func switchMode(_ mode: ProxyMode) {
        let wasRunning = appState.isRunning
        if wasRunning && appState.proxyMode == .systemProxy {
            SystemProxyManager.shared.disableSystemProxy()
        }
        appState.proxyMode = mode
        if wasRunning && mode == .systemProxy {
            SystemProxyManager.shared.enableSystemProxy()
        }
    }

    private func selectProfile(_ profile: Profile) {
        appState.selectedProfileId = profile.id
        if appState.isRunning {
            XrayCoreManager.shared.stop()
            if appState.proxyMode == .systemProxy {
                SystemProxyManager.shared.disableSystemProxy()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                try? XrayCoreManager.shared.start(configPath: profile.configPath)
                if self.appState.proxyMode == .systemProxy {
                    SystemProxyManager.shared.enableSystemProxy()
                }
            }
        }
    }
}

struct MenuBarButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
