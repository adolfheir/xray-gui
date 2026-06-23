import Foundation

/// A remote subscription that yields a list of `ProxyNode`s.
///
/// Subscription content is a Base64 (or raw) blob of newline-separated share links.
/// `SubscriptionManager` fetches the URL, decodes, parses each line with `ShareLinkParser`,
/// and replaces the subscription's nodes (preserving stable IDs via `ProxyNode.dedupKey`).
struct Subscription: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    /// Last successful refresh.
    var lastUpdated: Date?
    /// Auto-update period in hours; 0 disables auto-update.
    var autoUpdateHours: Int = 0
    /// Custom User-Agent sent when fetching; nil uses the app default.
    var userAgent: String?
    /// Number of nodes captured at the last refresh (for display before nodes load).
    var nodeCount: Int = 0
    /// Bytes used / total parsed from the `subscription-userinfo` response header, if present.
    var usedTraffic: Int64?
    var totalTraffic: Int64?
    var expireDate: Date?

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

extension Subscription {
    var isAutoUpdateEnabled: Bool { autoUpdateHours > 0 }

    /// Whether enough time has elapsed since `lastUpdated` to trigger an auto-refresh.
    func isDue(now: Date) -> Bool {
        guard isAutoUpdateEnabled else { return false }
        guard let last = lastUpdated else { return true }
        return now.timeIntervalSince(last) >= Double(autoUpdateHours) * 3600
    }
}
