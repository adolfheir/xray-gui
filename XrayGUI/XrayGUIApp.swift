import SwiftUI

@main
struct XrayGUIApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Window("XrayGUI", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 680, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 560)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: appState.isRunning ? "circle.fill" : "circle")
                .foregroundStyle(appState.isRunning ? .green : .secondary)
                .font(.system(size: 8))
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .medium))
        }
    }
}
