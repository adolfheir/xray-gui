import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var filterLevel: LogEntry.Level? = nil
    @State private var searchText = ""
    @State private var autoScroll = true

    var filteredLogs: [LogEntry] {
        appState.logs.filter { entry in
            let levelMatch = filterLevel == nil || entry.level == filterLevel
            let searchMatch = searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
            return levelMatch && searchMatch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter logs...", text: $searchText)
                    .textFieldStyle(.plain)

                Divider().frame(height: 16)

                Picker("Level", selection: $filterLevel) {
                    Text("All").tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(LogEntry.Level?.some(level))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                        .help("Auto Scroll")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)

                Button(action: { appState.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear Logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredLogs) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: appState.logs.count) { _ in
                    if autoScroll, let last = filteredLogs.last {
                        withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .font(.system(size: 12, design: .monospaced))
        }
        .navigationTitle("Logs")
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTime)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Image(systemName: entry.level.icon)
                .foregroundStyle(entry.level.color)
                .frame(width: 12)
            Text(entry.message)
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
    }
}
