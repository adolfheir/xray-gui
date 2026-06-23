import Foundation

/// Parameters for bringing up TUN mode, passed from the app to the privileged helper
/// as a JSON blob via `XrayHelperProtocol.startTUN(configJSON:)`.
///
/// The helper launches `tun2socksPath` (a tun2socks-compatible binary such as
/// xjasonlyu/tun2socks or sing-box's tun) which opens/creates the utun device and
/// forwards all of its traffic to the local SOCKS inbound exposed by Xray.
struct TunStartConfig: Codable, Equatable {
    /// Absolute path to the tun2socks-compatible binary.
    var tun2socksPath: String
    /// utun device name, e.g. "utun123".
    var tunName: String
    /// Tun interface IPv4 address, e.g. "198.18.0.1".
    var tunAddress: String
    /// Tun interface netmask, e.g. "255.255.0.0".
    var tunMask: String
    /// Local SOCKS inbound host (usually 127.0.0.1).
    var socksHost: String
    /// Local SOCKS inbound port that Xray listens on.
    var socksPort: Int
    /// DNS servers to set system-wide while TUN is active.
    var dnsServers: [String]
    /// Resolved proxy server IPs that MUST stay routed via the original gateway to
    /// prevent the proxy's own connection from looping back into the tun.
    var serverIPs: [String]
    /// tun2socks log level ("info", "warning", "error", "silent").
    var logLevel: String

    init(
        tun2socksPath: String,
        tunName: String = "utun123",
        tunAddress: String = "198.18.0.1",
        tunMask: String = "255.255.0.0",
        socksHost: String = "127.0.0.1",
        socksPort: Int,
        dnsServers: [String] = ["1.1.1.1"],
        serverIPs: [String] = [],
        logLevel: String = "warning"
    ) {
        self.tun2socksPath = tun2socksPath
        self.tunName = tunName
        self.tunAddress = tunAddress
        self.tunMask = tunMask
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.dnsServers = dnsServers
        self.serverIPs = serverIPs
        self.logLevel = logLevel
    }
}
