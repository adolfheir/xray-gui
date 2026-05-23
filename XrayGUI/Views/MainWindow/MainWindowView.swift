import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("Overview", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .tag(0)
                Label("Profiles", systemImage: "doc.on.doc")
                    .tag(1)
                Label("Logs", systemImage: "text.alignleft")
                    .tag(2)
                Label("Settings", systemImage: "gear")
                    .tag(3)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(160)
        } detail: {
            Group {
                switch selectedTab {
                case 0: OverviewView()
                case 1: ProfilesView()
                case 2: LogsView()
                case 3: SettingsView()
                default: OverviewView()
                }
            }
            .environmentObject(appState)
        }
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}
