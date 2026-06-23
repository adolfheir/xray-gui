import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: Tab = .overview

    enum Tab: Hashable {
        case overview, nodes, subscriptions, routing, profiles, logs, settings
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview".localized, systemImage: "gauge.with.dots.needle.bottom.50percent").tag(Tab.overview)
                Label("Nodes".localized, systemImage: "point.3.connected.trianglepath.dotted").tag(Tab.nodes)
                Label("Subscriptions".localized, systemImage: "antenna.radiowaves.left.and.right").tag(Tab.subscriptions)
                Label("Routing".localized, systemImage: "arrow.triangle.branch").tag(Tab.routing)
                Label("Profiles".localized, systemImage: "doc.on.doc").tag(Tab.profiles)
                Label("Logs".localized, systemImage: "text.alignleft").tag(Tab.logs)
                Label("Settings".localized, systemImage: "gear").tag(Tab.settings)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        } detail: {
            Group {
                switch selection {
                case .overview: OverviewView()
                case .nodes: NodesView()
                case .subscriptions: SubscriptionsView()
                case .routing: RoutingView()
                case .profiles: ProfilesView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            // Give the detail column a definite minimum width. Without it, a fully
            // flexible detail (e.g. the Profiles empty state, which fills both axes
            // with no intrinsic width) lets NavigationSplitView relayout the split so
            // aggressively that the sidebar's rows stop rendering — leaving an empty
            // sidebar the user can't navigate out of.
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(appState)
        }
        .alert("Error".localized, isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK".localized) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let info = appState.infoMessage {
                Text(info)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // .task(id:) cancels and restarts when the message changes, so an
                    // older auto-dismiss timer can never clear a newer toast.
                    .task(id: info) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation { appState.infoMessage = nil }
                    }
            }
        }
        .animation(.easeInOut, value: appState.infoMessage)
    }
}
