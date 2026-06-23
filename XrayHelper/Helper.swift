import Foundation

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: XrayHelperProtocol.self)
        connection.exportedObject = Helper()
        connection.resume()
        return true
    }
}

/// XPC-exposed facade. A fresh `Helper` is created per connection, so all mutable
/// TUN state lives in the `TunController` singleton to survive reconnects.
class Helper: NSObject, XrayHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void) {
        reply("XrayHelper \(HelperVersion)")
    }

    func startTUN(configJSON: Data, reply: @escaping (Bool, String) -> Void) {
        do {
            let config = try JSONDecoder().decode(TunStartConfig.self, from: configJSON)
            TunController.shared.start(config: config, reply: reply)
        } catch {
            reply(false, "Invalid TUN config: \(error.localizedDescription)")
        }
    }

    func stopTUN(reply: @escaping (Bool, String) -> Void) {
        TunController.shared.stop(reply: reply)
    }

    func getTUNStatus(reply: @escaping (Bool, String) -> Void) {
        TunController.shared.status(reply: reply)
    }

    func uninstall(reply: @escaping (Bool, String) -> Void) {
        TunController.shared.stop { _, _ in
            let fm = FileManager.default
            var ok = true
            var msg = "Uninstalled."
            // Remove the privileged helper binary and its launchd plist.
            let paths = [
                "/Library/PrivilegedHelperTools/\(HelperMachServiceName)",
                "/Library/LaunchDaemons/\(HelperMachServiceName).plist"
            ]
            for path in paths where fm.fileExists(atPath: path) {
                do { try fm.removeItem(atPath: path) }
                catch { ok = false; msg = "Failed to remove \(path): \(error.localizedDescription)" }
            }
            // Best-effort unload from launchd, then exit so the process is gone.
            _ = Shell.run("/bin/launchctl", ["remove", HelperMachServiceName])
            reply(ok, msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(ok ? 0 : 1) }
        }
    }
}

let HelperVersion = "0.2.0"

// MARK: - TUN orchestration

/// Owns the full TUN lifecycle as root: the tun2socks bridge process, the split-default
/// routes, the per-server pin routes, and the DNS override. Every piece of state added
/// during `start` is tracked so `stop` (and failure rollback) can undo it precisely.
final class TunController {
    static let shared = TunController()
    private init() {}

    private let queue = DispatchQueue(label: "com.xraygui.helper.tun")

    private var process: Process?
    private var pinnedRoutes: [String] = [] // host routes for server IPs (delete on stop)
    private var splitRoutes: [String] = [] // 0.0.0.0/1 & 128.0.0.0/1 (delete on stop)
    private var dnsService: String? // network service whose DNS we overrode
    private var savedDNS: [String]? // original DNS servers to restore
    private var originalGateway: String?
    private var activeTunName: String?

    var isRunning: Bool { queue.sync { process?.isRunning ?? false } }

    func status(reply: @escaping (Bool, String) -> Void) {
        queue.async {
            let running = self.process?.isRunning ?? false
            reply(running, running ? "TUN active on \(self.activeTunName ?? "?")" : "TUN inactive")
        }
    }

