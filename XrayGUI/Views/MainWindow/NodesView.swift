import AppKit
import SwiftUI

/// The "Nodes" tab of the main window: lists every proxy node grouped by its
/// originating subscription (plus a "Manual" section), with import / ping / sort
/// actions in the toolbar and per-row actions (test, copy, delete).
struct NodesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showImportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .sheet(isPresented: $showImportSheet) {
            ImportLinksSheet()
                .environmentObject(appState)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                showImportSheet = true
            } label: {
                Label("Add".localized, systemImage: "plus")
            }

            Button {
                appState.importFromClipboard()
            } label: {
                Label("Import from Clipboard".localized, systemImage: "doc.on.clipboard")
            }

            Spacer()

            Button {
                appState.testAllLatency()
            } label: {
                Label("Ping All".localized, systemImage: "bolt.horizontal")
            }
            .disabled(appState.nodes.isEmpty)

            Button {
                appState.sortNodesByLatency()
            } label: {
                Label("Sort by Latency".localized, systemImage: "arrow.up.arrow.down")
            }
            .disabled(appState.nodes.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.nodes.isEmpty {
            EmptyState(
                icon: "point.3.connected.trianglepath.dotted",
                title: "No Nodes",
                subtitle: "Add a subscription or import a share link to get started.",
                actionTitle: "Add Node",
                action: { showImportSheet = true }
            )
        } else {
            List {
                ForEach(appState.subscriptions) { sub in
                    let subNodes = appState.nodes(in: sub.id)
                    if !subNodes.isEmpty {
                        Section(sub.name) {
                            ForEach(subNodes) { node in
                                NodeRow(node: node)
                            }
                        }
                    }
                }

                let manual = appState.manualNodes
                if !manual.isEmpty {
                    Section("Manual".localized) {
                        ForEach(manual) { node in
                            NodeRow(node: node)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// A single node row: protocol badge, name + summary, latency/selection indicators,
/// and trailing action buttons (test latency, copy share link, delete).
struct NodeRow: View {
    @EnvironmentObject var appState: AppState
    let node: ProxyNode

    private var isSelected: Bool { appState.selectedNodeId == node.id }

    var body: some View {
        HStack(spacing: 10) {
            Badge(text: node.protocolType.displayName, color: .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name).fontWeight(.semibold)
                    if !node.supportedByXray {
                        Badge(text: "Unsupported".localized, color: .orange)
                    }
                }
                Text(node.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            LatencyBadge(result: appState.latency[node.id])

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack(spacing: 4) {
                IconButton("bolt.horizontal", tooltip: "Test Latency".localized) {
                    appState.testLatency(node)
                }
                IconButton("doc.on.clipboard", tooltip: "Copy Link".localized) {
                    guard let link = node.rawLink else { return }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(link, forType: .string)
                }
                IconButton("trash", tooltip: "Delete".localized, color: .red) {
                    appState.removeNode(node.id)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectNode(node.id)
        }
    }
}

/// A modal sheet for pasting one or more share links to import as manual nodes.
struct ImportLinksSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Links".localized)
                .font(.headline)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(4)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(8)

                if text.isEmpty {
                    Text("Paste share links (vmess://, vless://, trojan://, ss://, …)".localized)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Spacer()
                Button("Cancel".localized) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Import".localized) {
                    appState.importLinks(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460, height: 320)
    }
}
