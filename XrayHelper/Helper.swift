import Foundation

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: XrayHelperProtocol.self)
        connection.exportedObject = Helper()
        connection.resume()
        return true
    }
}

class Helper: NSObject, XrayHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void) {
        reply("XrayHelper 0.1.0")
    }

    func createTUNInterface(name: String, ip: String, mask: String, reply: @escaping (Bool, String) -> Void) {
        // Create utun interface using ifconfig
        let result = runCommand("/sbin/ifconfig", args: [name, "create"])
        guard result.0 else { reply(false, result.1); return }
        let result2 = runCommand("/sbin/ifconfig", args: [name, ip, ip, "netmask", mask, "up"])
        reply(result2.0, result2.1)
    }

    func destroyTUNInterface(name: String, reply: @escaping (Bool, String) -> Void) {
        let result = runCommand("/sbin/ifconfig", args: [name, "destroy"])
        reply(result.0, result.1)
    }

    func addRoute(destination: String, gateway: String, interfaceName: String, reply: @escaping (Bool, String) -> Void) {
        let result = runCommand("/sbin/route", args: ["add", "-net", destination, gateway])
        reply(result.0, result.1)
    }

    func removeRoute(destination: String, reply: @escaping (Bool, String) -> Void) {
        let result = runCommand("/sbin/route", args: ["delete", destination])
        reply(result.0, result.1)
    }

    func setDNS(servers: [String], reply: @escaping (Bool, String) -> Void) {
        // Set DNS via networksetup on Wi-Fi interface
        var args = ["-setdnsservers", "Wi-Fi"]
        args.append(contentsOf: servers)
        let result = runCommand("/usr/sbin/networksetup", args: args)
        reply(result.0, result.1)
    }

    func resetDNS(reply: @escaping (Bool, String) -> Void) {
        let result = runCommand("/usr/sbin/networksetup", args: ["-setdnsservers", "Wi-Fi", "empty"])
        reply(result.0, result.1)
    }

    private func runCommand(_ path: String, args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