    func start(config: TunStartConfig, reply: @escaping (Bool, String) -> Void) {
        queue.async {
            // Idempotent: tear down any prior state first.
            self.teardownLocked()

            guard FileManager.default.fileExists(atPath: config.tun2socksPath) else {
                reply(false, "tun2socks binary not found at \(config.tun2socksPath)")
                return
            }

            // 1) Capture the original default route (gateway) so we can pin server IPs to it.
            guard let gw = Self.defaultGateway() else {
                reply(false, "Could not determine the current default gateway.")
                return
            }
            self.originalGateway = gw

            // 2) Launch tun2socks; it creates the utun device.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: config.tun2socksPath)
            proc.arguments = [
                "-device", config.tunName,
                "-proxy", "socks5://\(config.socksHost):\(config.socksPort)",
                "-loglevel", config.logLevel
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                self.teardownLocked()
                reply(false, "Failed to launch tun2socks: \(error.localizedDescription)")
                return
            }
            self.process = proc
            self.activeTunName = config.tunName

            // Watchdog: if tun2socks dies unexpectedly (not via stop()), roll back the
            // routes/DNS so traffic is not stranded routing into a dead utun. The
            // identity check makes this a no-op for teardown we initiated (which nils
            // `process` first).
            proc.terminationHandler = { [weak self] _ in
                guard let self else { return }
                queue.async {
                    if self.process === proc { self.teardownLocked() }
                }
            }

            // 3) Wait for the utun interface to appear, then configure its address.
            guard Self.waitForInterface(config.tunName, timeout: 5) else {
                self.teardownLocked()
                reply(false, "tun2socks did not bring up \(config.tunName) in time.")
                return
            }
            _ = Shell.run("/sbin/ifconfig", [
                config.tunName, config.tunAddress, config.tunAddress,
                "netmask", config.tunMask, "up"
            ])

            // 4) Pin each resolved server IP to the original gateway to avoid a routing loop.
            for ip in config.serverIPs where !ip.isEmpty {
                let r = Shell.run("/sbin/route", ["add", "-host", ip, gw])
                if r.ok { self.pinnedRoutes.append(ip) }
            }

            // 5) Split-default override: route everything through the tun without deleting
            //    the real default (so the pin routes above keep working).
            for net in ["0.0.0.0/1", "128.0.0.0/1"] {
                let r = Shell.run("/sbin/route", ["add", "-net", net, "-interface", config.tunName])
                if r.ok { self.splitRoutes.append(net) }
            }

            // 6) Override DNS on the primary network service.
            if let service = Self.primaryNetworkService() {
                self.dnsService = service
                self.savedDNS = Self.currentDNS(service: service)
                if !config.dnsServers.isEmpty {
                    _ = Shell.run("/usr/sbin/networksetup",
                                  ["-setdnsservers", service] + config.dnsServers)
                }
            }

            reply(true, "TUN active on \(config.tunName) via gateway \(gw).")
        }
    }

    func stop(reply: @escaping (Bool, String) -> Void) {
        queue.async {
            self.teardownLocked()
            reply(true, "TUN stopped.")
        }
    }

    /// Undo everything `start` established. Safe to call repeatedly.
    private func teardownLocked() {
        // Kill the bridge process.
        if let p = process, p.isRunning {
            p.terminate()
            // Give it a moment, then force kill if needed.
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(50000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil

        // Remove split-default routes.
        for net in splitRoutes {
            _ = Shell.run("/sbin/route", ["delete", "-net", net])
        }
        splitRoutes.removeAll()

        // Remove pinned server host routes.
        for ip in pinnedRoutes {
            _ = Shell.run("/sbin/route", ["delete", "-host", ip])
        }
        pinnedRoutes.removeAll()

        // Destroy the tun interface if it lingers.
        if let name = activeTunName {
            _ = Shell.run("/sbin/ifconfig", [name, "destroy"])
        }
        activeTunName = nil

        // Restore DNS.
        if let service = dnsService {
            let restore = savedDNS?.isEmpty == false ? savedDNS! : ["empty"]
            _ = Shell.run("/usr/sbin/networksetup", ["-setdnsservers", service] + restore)
        }
        dnsService = nil
        savedDNS = nil
        originalGateway = nil
    }

    // MARK: Network helpers

    /// Parse `route -n get default` for the active gateway IP.
    static func defaultGateway() -> String? {
        let out = Shell.run("/sbin/route", ["-n", "get", "default"]).output
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Poll until the named interface exists (tun2socks creates it asynchronously).
    static func waitForInterface(_ name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Shell.run("/sbin/ifconfig", [name]).ok { return true }
            usleep(100_000)
        }
        return false
    }

    /// The network service (e.g. "Wi-Fi") backing the current default route's interface.
    static func primaryNetworkService() -> String? {
        // Map default-route interface (e.g. en0) to a service name via listnetworkserviceorder.
        let dev: String? = {
            let out = Shell.run("/sbin/route", ["-n", "get", "default"]).output
            for line in out.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("interface:") {
                    return t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }()
        let order = Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).output
        if let dev {
            // Blocks look like: "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)"
            let blocks = order.components(separatedBy: "\n\n")
            for block in blocks where block.contains("Device: \(dev)") {
                for line in block.components(separatedBy: "\n") where line.hasPrefix("(") {
                    if let range = line.range(of: ") ") {
                        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        // Fallback: first enabled service.
        for line in order.components(separatedBy: "\n") where line.hasPrefix("(1) ") {
            return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func currentDNS(service: String) -> [String] {
        let out = Shell.run("/usr/sbin/networksetup", ["-getdnsservers", service]).output
        // networksetup prints "There aren't any DNS Servers set on X." when empty,
        // otherwise one server per line. Keep only IP literals (IPv4 contains ".",
        // IPv6 contains ":"); this preserves IPv6 servers that begin with a hex letter.
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty, !line.contains(" ") else { return false }
                return line.contains(".") || line.contains(":")
            }
    }
}

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (p.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
