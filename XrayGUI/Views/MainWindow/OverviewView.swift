import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status Card
                GroupBox {
                    HStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(appState.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                                .frame(width: 64, height: 64)
                            Image(systemName: appState.isRunning ? "bolt.fill" : "bolt.slash")
                                .font(.system(size: 28))
                                .foregroundStyle(appState.isRunning ? .green : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(appState.isRunning ? "Running" : "Stopped")
                                .font(.title2.bold())
                                .foregroundStyle(appState.isRunning ? .green : .primary)
                            if let profile = appState.selectedProfile {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(profile.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("No profile selected")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                            HStack(spacing: 4) {
                                Image(systemName: appState.proxyMode.icon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(appState.proxyMode.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button(action: toggleXray) {
                            Text(appState.isRunning ? "Stop" : "Start")
                                .frame(width: 70)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(appState.isRunning ? .red : .green)
                    }
                    .padding(4)
                } label: {
                    Label("Status", systemImage: "circle.fill")
                }

                // Mode Selection Card
                GroupBox {
                    HStack(spacing: 12) {
                        ForEach(ProxyMode.allCases, id: \.self) { mode in
                            ModeCard(mode: mode, isSelected: appState.proxyMode == mode) {
                                appState.proxyMode = mode
                            }
                        }
                    }
                } label: {
                    Label("Proxy Mode", systemImage: "arrow.triangle.branch")
                }

                // Quick Profile Selection
                if !appState.profiles.isEmpty {
                    GroupBox {
                        VStack(spacing: 8) {
                            ForEach(appState.profiles) { profile in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name).font(.subheadline)
                                        Text(profile.configPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if appState.selectedProfile?.id == profile.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { appState.selectedProfileId = profile.id }
                                if profile.id != appState.profiles.last?.id { Divider() }
                            }
                        }
                    } label: {
                        Label("Profiles", systemImage: "doc.on.doc")
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    private func toggleXray() {
        if appState.isRunning {
            XrayCoreManager.shared.stop()
            if appState.proxyMode == .systemProxy { SystemProxyManager.shared.disableSystemProxy() }
        } else {
            guard let profile = appState.selectedProfile else {
                appState.errorMessage = "Please select a profile first."
                return
            }
            do {
                try XrayCoreManager.shared.start(configPath: profile.configPath)
                if appState.proxyMode == .systemProxy { SystemProxyManager.shared.enableSystemProxy() }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}

struct ModeCard: View {
    let mode: ProxyMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(mode.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? .white : .primary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
