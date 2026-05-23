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

    func enableSystemProxy() {
        let services = listNetworkServices()
        for service in services {
            runNetworkSetup(["-setwebproxy", service, "127.0.0.1", "\(httpPort)"])
            runNetworkSetup(["-setwebproxystate", service, "on"])
            runNetworkSetup(["-setsecurewebproxy", service, "127.0.0.1", "\(httpPort)"])
            runNetworkSetup(["-setsecurewebproxystate", service, "on"])
            runNetworkSetup(["-setsocksfirewallproxy", service, "127.0.0.1", "\(socksPort)"])
            runNetworkSetup(["-setsocksfirewallproxystate", service, "on"])
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
        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
            .dropFirst() // Skip header line
            .map { $0 }
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
