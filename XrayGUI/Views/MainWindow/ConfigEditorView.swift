import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inspect/validate the *generated* Xray config for the selected node, and view/edit
/// the raw JSON of a saved `Profile`.
///
/// The top picker chooses the source:
/// - `.generated` builds JSON from the currently selected node via `ConfigBuilder`
///   (read-only — it is regenerated on every relevant change).
/// - a specific `Profile` loads the file at `profile.configPath` into an editable buffer
///   that can be saved back to disk.
struct ConfigEditorView: View {
    @EnvironmentObject var appState: AppState

    /// Which document is currently shown in the editor.
    private enum Source: Hashable {
        case generated
        case profile(UUID)
    }

    /// Outcome of the last validation / build attempt.
    private enum Status: Equatable {
        case none
        case valid
        case invalid(String)
    }

    @State private var source: Source = .generated
    /// The text shown in the editor. For `.generated` this is regenerated; for a profile
    /// it is the on-disk contents, edited in place until saved.
    @State private var text: String = ""
    @State private var status: Status = .none
    /// True while editing a profile whose buffer differs from the loaded file.
    @State private var isDirty = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Config".localized)
        .onAppear(perform: reload)
        .onChange(of: source) { _ in reload() }
        .onChange(of: appState.selectedNodeId) { _ in if isGenerated { reload() } }
        .onChange(of: appState.buildOptions) { _ in if isGenerated { reload() } }
        .onChange(of: appState.routing) { _ in if isGenerated { reload() } }
    }

    // MARK: - Header (source picker + actions)

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Source".localized, selection: $source) {
                    Text("Generated".localized).tag(Source.generated)
                    ForEach(appState.profiles) { profile in
                        Text(profile.name).tag(Source.profile(profile.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)

                Spacer()

                Button {
                    validate()
                } label: {
                    Label("Validate".localized, systemImage: "checkmark.seal")
                }
                .help("Validate".localized)

                if isGenerated {
                    Button {
                        exportGenerated()
                    } label: {
                        Label("Export".localized, systemImage: "square.and.arrow.up")
                    }
                    .help("Export".localized)
                    .disabled(appState.selectedNode == nil)

                    Button {
                        reload()
                    } label: {
                        Label("Regenerate".localized, systemImage: "arrow.clockwise")
                    }
                    .help("Regenerate".localized)
                    .disabled(appState.selectedNode == nil)
                } else {
                    Button {
                        saveProfile()
                    } label: {
                        Label("Save".localized, systemImage: "tray.and.arrow.down")
                    }
                    .help("Save".localized)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
                }
            }

            statusBar
        }
        .padding(12)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            switch status {
            case .none:
                if isGenerated {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Read-only generated configuration".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if isDirty {
                    Image(systemName: "pencil.circle").foregroundStyle(.orange)
                    Text("Unsaved changes".localized)
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Color.clear.frame(height: 1)
                }
            case .valid:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Config is valid".localized)
                    .font(.callout)
                    .foregroundStyle(.green)
            case .invalid(let message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Invalid JSON".localized + (message.isEmpty ? "" : ": \(message)"))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isGenerated && appState.selectedNode == nil {
            EmptyState(
                icon: "doc.text.magnifyingglass",
                title: "No node selected",
                subtitle: "Select a node to inspect its generated Xray configuration, or pick a saved profile to edit its raw JSON.",
                actionTitle: nil,
                action: nil
            )
        } else if !isGenerated && currentProfile == nil {
            EmptyState(
                icon: "doc.badge.gearshape",
                title: "Profile not found",
                subtitle: "The selected profile no longer exists."
            )
        } else if !isGenerated, let profile = currentProfile, !profile.exists {
            EmptyState(
                icon: "doc.badge.gearshape",
                title: "Config file not found.",
                subtitle: profile.configPath
            )
        } else {
            editor
        }
    }

    private var editor: some View {
        TextEditor(text: editorBinding)
            .font(.system(.body, design: .monospaced))
            .disableAutocorrection(true)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
    }

    /// Read-only for generated config; editable (and dirty-tracking) for a profile.
    private var editorBinding: Binding<String> {
        if isGenerated {
            return .constant(text)
        }
        return Binding(
            get: { text },
            set: { newValue in
                text = newValue
                isDirty = true
                if status != .none { status = .none }
            }
        )
    }

    // MARK: - Derived state

    private var isGenerated: Bool {
        if case .generated = source { return true }
        return false
    }

    private var currentProfile: Profile? {
        if case .profile(let id) = source {
            return appState.profiles.first(where: { $0.id == id })
        }
        return nil
    }

    // MARK: - Loading

    private func reload() {
        status = .none
        isDirty = false
        if isGenerated {
            loadGenerated()
        } else {
            loadProfile()
        }
    }

    private func loadGenerated() {
        guard let node = appState.selectedNode else {
            text = ""
            return
        }
        if let data = try? ConfigBuilder.buildConfig(
            node: node,
            routing: appState.routing,
            options: appState.buildOptions
        ), let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = ""
            status = .invalid("Could not generate configuration for this node.".localized)
        }
    }

    private func loadProfile() {
        guard let profile = currentProfile else {
            text = ""
            return
        }
        if profile.exists, let contents = try? String(contentsOf: profile.configURL, encoding: .utf8) {
            text = contents
        } else {
            text = ""
        }
    }

    // MARK: - Actions

    private func validate() {
        let data = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .invalid("Empty document".localized)
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            status = .valid
        } catch {
            status = .invalid(error.localizedDescription)
        }
    }

    private func saveProfile() {
        guard let profile = currentProfile else { return }
        // Validate before writing so we never persist broken JSON silently.
        let data = Data(text.utf8)
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            status = .invalid(error.localizedDescription)
            return
        }
        do {
            try data.write(to: profile.configURL, options: .atomic)
            isDirty = false
            status = .valid
            appState.infoMessage = "Saved".localized
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func exportGenerated() {
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = (appState.selectedNode?.name ?? "config") + ".json"
        panel.canCreateDirectories = true
        panel.title = "Export".localized
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                appState.infoMessage = "Saved".localized
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}
