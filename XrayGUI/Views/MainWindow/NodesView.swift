import AppKit
import SwiftUI

/// The "Nodes" tab of the main window: lists every proxy node grouped by its
/// originating subscription (plus a "Manual" section), with import / ping / sort
/// actions in the toolbar and per-row actions (test, copy, delete).
struct NodesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showImportSheet = false
    @State private var showNewNode = false
    @State private var nodeToEdit: ProxyNode?

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
        .sheet(isPresented: $showNewNode) {
            NodeEditorView(node: nil)
                .environmentObject(appState)
        }
        .sheet(item: $nodeToEdit) { node in
            NodeEditorView(node: node)
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
                showNewNode = true
            } label: {
                Label("New Node".localized, systemImage: "square.and.pencil")
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
                                NodeRow(node: node) { nodeToEdit = node }
                            }
                        }
                    }
                }

                let manual = appState.manualNodes
                if !manual.isEmpty {
                    Section("Manual".localized) {
                        ForEach(manual) { node in
                            NodeRow(node: node) { nodeToEdit = node }
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
    var onEdit: () -> Void = {}
    @State private var showShareSheet = false

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

            SpeedBadge(result: appState.speed[node.id])

            LatencyBadge(result: appState.latency[node.id])

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack(spacing: 4) {
                IconButton("bolt.horizontal", tooltip: "Test Latency".localized) {
                    appState.testLatency(node)
                }
                IconButton("speedometer", tooltip: "Test Speed".localized) {
                    appState.testSpeed(node)
                }
                IconButton("doc.on.clipboard", tooltip: "Copy Link".localized) {
                    guard let link = ShareLinkExporter.export(node) else { return }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(link, forType: .string)
                }
                IconButton("qrcode", tooltip: "Share QR".localized) {
                    showShareSheet = true
                }
                IconButton("pencil", tooltip: "Edit".localized) {
                    onEdit()
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
        .sheet(isPresented: $showShareSheet) {
            NodeShareSheet(node: node)
        }
    }
}

/// A modal sheet that shares a single node as a QR code plus its share link text.
///
/// The link is produced by ``ShareLinkExporter`` (original `rawLink` when present,
/// otherwise a freshly built URI). When the node can't be exported a friendly
/// notice is shown instead.
struct NodeShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let node: ProxyNode

    private var link: String? { ShareLinkExporter.export(node) }

    var body: some View {
        VStack(spacing: 14) {
            Text(node.name)
                .font(.headline)
                .lineLimit(1)

            if let link {
                content(for: link)
            } else {
                Spacer()
                Text("This node can't be exported to a share link.".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()

                Button("Done".localized) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func content(for link: String) -> some View {
        if let qr = QRCodeGenerator.image(from: link) {
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .background(Color.white)
                .cornerRadius(8)
        }

        ScrollView {
            Text(link)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 90)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)

        HStack {
            Button("Copy Link".localized) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(link, forType: .string)
            }
            Spacer()
            Button("Done".localized) { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
