import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header: custom profile toggle.
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $appState.useCustomProfile) {
                    Text("Use custom profile".localized)
                        .font(.headline)
                }
                .toggleStyle(.switch)

                Text("When enabled, the selected raw profile is launched instead of the generated node config.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if appState.profiles.isEmpty {
                EmptyState(
                    icon: "doc.text",
                    title: "No Profiles",
                    subtitle: "Add a JSON config file to get started.",
                    actionTitle: "Add Profile",
                    action: { showAddSheet = true }
                )
            } else {
                List {
                    ForEach($appState.profiles) { $profile in
                        ProfileRow(profile: $profile)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Profiles".localized)
        .toolbar {
            ToolbarItemGroup {
                Button(action: { appState.saveGeneratedConfigAsProfile() }) {
                    Label("Save current config".localized, systemImage: "doc.badge.plus")
                }
                .help("Save the generated config of the selected node as a profile.".localized)
                .disabled(!appState.canSnapshotGeneratedConfig)

                Button(action: { showAddSheet = true }) {
                    Label("Add Profile".localized, systemImage: "plus")
                }
                .help("Add Profile".localized)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProfileSheet()
                .environmentObject(appState)
        }
    }
}

struct ProfileRow: View {
    @EnvironmentObject var appState: AppState
    @Binding var profile: Profile
    /// Read-only reverse-mapping of the profile JSON, parsed lazily for the inline summary.
    @State private var inspected: ProfileInspector.Inspected?
    @State private var showInspector = false

    private var isSelected: Bool {
        appState.selectedProfile?.id == profile.id
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { appState.selectedProfileId = profile.id }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08))
                            .frame(width: 36, height: 36)
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .font(.subheadline.weight(.bold))
                            if !profile.exists {
                                Badge(text: "Missing".localized, color: .orange)
                            }
                        }
                        // Reverse-mapped one-line summary so the merged/raw config is
                        // readable at a glance without opening the file.
                        if let inspected {
                            Text(inspected.headline)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(profile.configPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Row actions.
            HStack(spacing: 4) {
                IconButton("eye", tooltip: "Inspect".localized) {
                    showInspector = true
                }
                .disabled(inspected == nil)
                IconButton("pencil", tooltip: "Open in Editor".localized) {
                    NSWorkspace.shared.open(profile.configURL)
                }
                IconButton("folder", tooltip: "Reveal in Finder".localized) {
                    NSWorkspace.shared.selectFile(profile.configPath, inFileViewerRootedAtPath: "")
                }
                IconButton("trash", tooltip: "Delete".localized, color: .red) {
                    deleteProfile()
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: profile.configPath) {
            inspected = ProfileInspector.inspect(path: profile.configPath)
        }
        .sheet(isPresented: $showInspector) {
            if let inspected {
                ProfileInspectorSheet(profileName: profile.name, inspected: inspected)
            }
        }
    }

    private func deleteProfile() {
        let removedId = profile.id
        appState.profiles.removeAll { $0.id == removedId }
        if appState.selectedProfileId == removedId {
            appState.selectedProfileId = appState.profiles.first?.id
        }
    }
}

struct AddProfileSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var configPath = ""

    private var canAdd: Bool {
        !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Profile".localized)
                .font(.headline)
                .padding()

            Form {
                TextField("Profile Name".localized, text: $name)

                HStack(spacing: 8) {
                    TextField("Config File Path".localized, text: $configPath)
                    Button("Browse".localized) { browseFile() }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel".localized) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add".localized) { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private func browseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Select Xray Config File".localized
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func add() {
        let trimmedPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        var finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalName.isEmpty {
            finalName = URL(fileURLWithPath: trimmedPath).deletingPathExtension().lastPathComponent
        }
        let profile = Profile(name: finalName, configPath: trimmedPath)
        appState.profiles.append(profile)
        appState.selectedProfileId = profile.id
        dismiss()
    }
}

// MARK: - Read-only inspector

/// A read-only breakdown of a profile's raw JSON: its inbounds, outbounds (reverse-mapped
/// to nodes), routing rules and DNS. It never edits the source file — it only projects the
/// config so a merged/custom profile is browsable like the rest of the app.
struct ProfileInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profileName: String
    let inspected: ProfileInspector.Inspected

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profileName).font(.headline).lineLimit(1)
                    Text(inspected.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done".localized) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    outboundsSection
                    inboundsSection
                    routingSection
                    dnsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder
    private var outboundsSection: some View {
        if !inspected.outbounds.isEmpty {
            Card("Outbounds", systemImage: "arrow.up.forward") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(inspected.outbounds) { outbound in
                        switch outbound {
                        case .node(let node):
                            InspectedNodeRow(node: node)
                        case .plain(_, let tag, let proto):
                            HStack(spacing: 8) {
                                Badge(text: proto, color: .secondary)
                                Text(tag ?? proto)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inboundsSection: some View {
        if !inspected.inbounds.isEmpty {
            Card("Inbounds", systemImage: "arrow.down.forward") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inspected.inbounds) { inbound in
                        HStack(spacing: 8) {
                            Badge(text: inbound.proto, color: .accentColor)
                            Text([inbound.listen, inbound.port].compactMap { $0 }.joined(separator: ":"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let tag = inbound.tag {
                                Text(tag).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var routingSection: some View {
        if !inspected.rules.isEmpty || inspected.domainStrategy != nil || !inspected.balancers.isEmpty {
            Card("Routing", systemImage: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 6) {
                    if let strategy = inspected.domainStrategy {
                        labeledLine("Domain Strategy".localized, strategy)
                    }
                    if !inspected.balancers.isEmpty {
                        labeledLine("Balancer".localized, inspected.balancers.joined(separator: ", "))
                    }
                    if inspected.hasObservatory {
                        labeledLine("Health Check".localized, "Enabled".localized)
                    }
                    ForEach(inspected.rules) { rule in
                        HStack(alignment: .top, spacing: 8) {
                            Badge(text: rule.target, color: .blue)
                            Text(rule.matcher)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dnsSection: some View {
        if !inspected.dnsServers.isEmpty {
            Card("DNS", systemImage: "globe") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(inspected.dnsServers.enumerated()), id: \.offset) { _, server in
                        Text(server)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func labeledLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label + ":").font(.caption.weight(.semibold))
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A compact, non-interactive node row used inside the profile inspector. Unlike
/// `NodeRow` it carries no selection/test/delete actions — the inspected node is a
/// projection of the raw config, not a managed node.
struct InspectedNodeRow: View {
    let node: ProxyNode

    var body: some View {
        HStack(spacing: 10) {
            Badge(text: node.protocolType.displayName, color: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name).font(.caption.weight(.semibold))
                    if !node.supportedByXray {
                        Badge(text: "Unsupported".localized, color: .orange)
                    }
                }
                Text(node.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}
