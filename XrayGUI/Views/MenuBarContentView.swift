import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if appState.isRunning {
                trafficStrip
                Divider()
            }
            modeSection
            if !appState.nodes.isEmpty {
                Divider().padding(.vertical, 4)
                nodeSection
            }
            Divider().padding(.vertical, 4)
            actions
        }
        .frame(width: 280)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("XrayGUI").font(.headline)
                Text((appState.isRunning ? "Running" : "Stopped").localized)
                    .font(.caption)
                    .foregroundStyle(appState.isRunning ? .green : .secondary)
            }
            Spacer()
            if appState.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: { appState.toggle() }) {
                    Image(systemName: appState.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(appState.isRunning ? .red : .green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var trafficStrip: some View {
        HStack {
            Label(Format.speed(appState.traffic.uplinkRate), systemImage: "arrow.up")
                .foregroundStyle(.secondary)
            Spacer()
            Label(Format.speed(appState.traffic.downlinkRate), systemImage: "arrow.down")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODE".localized).font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6)
            ForEach(ProxyMode.allCases, id: \.self) { mode in
                Button(action: { appState.switchMode(mode) }) {
                    HStack {
                        Image(systemName: mode.icon).frame(width: 16)
                        Text(mode.rawValue.localized)
                        Spacer()
                        if appState.proxyMode == mode {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(appState.proxyMode == mode ? Color.accentColor.opacity(0.1) : .clear)
                .cornerRadius(6).padding(.horizontal, 4)
            }
        }
    }

    private var nodeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROFILE".localized).font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.nodes) { node in
                        Button(action: { appState.selectNode(node.id) }) {
                            HStack {
                                Image(systemName: "point.3.connected.trianglepath.dotted").frame(width: 16)
                                Text(node.name).lineLimit(1)
                                Spacer()
                                LatencyBadge(result: appState.latency[node.id])
                                if appState.selectedNodeId == node.id {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(appState.selectedNodeId == node.id ? Color.accentColor.opacity(0.1) : .clear)
                        .cornerRadius(6).padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            MenuBarButton("Test Latency", icon: "bolt.horizontal") { appState.testAllLatency() }
            MenuBarButton("Open Main Window", icon: "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarButton("Quit", icon: "power") {
                if appState.isRunning { appState.stop() }
                NSApp.terminate(nil)
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
                Text(title.localized)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
