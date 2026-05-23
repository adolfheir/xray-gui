import Foundation

class HelperClient {
    static let shared = HelperClient()

    private var connection: NSXPCConnection?

    private init() {}

    private func connect() -> XrayHelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: HelperMachServiceName,
                                      options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: XrayHelperProtocol.self)
            conn.invalidationHandler = { [weak self] in self?.connection = nil }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxy as? XrayHelperProtocol
    }

    func installHelper(completion: @escaping (Bool, String) -> Void) {
        // SMJobBless requires code signing; scaffold for now
        completion(false, "Helper installation requires code signing. Run 'make install-helper' for development.")
    }

    func createTUN(name: String = "utun9", ip: String = "198.18.0.1", mask: String = "255.255.0.0",
                   completion: @escaping (Bool, String) -> Void) {
        guard let helper = connect() else {
            completion(false, "Cannot connect to helper. Is it installed?")
            return
        }
        helper.createTUNInterface(name: name, ip: ip, mask: mask, reply: completion)
    }

    func destroyTUN(name: String = "utun9", completion: @escaping (Bool, String) -> Void) {
        guard let helper = connect() else {
            completion(false, "Cannot connect to helper.")
            return
        }
        helper.destroyTUNInterface(name: name, reply: completion)
    }
}
