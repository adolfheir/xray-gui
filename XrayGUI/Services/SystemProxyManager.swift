import Foundation

class SystemProxyManager {
    static let shared = SystemProxyManager()

    private init() {}

    var httpPort: Int {
        get { UserDefaults.standard.integer(forKey: "httpProxyPort").nonZero ?? 10809 }
        set { UserDefaults.standard.set(newValue, forKey: "httpProxyPort") }
    }

    var socksPort: Int {
        get { UserDefaults.standard.integer(forKey: "socksProxyPort").nonZero ?? 10808 }
        set { UserDefaults.standard.set(newValue, forKey: "socksProxyPort") }
    }

    /// Hosts/domains that should bypass the proxy (loopback + private LAN ranges +
    /// `*.local`). Keeps local services and intranet reachable while proxied.
    static let bypassDomains = [
        "127.0.0.1", "localhost", "::1",
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "*.local", "169.254.0.0/16"
    ]

    /// Enable HTTP/HTTPS/SOCKS system proxy on every network service, using the given
    /// ports and applying the bypass list. Falls back to the persisted ports when 0.
    func enableSystemProxy(httpPort: Int? = nil, socksPort: Int? = nil) {
        let http = (httpPort?.nonZero) ?? self.httpPort
        let socks = (socksPort?.nonZero) ?? self.socksPort
        let services = listNetworkServices()
        for service in services {
            runNetworkSetup(["-setwebproxy", service, "127.0.0.1", "\(http)"])
            runNetworkSetup(["-setwebproxystate", service, "on"])
            runNetworkSetup(["-setsecurewebproxy", service, "127.0.0.1", "\(http)"])
            runNetworkSetup(["-setsecurewebproxystate", service, "on"])
            runNetworkSetup(["-setsocksfirewallproxy", service, "127.0.0.1", "\(socks)"])
            runNetworkSetup(["-setsocksfirewallproxystate", service, "on"])
            runNetworkSetup(["-setproxybypassdomains", service] + Self.bypassDomains)
        }
    }

    func disableSystemProxy() {
        let services = listNetworkServices()
        for service in services {
            runNetworkSetup(["-setwebproxystate", service, "off"])
            runNetworkSetup(["-setsecurewebproxystate", service, "off"])
            runNetworkSetup(["-setsocksfirewallproxystate", service, "off"])
        }
    }

    private func listNetworkServices() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // First line is the "An asterisk (*) denotes..." header; disabled services are
        // prefixed with "*" and must be skipped (networksetup rejects them).
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
    }

    @discardableResult
    private func runNetworkSetup(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
