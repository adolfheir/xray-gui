import SwiftUI
import AppKit

struct ProfilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false
    @State private var newProfileName = ""
    @State private var newProfilePath = ""
    @State private var editingProfile: Profile?

    var body: some View {
        VStack(spacing: 0) {
            if appState.profiles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    Text("No Profiles")
                        .font(.title2.bold())
                    Text("Add a JSON config file to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Add Profile") { showAddSheet = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($appState.profiles) { $profile in
                        ProfileRow(profile: $profile,
                                   isSelected: appState.selectedProfile?.id == profile.id,
                                   onSelect: { appState.selectedProfileId = profile.id },
                                   onDelete: { deleteProfile(profile) },
                                   onOpenInEditor: { openInEditor(profile) },
                                   onRevealInFinder: { revealInFinder(profile) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem {
                Button(action: { showAddSheet = true }) {
                    Label("Add Profile", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProfileSheet(isPresented: $showAddSheet)
                .environmentObject(appState)
        }
    }

    private func deleteProfile(_ profile: Profile) {
        appState.profiles.removeAll { $0.id == profile.id }
        if appState.selectedProfileId == profile.id {
            appState.selectedProfileId = appState.profiles.first?.id
        }
    }

    private func openInEditor(_ profile: Profile) {
        NSWorkspace.shared.open(profile.configURL)
    }

    private func revealInFinder(_ profile: Profile) {
        NSWorkspace.shared.selectFile(profile.configPath, inFileViewerRootedAtPath: "")
    }
}

struct ProfileRow: View {
    @Binding var profile: Profile
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onOpenInEditor: () -> Void
    let onRevealInFinder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08))
                            .frame(width: 36, height: 36)
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .font(.subheadline.weight(.medium))
                            if !profile.exists {
                                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .labelStyle(.iconOnly)
                            }
                        }
                        Text(profile.configPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

            // Action buttons
            HStack(spacing: 4) {
                IconButton("pencil", tooltip: "Open in Editor", action: onOpenInEditor)
                IconButton("folder", tooltip: "Reveal in Finder", action: onRevealInFinder)
                IconButton("trash", tooltip: "Delete", color: .red, action: onDelete)
            }
        }
        .padding(.vertical, 4)
    }
}

struct IconButton: View {
    let icon: String
    let tooltip: String
    let color: Color
    let action: () -> Void

    init(_ icon: String, tooltip: String, color: Color = .secondary, action: @escaping () -> Void) {
        self.icon = icon
        self.tooltip = tooltip
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

struct AddProfileSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var configPath = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Profile")
                .font(.headline)
                .padding()

            Form {
                TextField("Profile Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Config File Path", text: $configPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") { browseFile() }
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Add") {
                    let profile = Profile(
                        name: name.isEmpty
                            ? URL(fileURLWithPath: configPath).deletingPathExtension().lastPathComponent
                            : name,
                        configPath: configPath
                    )
                    appState.profiles.append(profile)
                    appState.selectedProfileId = profile.id
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(configPath.isEmpty)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 440)
    }

    private func browseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Select Xray Config File"
        panel.message = "Choose a JSON configuration file for Xray"
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }
}
