import Foundation

let HelperMachServiceName = "com.xraygui.helper"

@objc protocol XrayHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func createTUNInterface(name: String, ip: String, mask: String, reply: @escaping (Bool, String) -> Void)
    func destroyTUNInterface(name: String, reply: @escaping (Bool, String) -> Void)
    func addRoute(destination: String, gateway: String, interfaceName: String, reply: @escaping (Bool, String) -> Void)
    func removeRoute(destination: String, reply: @escaping (Bool, String) -> Void)
    func setDNS(servers: [String], reply: @escaping (Bool, String) -> Void)
    func resetDNS(reply: @escaping (Bool, String) -> Void)
}
