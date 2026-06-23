import Foundation

/// The wire-level protocol of a proxy node.
///
/// Only a subset is natively supported by Xray-core. Nodes whose protocol is not
/// supported are still parsed and stored (so the user does not silently lose them)
/// but `protocolType.isSupportedByXray` returns false and `ConfigBuilder` refuses
/// to generate an outbound for them.
enum ProxyProtocol: String, Codable, CaseIterable, Hashable {
    case vmess
    case vless
    case trojan
    case shadowsocks // ss://  and Shadowsocks-2022
    case socks
    case http
    case ssr // ShadowsocksR — parsed but NOT supported by Xray-core
    case hysteria2 // hy2://  — parsed but NOT supported by Xray-core
    case tuic // tuic:// — parsed but NOT supported by Xray-core
    case wireguard

    /// Whether Xray-core can build an outbound for this protocol.
    var isSupportedByXray: Bool {
        switch self {
        case .vmess, .vless, .trojan, .shadowsocks, .socks, .http, .wireguard:
            return true
        case .ssr, .hysteria2, .tuic:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .vmess: return "VMess"
        case .vless: return "VLESS"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        case .socks: return "SOCKS"
        case .http: return "HTTP"
        case .ssr: return "ShadowsocksR"
        case .hysteria2: return "Hysteria2"
        case .tuic: return "TUIC"
        case .wireguard: return "WireGuard"
        }
    }
}

/// A normalized, protocol-agnostic representation of a single proxy server.
///
/// This is the **central contract** shared by the whole app:
/// - `ShareLinkParser` produces `ProxyNode` values from vmess/vless/trojan/ss/ssr/… URIs.
/// - `ConfigBuilder` consumes a `ProxyNode` (plus `RoutingSettings`) to emit a complete Xray JSON config.
/// - `SubscriptionManager` stores arrays of these.
/// - `LatencyTester` reads `address`/`port` and writes back latency.
///
/// Optional fields are populated only when relevant to the node's protocol/transport.
/// Parsers MUST NOT invent values; leave fields nil when the source link omits them so
/// `ConfigBuilder` can apply Xray's own defaults.
struct ProxyNode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    // MARK: Identity
    /// Human-readable remark (vmess "ps", URI fragment, etc.). Never empty after parsing.
    var name: String
    var protocolType: ProxyProtocol
    var address: String
    var port: Int

    // MARK: Credentials
    /// VMess / VLESS UUID.
    var userId: String?
    /// VMess alterId (legacy). nil or 0 for AEAD.
    var alterId: Int?
    /// VMess security / encryption ("auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero").
    /// For Shadowsocks this holds the cipher method (see also `method`).
    var encryption: String?
    /// Trojan / Shadowsocks / SSR / Hysteria2 / TUIC password.
    var password: String?
    /// VLESS flow control, e.g. "xtls-rprx-vision".
    var flow: String?

    // MARK: Shadowsocks / SSR
    /// Shadowsocks / SSR cipher method (e.g. "aes-256-gcm", "2022-blake3-aes-256-gcm").
    var method: String?
    var ssrProtocol: String?
    var ssrProtocolParam: String?
    var ssrObfs: String?
    var ssrObfsParam: String?

    // MARK: Transport (streamSettings.network)
    /// "tcp", "ws", "grpc", "h2"/"http", "quic", "kcp"/"mkcp", "httpupgrade", "xhttp"/"splithttp".
    var network: String = "tcp"
    /// "none", "tls", "reality", "xtls".
    var security: String = "none"

    // MARK: TLS / Reality
    var sni: String?
    /// Comma-joined ALPN list, e.g. "h2,http/1.1".
    var alpn: String?
    /// uTLS fingerprint, e.g. "chrome", "firefox", "safari", "randomized".
    var fingerprint: String?
    var allowInsecure: Bool = false
    /// REALITY public key.
    var publicKey: String?
    /// REALITY shortId.
    var shortId: String?
    /// REALITY spiderX path.
    var spiderX: String?

    // MARK: ws / http / httpupgrade / xhttp
    var path: String?
    /// Host header (ws/http/httpupgrade) — may be comma-separated for http/2.
    var host: String?
    /// TCP header obfuscation type ("none" or "http"); also mKCP header type.
    var headerType: String?

    // MARK: gRPC
    var serviceName: String?
    /// "gun" or "multi".
    var grpcMode: String?

    // MARK: QUIC / mKCP
    var quicSecurity: String?
    var quicKey: String?
    /// mKCP seed.
    var seed: String?

    // MARK: Metadata
    /// Subscription this node came from; nil for manually added nodes.
    var subscriptionId: UUID?
    /// Original share link, retained for re-export / debugging.
    var rawLink: String?

    init(
        id: UUID = UUID(),
        name: String,
        protocolType: ProxyProtocol,
        address: String,
        port: Int
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.address = address
        self.port = port
    }
}

extension ProxyNode {
    /// A stable identity tuple used for de-duplication across subscription refreshes.
    /// Two nodes that differ only by `id`/`name`/`subscriptionId` are considered the same server.
    var dedupKey: String {
        [
            protocolType.rawValue, address, "\(port)",
            userId ?? "", password ?? "", network, security,
            path ?? "", host ?? "", serviceName ?? "", flow ?? ""
        ].joined(separator: "|")
    }

    var supportedByXray: Bool { protocolType.isSupportedByXray }

    /// A compact one-line summary for list rows / tooltips.
    var summary: String {
        "\(protocolType.displayName) · \(address):\(port)"
            + (network != "tcp" ? " · \(network)" : "")
            + (security != "none" ? " · \(security)" : "")
    }
}
