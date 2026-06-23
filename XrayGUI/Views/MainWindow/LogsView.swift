import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var filterLevel: LogEntry.Level? = nil
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var newestFirst = false

    var filteredLogs: [LogEntry] {
        appState.logs.filter { entry in
            let levelMatch = filterLevel == nil || entry.level == filterLevel
            let searchMatch = searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
            return levelMatch && searchMatch
        }
    }

    /// The rows in display order. `appState.logs` is oldest-first; flip it when the
    /// user wants the newest entries pinned to the top.
    var displayedLogs: [LogEntry] {
        newestFirst ? filteredLogs.reversed() : filteredLogs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter logs...".localized, text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear".localized)
                }

                Divider().frame(height: 16)

                Picker("Level".localized, selection: $filterLevel) {
                    Text("All".localized).tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(LogEntry.Level?.some(level))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Button {
                    newestFirst.toggle()
                } label: {
                    Image(systemName: newestFirst ? "arrow.up" : "arrow.down")
                }
                .help((newestFirst ? "Newest First" : "Oldest First").localized)

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Auto Scroll".localized)

                Button {
                    appState.clearLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear Logs".localized)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayedLogs) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: appState.logs.count) { _ in
                    scrollToNewest(proxy)
                }
                .onChange(of: newestFirst) { _ in
                    scrollToNewest(proxy)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .font(.system(size: 12, design: .monospaced))
        }
        .navigationTitle("Logs".localized)
    }

    /// Keeps the newest entry in view when auto-scroll is on. The newest log is
    /// always `appState.logs.last`; it sits at the top in newest-first mode and at
    /// the bottom otherwise, so the anchor flips with the order.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard autoScroll, let newest = appState.logs.last else { return }
        withAnimation(.none) {
            proxy.scrollTo(newest.id, anchor: newestFirst ? .top : .bottom)
        }
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
