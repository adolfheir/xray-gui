import SwiftUI

/// The main-window landing tab: a live status summary, traffic counters,
/// proxy-mode picker, and a quick node selector — all driven by `AppState`.
struct OverviewView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                if appState.isRunning {
                    trafficCard
                }
                proxyModeCard
                if !appState.nodes.isEmpty {
                    nodesCard
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview".localized)
    }

    // MARK: - Status

    private var statusCard: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .fill((appState.isRunning ? Color.green : Color.secondary).opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: appState.isRunning ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(appState.isRunning ? Color.green : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.isRunning ? "Running".localized : "Stopped".localized)
                        .font(.title2.bold())

                    if let node = appState.selectedNode {
                        Text(node.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text("No node selected".localized)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: appState.proxyMode.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appState.proxyMode.rawValue.localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: { appState.toggle() }) {
                    HStack(spacing: 6) {
                        if appState.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: appState.isRunning ? "stop.fill" : "play.fill")
                        }
                        Text(appState.isRunning ? "Stop".localized : "Start".localized)
                            .frame(minWidth: 56)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(appState.isRunning ? .red : .green)
                .disabled(appState.isBusy)
            }
        }
    }

    // MARK: - Traffic

    private var trafficCard: some View {
        Card("Traffic", systemImage: "chart.bar.xaxis") {
            HStack(spacing: 10) {
                StatTile(label: "Upload",
                         value: Format.speed(appState.traffic.uplinkRate),
                         systemImage: "arrow.up",
                         tint: .blue)
                StatTile(label: "Download",
                         value: Format.speed(appState.traffic.downlinkRate),
                         systemImage: "arrow.down",
                         tint: .green)
                StatTile(label: "Total Upload",
                         value: Format.bytes(appState.traffic.uplinkTotal),
                         systemImage: "arrow.up.circle",
                         tint: .blue)
                StatTile(label: "Total Download",
                         value: Format.bytes(appState.traffic.downlinkTotal),
                         systemImage: "arrow.down.circle",
                         tint: .green)
            }
        }
    }

    // MARK: - Proxy Mode

    private var proxyModeCard: some View {
        Card("Proxy Mode", systemImage: "switch.2") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(ProxyMode.allCases, id: \.self) { mode in
                        OverviewModeCard(mode: mode,
                                         isSelected: appState.proxyMode == mode) {
                            appState.switchMode(mode)
                        }
                    }
                }
                Text(appState.proxyMode.descriptionKey.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Current Nodes

    private var nodesCard: some View {
        Card("Current Node", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button(action: { appState.testAllLatency() }) {
                        Label("Test Latency".localized, systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                VStack(spacing: 2) {
                    ForEach(appState.nodes) { node in
                        nodeRow(node)
                        if node.id != appState.nodes.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func nodeRow(_ node: ProxyNode) -> some View {
        let isSelected = appState.selectedNodeId == node.id
        return Button(action: { appState.selectNode(node.id) }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(node.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                LatencyBadge(result: appState.latency[node.id])
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A selectable tile representing a single `ProxyMode` in the Overview mode picker.
struct OverviewModeCard: View {
    let mode: ProxyMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.system(size: 22, weight: .medium))
                Text(mode.rawValue.localized)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.08))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
