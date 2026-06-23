import AppKit
import Combine
import Foundation

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

    /// Localization key for the human description.
    var descriptionKey: String {
        switch self {
        case .systemProxy: return "Route via HTTP/SOCKS system proxy"
        case .tun: return "Route all traffic via TUN interface"
        case .manual: return "No proxy configuration"
        }
    }
}

/// Per-node latency-test state.
enum LatencyResult: Equatable {
    case untested
    case testing
    case failed
    case ms(Int)
}

/// The single source of truth for the whole app: persisted configuration (nodes,
/// subscriptions, routing, build options) plus live runtime state (running flag, logs,
/// traffic, latency). All proxy orchestration (start/stop, config generation+validation,
/// system-proxy/TUN side effects, traffic polling) is centralized here so the menu bar
/// and the main window share one code path.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Runtime
    @Published var isRunning = false
    @Published var isBusy = false // a start/stop transition is in flight
    @Published var logs: [LogEntry] = []
    @Published var errorMessage: String?
    @Published var infoMessage: String? // non-error toast (e.g. "Imported 5 nodes")
    @Published var traffic: TrafficStatsManager.Snapshot = .zero
    @Published var latency: [UUID: LatencyResult] = [:]

    // MARK: Persisted — selection & mode
    @Published var proxyMode: ProxyMode = .systemProxy { didSet { persist() } }
    @Published var selectedNodeId: UUID? { didSet { persist() } }
    @Published var selectedProfileId: UUID? { didSet { persist() } }
    /// When true, launch the selected raw Profile JSON instead of generating from a node.
    @Published var useCustomProfile = false { didSet { persist() } }

    // MARK: Persisted — data
    @Published var nodes: [ProxyNode] = [] { didSet { persist() } }
    @Published var subscriptions: [Subscription] = [] { didSet { persist() } }
    @Published var profiles: [Profile] = [] { didSet { persist() } }
    @Published var routing: RoutingSettings = .default { didSet { persist() } }
    @Published var buildOptions: ConfigBuildOptions = .default { didSet { persist() } }

    // MARK: Persisted — preferences
    @Published var appLanguage: AppLanguage = .system {
        didSet {
            LocalizationManager.shared.current = appLanguage
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            objectWillChange.send()
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var autoUpdateTimer: Timer?

    private init() {
        load()
        appLanguage = LocalizationManager.shared.current
        scheduleAutoUpdate()
    }

    // MARK: - Selection helpers

    var selectedNode: ProxyNode? {
        if let id = selectedNodeId, let n = nodes.first(where: { $0.id == id }) { return n }
        return nil
    }

    var selectedProfile: Profile? {
        if let id = selectedProfileId, let p = profiles.first(where: { $0.id == id }) { return p }
        return profiles.first
    }

    func nodes(in subscriptionId: UUID?) -> [ProxyNode] {
        nodes.filter { $0.subscriptionId == subscriptionId }
    }

    /// Nodes that do not belong to any subscription (manually added / imported).
    var manualNodes: [ProxyNode] { nodes.filter { $0.subscriptionId == nil } }

    // MARK: - Logs

    func addLog(_ message: String, level: LogEntry.Level = .info) {
        logs.append(LogEntry(message: message, level: level))
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - Lifecycle (start / stop)

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        do {
            let path = try prepareConfig()
            try XrayCoreManager.shared.start(configPath: path)
            applyProxySideEffectsOnStart()
            startTrafficPolling()
        } catch {
            errorMessage = error.localizedDescription
            // Roll back anything partial.
            XrayCoreManager.shared.stop()
        }
        isBusy = false
    }

    func stop() {
        guard isRunning || isBusy else { return }
        isBusy = true
        teardownProxySideEffects()
        XrayCoreManager.shared.stop()
        isBusy = false
    }

    /// Disable the active mode's side effects (system proxy / TUN) and stop traffic
    /// polling. Shared by `stop()` and the crash supervisor's give-up path so the
    /// machine is never left routing into a dead core.
    func teardownProxySideEffects() {
        TrafficStatsManager.shared.stop()
        traffic = .zero
        switch proxyMode {
        case .systemProxy:
            SystemProxyManager.shared.disableSystemProxy()
        case .tun:
            TunManager.shared.stop { [weak self] ok, msg in
                Task { @MainActor in if !ok { self?.addLog("TUN stop: \(msg)", level: .warning) } }
            }
        case .manual:
            break
        }
    }

    /// Re-run the full launch path after the core crashed and the supervisor decided
    /// to restart it. Re-applies proxy/TUN side effects and traffic polling against the
    /// freshly launched core (all idempotent), keeping process + side effects in sync.
    func handleCoreCrashRestart() {
        guard !isRunning else { return }
        do {
            let path = try prepareConfig()
            try XrayCoreManager.shared.start(configPath: path)
            applyProxySideEffectsOnStart()
            startTrafficPolling()
        } catch {
            errorMessage = error.localizedDescription
            XrayCoreManager.shared.stop()
        }
    }

    func restart() {
        guard isRunning else { return }
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.start() }
    }

    /// Change proxy mode, reapplying side effects if currently running.
    func switchMode(_ mode: ProxyMode) {
        guard mode != proxyMode else { return }
        if isRunning {
            // Tear down the old mode's side effects, switch, then re-apply.
            switch proxyMode {
            case .systemProxy: SystemProxyManager.shared.disableSystemProxy()
            case .tun: TunManager.shared.stop { _, _ in }
            case .manual: break
            }
            proxyMode = mode
            applyProxySideEffectsOnStart()
        } else {
            proxyMode = mode
        }
    }

    private func applyProxySideEffectsOnStart() {
        switch proxyMode {
        case .systemProxy:
            SystemProxyManager.shared.enableSystemProxy(httpPort: buildOptions.httpPort,
                                                        socksPort: buildOptions.socksPort)
        case .tun:
            guard let node = selectedNode else {
                addLog("TUN mode requires a selected node.", level: .warning); return
            }
            TunManager.shared.start(node: node,
                                    socksPort: buildOptions.socksPort,
                                    dnsServers: routing.remoteDNS) { [weak self] ok, msg in
                Task { @MainActor in self?.addLog("TUN: \(msg)", level: ok ? .info : .error) }
            }
        case .manual:
            break
        }
    }

    private func startTrafficPolling() {
        guard buildOptions.enableStatsAPI, buildOptions.apiPort > 0 else { return }
        let xrayPath = XrayCoreManager.shared.xrayBinaryPath
        guard !xrayPath.isEmpty else { return }
        TrafficStatsManager.shared.start(xrayPath: xrayPath, apiPort: buildOptions.apiPort) { [weak self] snap in
            Task { @MainActor in self?.traffic = snap }
        }
    }

    // MARK: - Config generation & validation

    /// Directory holding generated/runtime config files.
    private var configDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("XrayGUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Produce the config file path to launch: either a raw Profile or a freshly
    /// generated config from the selected node (validated with `xray -test`).
    func prepareConfig() throws -> String {
        if useCustomProfile, let profile = selectedProfile {
            guard profile.exists else { throw AppError.configMissing }
            try validateConfig(path: profile.configPath)
            return profile.configPath
        }
        guard let node = selectedNode else { throw AppError.noSelection }
        let data = try ConfigBuilder.buildConfig(node: node, routing: routing, options: buildOptions)
        let url = configDirectory.appendingPathComponent("current-config.json")
        try data.write(to: url)
        try validateConfig(path: url.path)
        return url.path
    }

    /// Run `xray run -test -c <path>` and throw with stderr on failure.
    private func validateConfig(path: String) throws {
        let xray = XrayCoreManager.shared.xrayBinaryPath
        guard !xray.isEmpty, FileManager.default.fileExists(atPath: xray) else {
            throw XrayError.binaryNotFound
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: xray)
        p.arguments = ["run", "-test", "-c", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { throw AppError.validationFailed(error.localizedDescription) }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = out.components(separatedBy: "\n").suffix(6).joined(separator: "\n")
            throw AppError.validationFailed(lines.isEmpty ? "Config test failed." : lines)
        }
    }

    // MARK: - Nodes & import

    func selectNode(_ id: UUID) {
        selectedNodeId = id
        if isRunning { restart() }
    }

    func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        if selectedNodeId == id { selectedNodeId = nodes.first?.id }
    }

    /// Parse arbitrary text (single link, multi-line, or base64 subscription blob) and
    /// append the resulting manual nodes. Returns the number imported.
    @discardableResult
    func importLinks(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let parsed = ShareLinkParser.parseSubscription(trimmed)
        guard !parsed.isEmpty else {
            errorMessage = "No valid share links found".localized
            return 0
        }
        nodes.append(contentsOf: parsed)
        if selectedNodeId == nil { selectedNodeId = parsed.first?.id }
        infoMessage = "Imported %d node(s)".localized(parsed.count)
        return parsed.count
    }

    func importFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        _ = importLinks(text)
    }

    // MARK: - Subscriptions

    func addSubscription(name: String, url: String) {
        var sub = Subscription(name: name.isEmpty ? url : name, url: url)
        sub.autoUpdateHours = 0
        subscriptions.append(sub)
        Task { await updateSubscription(sub.id) }
    }

    func removeSubscription(_ id: UUID) {
        nodes.removeAll { $0.subscriptionId == id }
        subscriptions.removeAll { $0.id == id }
        if selectedNode == nil { selectedNodeId = nodes.first?.id }
    }

    func updateSubscription(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let sub = subscriptions[idx]
        do {
            let (newNodes, info) = try await SubscriptionManager.shared.fetch(sub)
            let previousSelectedKey = selectedNode?.dedupKey
            nodes.removeAll { $0.subscriptionId == id }
            nodes.append(contentsOf: newNodes)

            subscriptions[idx].lastUpdated = Date()
            subscriptions[idx].nodeCount = newNodes.count
            subscriptions[idx].usedTraffic = (info?.upload ?? 0) + (info?.download ?? 0)
            subscriptions[idx].totalTraffic = info?.total
            subscriptions[idx].expireDate = info?.expire

            // Restore selection if the same server still exists.
            if let key = previousSelectedKey, let match = newNodes.first(where: { $0.dedupKey == key }) {
                selectedNodeId = match.id
            } else if selectedNode == nil {
                selectedNodeId = nodes.first?.id
            }
            infoMessage = "Imported %d node(s)".localized(newNodes.count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAllSubscriptions() async {
        for sub in subscriptions { await updateSubscription(sub.id) }
    }

    private func scheduleAutoUpdate() {
        autoUpdateTimer?.invalidate()
        // Check hourly whether any subscription is due.
        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                for sub in self.subscriptions where sub.isDue(now: now) {
                    await self.updateSubscription(sub.id)
                }
            }
        }
    }

    // MARK: - Latency

    func testLatency(_ node: ProxyNode) {
        latency[node.id] = .testing
        Task {
            let ms = await LatencyTester.tcpPing(host: node.address, port: node.port)
            await MainActor.run {
                self.latency[node.id] = ms.map { .ms($0) } ?? .failed
            }
        }
    }

    func testAllLatency() {
        for node in nodes { testLatency(node) }
    }

    func sortNodesByLatency() {
        nodes.sort { a, b in
            let la = latencyValue(a.id), lb = latencyValue(b.id)
            return la < lb
        }
    }

    private func latencyValue(_ id: UUID) -> Int {
        switch latency[id] {
        case .ms(let v): return v
        default: return Int.max
        }
    }

    // MARK: - Errors

    enum AppError: LocalizedError {
        case noSelection
        case configMissing
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSelection: return "No node selected".localized
            case .configMissing: return "Config file not found.".localized
            case .validationFailed(let detail): return "Invalid config:\n\(detail)"
            }
        }
    }

    // MARK: - Persistence

    private enum Key {
        static let nodes = "nodes.v2"
        static let subscriptions = "subscriptions.v2"
        static let profiles = "profiles"
        static let routing = "routingSettings.v2"
        static let buildOptions = "buildOptions.v2"
        static let proxyMode = "proxyMode"
        static let selectedNodeId = "selectedNodeId"
        static let selectedProfileId = "selectedProfileId"
        static let useCustomProfile = "useCustomProfile"
    }

    private var isLoading = false

    private func persist() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        let enc = JSONEncoder()
        d.set(try? enc.encode(nodes), forKey: Key.nodes)
        d.set(try? enc.encode(subscriptions), forKey: Key.subscriptions)
        d.set(try? enc.encode(profiles), forKey: Key.profiles)
        d.set(try? enc.encode(routing), forKey: Key.routing)
        d.set(try? enc.encode(buildOptions), forKey: Key.buildOptions)
        d.set(proxyMode.rawValue, forKey: Key.proxyMode)
        d.set(selectedNodeId?.uuidString, forKey: Key.selectedNodeId)
        d.set(selectedProfileId?.uuidString, forKey: Key.selectedProfileId)
        d.set(useCustomProfile, forKey: Key.useCustomProfile)
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let d = UserDefaults.standard
        let dec = JSONDecoder()
        if let data = d.data(forKey: Key.nodes), let v = try? dec.decode([ProxyNode].self, from: data) { nodes = v }
        if let data = d.data(forKey: Key.subscriptions), let v = try? dec.decode([Subscription].self, from: data) { subscriptions = v }
        if let data = d.data(forKey: Key.profiles), let v = try? dec.decode([Profile].self, from: data) { profiles = v }
        if let data = d.data(forKey: Key.routing), let v = try? dec.decode(RoutingSettings.self, from: data) { routing = v }
        if let data = d.data(forKey: Key.buildOptions), let v = try? dec.decode(ConfigBuildOptions.self, from: data) { buildOptions = v }
        if let raw = d.string(forKey: Key.proxyMode), let m = ProxyMode(rawValue: raw) { proxyMode = m }
        if let raw = d.string(forKey: Key.selectedNodeId) { selectedNodeId = UUID(uuidString: raw) }
        if let raw = d.string(forKey: Key.selectedProfileId) { selectedProfileId = UUID(uuidString: raw) }
        useCustomProfile = d.bool(forKey: Key.useCustomProfile)

        // Migrate legacy single binary/port settings already handled by managers.
    }
}
