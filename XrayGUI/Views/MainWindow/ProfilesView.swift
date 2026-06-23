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
            ToolbarItem {
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
                        Text(profile.configPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
