import Foundation
import Combine

enum ProxyMode: String, CaseIterable, Codable {
    case systemProxy = "System Proxy"
    case tun = "TUN"
    case manual = "Manual"

    var icon: String {
        switch self {
        case .systemProxy: return "network"
        case .tun: return "square.stack.3d.up"
        case .manual: return "hand.point.up.left"
        }
    }

    var description: String {
        switch self {
        case .systemProxy: return "Route via HTTP/SOCKS system proxy"
        case .tun: return "Route all traffic via TUN interface"
        case .manual: return "No proxy configuration"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRunning = false
    @Published var proxyMode: ProxyMode = .systemProxy {
        didSet {
            UserDefaults.standard.set(proxyMode.rawValue, forKey: "proxyMode")
        }
    }
    @Published var selectedProfileId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedProfileId?.uuidString, forKey: "selectedProfileId")
        }
    }
    @Published var profiles: [Profile] = [] {
        didSet { saveProfiles() }
    }
    @Published var logs: [LogEntry] = []
    @Published var errorMessage: String?
    @Published var showMainWindow = false

    private init() {
        loadSettings()
        loadProfiles()
    }

    var selectedProfile: Profile? {
        if let id = selectedProfileId, let p = profiles.first(where: { $0.id == id }) { return p }
        return profiles.first
    }

    func addLog(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(message: message, level: level)
        logs.append(entry)
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    func clearLogs() { logs.removeAll() }

    private func loadSettings() {
        if let raw = UserDefaults.standard.string(forKey: "proxyMode"),
           let mode = ProxyMode(rawValue: raw) { proxyMode = mode }
        if let raw = UserDefaults.standard.string(forKey: "selectedProfileId"),
           let id = UUID(uuidString: raw) { selectedProfileId = id }
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "profiles"),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        profiles = decoded
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: "profiles")
    }
}
