import Foundation

/// Everything `ConfigBuilder` needs (besides the selected `ProxyNode` and
/// `RoutingSettings`) to emit a complete Xray config: local inbounds, the stats/api
/// endpoint, sniffing, mux, and log level.
///
/// This is a stable contract: `AppState` populates it from persisted settings and
/// passes it to `ConfigBuilder.buildConfig(node:routing:options:)`.
struct ConfigBuildOptions: Codable, Hashable {
    // MARK: Local inbounds
    /// SOCKS inbound port (0 disables the SOCKS inbound).
    var socksPort: Int = 10808
    /// HTTP inbound port (0 disables the HTTP inbound).
    var httpPort: Int = 10809
    /// Inbound listen address. "127.0.0.1" for local-only, "0.0.0.0" to share on LAN.
    var listenAddress: String = "127.0.0.1"
    /// Allow UDP over SOCKS and enable UDP relay.
    var enableUDP: Bool = true
    /// Enable destination sniffing (needed for domain-based routing under TUN/SOCKS).
    var enableSniffing: Bool = true

    // MARK: Stats / API
    /// Expose the gRPC API + stats so the app can poll traffic counters.
    var enableStatsAPI: Bool = true
    /// Port for the local API inbound (dokodemo-door → api).
    var apiPort: Int = 10812

    // MARK: Outbound tuning
    /// Enable mux.cool on the proxy outbound.
    var enableMux: Bool = false
    var muxConcurrency: Int = 8

    // MARK: Logging
    /// Xray log level: "debug", "info", "warning", "error", "none".
    var logLevel: String = "warning"

    static let `default` = ConfigBuildOptions()
}
