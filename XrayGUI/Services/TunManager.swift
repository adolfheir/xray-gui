import Foundation

/// App-side TUN orchestration. Resolves the active node's server IP(s) (so the helper
/// can pin them to the original gateway and avoid a routing loop), assembles a
/// `TunStartConfig`, and drives the privileged helper.
///
/// Requires:
///  - the privileged helper installed (`HelperClient.isHelperInstalled`), and
///  - a tun2socks-compatible binary path (configured in Settings),
/// because Xray-core itself does not own a tun device.
final class TunManager {
    static let shared = TunManager()
    private init() {}

    private(set) var isActive = false

    /// UserDefaults-backed path to the tun2socks binary.
    var tun2socksPath: String {
        get { UserDefaults.standard.string(forKey: "tun2socksPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tun2socksPath") }
    }

    enum TunError: LocalizedError {
        case helperMissing
        case tun2socksMissing
        case noServer

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "Privileged helper is not installed. Install it in Settings → TUN Mode."
            case .tun2socksMissing:
                return "tun2socks binary not set or not found. Set its path in Settings → TUN Mode."
            case .noServer:
                return "Could not resolve the node's server address."
            }
        }
    }

    /// Bring up TUN for the given node, bridging the utun to the local SOCKS inbound.
    func start(node: ProxyNode,
               socksPort: Int,
               dnsServers: [String],
               completion: @escaping (Bool, String) -> Void) {
        guard HelperClient.shared.isHelperInstalled else {
            completion(false, TunError.helperMissing.localizedDescription); return
        }
        let path = tun2socksPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            completion(false, TunError.tun2socksMissing.localizedDescription); return
        }

        // Resolve server IPs off the main thread.
        DispatchQueue.global().async {
            let ips = Self.resolveIPs(host: node.address)
            guard !ips.isEmpty else {
                DispatchQueue.main.async { completion(false, TunError.noServer.localizedDescription) }
                return
            }
            let config = TunStartConfig(
                tun2socksPath: path,
                socksPort: socksPort,
                dnsServers: dnsServers.isEmpty ? ["1.1.1.1"] : dnsServers,
                serverIPs: ips
            )
            HelperClient.shared.startTUN(config) { ok, msg in
                DispatchQueue.main.async {
                    self.isActive = ok
                    completion(ok, msg)
                }
            }
        }
    }

    func stop(completion: @escaping (Bool, String) -> Void) {
        HelperClient.shared.stopTUN { ok, msg in
            DispatchQueue.main.async {
                self.isActive = false
                completion(ok, msg)
            }
        }
    }

    // MARK: - DNS resolution

    /// Resolve a host to its IPv4/IPv6 literals. If `host` is already an IP literal,
    /// returns it unchanged.
    static func resolveIPs(host: String) -> [String] {
        if isIPLiteral(host) { return [host] }

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var ips: [String] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if !ip.isEmpty && !ips.contains(ip) { ips.append(ip) }
            }
            ptr = info.pointee.ai_next
        }
        return ips
    }

    static func isIPLiteral(_ s: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return true }
        return false
    }
}
