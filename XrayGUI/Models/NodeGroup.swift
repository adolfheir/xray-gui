import Foundation

/// Load-balancing strategy for an Xray routing balancer. Each value maps directly to
/// the `routing.balancers[].strategy.type` accepted by Xray-core.
enum BalancerStrategy: String, Codable, CaseIterable, Identifiable {
    /// Round/random pick across the group's members; no health probing required.
    case random
    /// Observatory-driven selection of the member with the lowest measured latency.
    case leastPing
    /// Observatory-driven selection of the member with the lowest measured load.
    case leastLoad

    var id: String { rawValue }

    /// Localization key (English text doubles as the key) for the human-readable name.
    var displayKey: String {
        switch self {
        case .random: return "Random"
        case .leastPing: return "Least Ping"
        case .leastLoad: return "Least Load"
        }
    }

    /// `leastPing` / `leastLoad` need an `observatory` block to perform the health
    /// probes that drive their selection; `random` does not.
    var needsObservatory: Bool { self != .random }
}

/// A user-defined group of proxy nodes that Xray load-balances across via a routing
/// balancer. `ConfigBuilder` turns a selected group into one outbound per member
/// (`proxy-0`, `proxy-1`, …), a `routing.balancers` entry, and — when the strategy
/// requires it — an `observatory` health-probe block. Persisted in `AppState`.
struct NodeGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// User-facing name of the group.
    var name: String
    /// References to member `ProxyNode.id`s. Order defines the generated outbound tag
    /// order (`proxy-0`, `proxy-1`, …).
    var memberIds: [UUID] = []
    /// Load-balancing strategy applied by the generated balancer.
    var strategy: BalancerStrategy = .leastPing
    /// Observatory probe URL (used only when `strategy.needsObservatory`).
    var probeURL: String = "https://www.gstatic.com/generate_204"
    /// Observatory probe interval, in Xray duration syntax (e.g. "5m").
    var probeInterval: String = "5m"

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
