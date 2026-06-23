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

/// Per-node download-speed-test state (real throughput through the node, in Mbps).
enum SpeedResult: Equatable {
    case untested
    case testing
    case failed
    case mbps(Double)
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
    @Published var speed: [UUID: SpeedResult] = [:]

    /// One-shot guard so the main window is auto-opened only once at launch.
    var didShowInitialWindow = false

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

    // MARK: Persisted — strategy groups (balancer)
    /// User-defined load-balancing groups. When `selectedGroupId` points at one, the
    /// generated config is a balancer over the group's members instead of a single node.
    @Published var nodeGroups: [NodeGroup] = [] { didSet { persist() } }
    @Published var selectedGroupId: UUID? { didSet { persist() } }

    // MARK: Persisted — preferences
    @Published var appLanguage: AppLanguage = .system {
        didSet {
            LocalizationManager.shared.current = appLanguage
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            objectWillChange.send()
        }
    }

    /// User-selected UI appearance (follow system / light / dark). Persisted
    /// independently of `Key`/`persist()` (like `appLanguage`) so it never
    /// collides with the encoded-data keys.
    @Published var appTheme: AppTheme = .system {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme")
            objectWillChange.send()
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var autoUpdateTimer: Timer?

    // MARK: Connection resilience
    /// Re-establishes the connection after the Mac wakes from sleep.
    private let powerMonitor = PowerEventMonitor()
    /// Restores the system proxy if it is changed from outside the app.
    private let proxyGuard = SystemProxyGuard()
    /// Reconnects on network path changes (Wi-Fi switch, cable plug/unplug, etc.).
    private let networkMonitor = NetworkMonitor()
    /// One-shot guard so the monitor callbacks are wired only once.
    private var resilienceWired = false
    /// Timestamp of our own most recent system-proxy write. Used to ignore the
    /// proxy-guard notifications triggered by our own `networksetup` calls so the
    /// guard never fights itself in a loop.
    private var lastProxyWriteAt: Date?

    private init() {
        load()
        appLanguage = LocalizationManager.shared.current
        if let raw = UserDefaults.standard.string(forKey: "appTheme"), let t = AppTheme(rawValue: raw) {
            appTheme = t
        }
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
            startResilienceMonitors()
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
        stopResilienceMonitors()
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
            lastProxyWriteAt = Date()
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
            startResilienceMonitors()
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

    // MARK: - Connection resilience

    /// Start the wake / network / system-proxy monitors for the duration of a run.
    /// Idempotent — each monitor guards its own start. The proxy guard is only useful
    /// in system-proxy mode, so it is started conditionally.
    private func startResilienceMonitors() {
        wireResilienceIfNeeded()
        powerMonitor.start()
        networkMonitor.start()
        if proxyMode == .systemProxy { proxyGuard.start() }
    }

    /// Stop all resilience monitors (on user-initiated stop or supervisor give-up).
    private func stopResilienceMonitors() {
        powerMonitor.stop()
        networkMonitor.stop()
        proxyGuard.stop()
    }

    /// Wire the monitor callbacks exactly once. All handlers are no-ops unless a run is
    /// in progress, and each reconnect path is idempotent.
    private func wireResilienceIfNeeded() {
        guard !resilienceWired else { return }
        resilienceWired = true

        // After wake from sleep, sockets and the upstream connection are usually dead;
        // relaunch the core (which also re-applies proxy/TUN side effects).
        powerMonitor.onWake = { [weak self] in
            guard let self, isRunning else { return }
            addLog("Woke from sleep — reconnecting.", level: .info)
            restart()
        }

        // On a network path change, reconnect once connectivity is back. We ignore the
        // "became unreachable" edge: there is nothing to reconnect to until a usable
        // path returns, and the crash supervisor handles a core that dies meanwhile.
        networkMonitor.onPathChange = { [weak self] isReachable in
            guard let self, isRunning, isReachable else { return }
            addLog("Network changed — reconnecting.", level: .info)
            restart()
        }

        // If the system proxy is changed from outside the app (user edit, another VPN),
        // restore it — but ignore the notifications caused by our own writes.
        proxyGuard.onProxyChanged = { [weak self] in
            guard let self, isRunning, proxyMode == .systemProxy else { return }
            if let last = lastProxyWriteAt, Date().timeIntervalSince(last) < 2 { return }
            addLog("System proxy was changed externally — restoring.", level: .warning)
            lastProxyWriteAt = Date()
            SystemProxyManager.shared.enableSystemProxy(httpPort: buildOptions.httpPort,
                                                        socksPort: buildOptions.socksPort)
        }
    }

    /// Synchronous teardown safe to call from `applicationWillTerminate` (i.e. on any
    /// quit path: menu Quit, an Apple-Event `quit`, or a SIGTERM from `scripts/run.sh`).
    ///
    /// It is `nonisolated` and reads the persisted proxy mode from `UserDefaults`, so it
    /// touches no main-actor state and needs no `await`. The system-proxy reset runs
    /// synchronously (via `networksetup`) and therefore completes before the process
    /// exits, ensuring the Mac is never left routing into a dead core.
    nonisolated static func terminateCleanup() {
        XrayCoreManager.shared.stop()
        TrafficStatsManager.shared.stop()
        let mode = UserDefaults.standard.string(forKey: "proxyMode") ?? ProxyMode.systemProxy.rawValue
        switch mode {
        case ProxyMode.tun.rawValue:
            TunManager.shared.stop { _, _ in }
        case ProxyMode.manual.rawValue:
            break
        default:
            SystemProxyManager.shared.disableSystemProxy()
        }
    }

    /// Change proxy mode, reapplying side effects if currently running.
    func switchMode(_ mode: ProxyMode) {
        guard mode != proxyMode else { return }
        if isRunning {
            // Tear down the old mode's side effects, switch, then re-apply.
            switch proxyMode {
            case .systemProxy:
                lastProxyWriteAt = Date()
                SystemProxyManager.shared.disableSystemProxy()
            case .tun: TunManager.shared.stop { _, _ in }
            case .manual: break
            }
            proxyMode = mode
            applyProxySideEffectsOnStart()
            // The proxy guard is only relevant in system-proxy mode.
            if mode == .systemProxy { proxyGuard.start() } else { proxyGuard.stop() }
        } else {
            proxyMode = mode
        }
    }

    private func applyProxySideEffectsOnStart() {
        switch proxyMode {
        case .systemProxy:
            lastProxyWriteAt = Date()
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
        let data: Data
        if let group = selectedGroup, !groupMembers(group).isEmpty {
            // Balancer path: build a load-balancing config over the group's members.
            data = try ConfigBuilder.buildConfig(group: group,
                                                 nodes: groupMembers(group),
                                                 routing: routing,
                                                 options: buildOptions)
        } else {
            guard let node = selectedNode else { throw AppError.noSelection }
            data = try ConfigBuilder.buildConfig(node: node, routing: routing, options: buildOptions)
        }
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
        selectedGroupId = nil // node and group selection are mutually exclusive
        if isRunning { restart() }
    }

    func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        if selectedNodeId == id { selectedNodeId = nodes.first?.id }
    }

    /// Append a manually-created node and select it.
    func addNode(_ node: ProxyNode) {
        nodes.append(node)
        selectedNodeId = node.id
        selectedGroupId = nil // node and group selection are mutually exclusive
    }

    /// Replace an existing node (matched by id) with an edited copy.
    func updateNode(_ node: ProxyNode) {
        guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[idx] = node
        if isRunning && selectedNodeId == node.id { restart() }
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

    // MARK: - Node groups

    /// The currently selected strategy group, if any.
    var selectedGroup: NodeGroup? {
        selectedGroupId.flatMap { id in nodeGroups.first { $0.id == id } }
    }

    /// Resolves a group's member ids to live `ProxyNode`s, preserving member order and
    /// silently dropping ids that no longer exist.
    func groupMembers(_ group: NodeGroup) -> [ProxyNode] {
        group.memberIds.compactMap { mid in nodes.first { $0.id == mid } }
    }

    /// Whether the next launch should build a balancer config from `selectedGroup`
    /// rather than the single `selectedNode`. True only when a non-empty group is
    /// selected (and a raw profile is not in use).
    var isUsingGroup: Bool {
        guard !useCustomProfile, let group = selectedGroup else { return false }
        return !groupMembers(group).isEmpty
    }

    func addGroup(_ group: NodeGroup) {
        nodeGroups.append(group)
    }

    func updateGroup(_ group: NodeGroup) {
        guard let idx = nodeGroups.firstIndex(where: { $0.id == group.id }) else { return }
        nodeGroups[idx] = group
        if selectedGroupId == group.id, isRunning { restart() }
    }

    func removeGroup(_ id: UUID) {
        nodeGroups.removeAll { $0.id == id }
        if selectedGroupId == id { selectedGroupId = nil }
    }

    /// Select a strategy group as the active outbound source. Selecting a group is
    /// mutually exclusive with selecting a single node, so the node selection is
    /// cleared. Restarts the core if running.
    func selectGroup(_ id: UUID) {
        selectedGroupId = id
        selectedNodeId = nil
        if isRunning { restart() }
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
        guard node.supportedByXray else { latency[node.id] = .failed; return }
        latency[node.id] = .testing
        let xrayPath = XrayCoreManager.shared.xrayBinaryPath
        let options = buildOptions
        Task {
            // Real end-to-end probe: route a request through a throwaway instance of
            // this node, not a bare TCP handshake to its address.
            let ms = await NodeLatencyProbe.measure(node: node, xrayPath: xrayPath, options: options)
            await MainActor.run {
                self.latency[node.id] = ms.map { .ms($0) } ?? .failed
            }
        }
    }

    /// Probe every node's real latency, bounding how many throwaway `xray` instances
    /// run at once (each probe is a short-lived process).
    func testAllLatency() {
        let targets = nodes.filter(\.supportedByXray)
        for node in targets { latency[node.id] = .testing }
        for node in nodes where !node.supportedByXray { latency[node.id] = .failed }
        let xrayPath = XrayCoreManager.shared.xrayBinaryPath
        let options = buildOptions
        Task {
            let maxConcurrent = 5
            var pending = targets.makeIterator()
            await withTaskGroup(of: (UUID, Int?).self) { group in
                var inFlight = 0
                func startNext() -> Bool {
                    guard let node = pending.next() else { return false }
                    group.addTask {
                        (node.id, await NodeLatencyProbe.measure(node: node, xrayPath: xrayPath, options: options))
                    }
                    return true
                }
                for _ in 0 ..< maxConcurrent where startNext() { inFlight += 1 }
                while inFlight > 0, let (id, ms) = await group.next() {
                    inFlight -= 1
                    await MainActor.run { self.latency[id] = ms.map { .ms($0) } ?? .failed }
                    if startNext() { inFlight += 1 }
                }
            }
        }
    }

    /// Real download-speed test for a single node: spins up a throwaway instance and
    /// downloads through it, reporting Mbps. On-demand only (no batch) since it
    /// consumes real bandwidth.
    func testSpeed(_ node: ProxyNode) {
        guard node.supportedByXray else { speed[node.id] = .failed; return }
        speed[node.id] = .testing
        let xrayPath = XrayCoreManager.shared.xrayBinaryPath
        let options = buildOptions
        Task {
            let mbps = await NodeLatencyProbe.measureSpeed(node: node, xrayPath: xrayPath, options: options)
            await MainActor.run {
                self.speed[node.id] = mbps.map { .mbps($0) } ?? .failed
            }
        }
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
        static let nodeGroups = "nodeGroups.v1"
        static let selectedGroupId = "selectedGroupId"
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
        d.set(try? enc.encode(nodeGroups), forKey: Key.nodeGroups)
        d.set(selectedGroupId?.uuidString, forKey: Key.selectedGroupId)
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
        if let data = d.data(forKey: Key.nodeGroups), let v = try? dec.decode([NodeGroup].self, from: data) { nodeGroups = v }
        if let raw = d.string(forKey: Key.selectedGroupId) { selectedGroupId = UUID(uuidString: raw) }
        if let raw = d.string(forKey: Key.proxyMode), let m = ProxyMode(rawValue: raw) { proxyMode = m }
        if let raw = d.string(forKey: Key.selectedNodeId) { selectedNodeId = UUID(uuidString: raw) }
        if let raw = d.string(forKey: Key.selectedProfileId) { selectedProfileId = UUID(uuidString: raw) }
        useCustomProfile = d.bool(forKey: Key.useCustomProfile)

        // Migrate legacy single binary/port settings already handled by managers.
    }
}
