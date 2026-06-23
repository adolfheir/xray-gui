import Foundation

/// High-level routing presets. Each maps to a concrete Xray `routing.rules` array
/// produced by `ConfigBuilder`.
enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    /// Everything goes through the proxy (except optionally private/LAN).
    case global
    /// Mainland-China IPs/domains go direct; everything else proxied (the common default).
    case bypassMainland
    /// Everything direct except a user-defined proxy list.
    case directMainlandProxyRest = "directRest"
    /// Everything direct (proxy effectively off, useful for testing).
    case direct
    /// Fully custom rules authored by the user.
    case custom

    var id: String { rawValue }

    var displayKey: String {
        switch self {
        case .global: return "routing.mode.global"
        case .bypassMainland: return "routing.mode.bypassMainland"
        case .directMainlandProxyRest: return "routing.mode.directRest"
        case .direct: return "routing.mode.direct"
        case .custom: return "routing.mode.custom"
        }
    }
}

/// The action a routing rule applies.
enum RuleOutbound: String, Codable, CaseIterable, Identifiable {
    case proxy
    case direct
    case block
    var id: String { rawValue }
}

/// A single user-authored routing rule. Domains and IPs accept Xray's native
/// matchers ("geosite:cn", "geoip:cn", "domain:example.com", "1.2.3.0/24", "ext:...").
struct RoutingRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var remark: String = ""
    var outbound: RuleOutbound = .direct
    /// Raw domain matchers, one per entry.
    var domains: [String] = []
    /// Raw IP matchers, one per entry.
    var ips: [String] = []
    /// Destination ports, e.g. "443" or "1000-2000".
    var port: String = ""
    /// Network: "", "tcp", "udp", or "tcp,udp".
    var network: String = ""

    init(id: UUID = UUID()) { self.id = id }
}

/// All routing-related configuration. Persisted in `AppState`.
struct RoutingSettings: Codable, Hashable {
    var mode: RoutingMode = .bypassMainland
    /// Route LAN/private network traffic directly (bypass proxy).
    var bypassLAN: Bool = true
    /// Block common ad/tracker domains (geosite:category-ads-all).
    var blockAds: Bool = false
    /// Domain strategy for the routing engine: "AsIs", "IPIfNonMatch", "IPOnDemand".
    var domainStrategy: String = "IPIfNonMatch"
    /// User custom rules, applied before preset rules in `.custom` mode and
    /// appended in other modes.
    var customRules: [RoutingRule] = []

    // MARK: DNS
    /// DNS servers used by Xray for proxied lookups (e.g. "1.1.1.1", "8.8.8.8").
    var remoteDNS: [String] = ["1.1.1.1", "8.8.8.8"]
    /// DNS servers used for direct/domestic lookups (e.g. "223.5.5.5", "119.29.29.29").
    var directDNS: [String] = ["223.5.5.5", "119.29.29.29"]
    /// Enable Xray's built-in DNS module in the generated config.
    var enableDNS: Bool = true

    static let `default` = RoutingSettings()
}
