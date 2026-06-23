import Foundation
import Security
import ServiceManagement

/// App-side client for the privileged helper. Manages the XPC connection, installs
/// the helper via `SMJobBless`, and forwards TUN start/stop calls.
final class HelperClient {
    static let shared = HelperClient()

    private var connection: NSXPCConnection?

    private init() {}

    // MARK: Connection

    private func proxy(_ onError: @escaping (Bool, String) -> Void) -> XrayHelperProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: HelperMachServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: XrayHelperProtocol.self)
            conn.invalidationHandler = { [weak self] in self?.connection = nil }
            conn.interruptionHandler = { [weak self] in self?.connection = nil }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { err in
            onError(false, "Helper connection error: \(err.localizedDescription). Is the helper installed?")
        } as? XrayHelperProtocol
    }

    /// Whether the helper appears installed (binary present on disk).
    var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(HelperMachServiceName)")
    }

    // MARK: Health

    func getVersion(completion: @escaping (String?) -> Void) {
        guard let helper = proxy({ _, _ in completion(nil) }) else { completion(nil); return }
        helper.getVersion { v in completion(v) }
    }

    // MARK: TUN

    func startTUN(_ config: TunStartConfig, completion: @escaping (Bool, String) -> Void) {
        guard let data = try? JSONEncoder().encode(config) else {
            completion(false, "Failed to encode TUN config."); return
        }
        guard let helper = proxy(completion) else {
            completion(false, "Cannot connect to helper. Install it in Settings."); return
        }
        helper.startTUN(configJSON: data, reply: completion)
    }

    func stopTUN(completion: @escaping (Bool, String) -> Void) {
        guard let helper = proxy(completion) else { completion(false, "Helper not connected."); return }
        helper.stopTUN(reply: completion)
    }

    func tunStatus(completion: @escaping (Bool, String) -> Void) {
        guard let helper = proxy(completion) else { completion(false, "Helper not connected."); return }
        helper.getTUNStatus(reply: completion)
    }

    func uninstallHelper(completion: @escaping (Bool, String) -> Void) {
        guard let helper = proxy(completion) else { completion(false, "Helper not connected."); return }
        helper.uninstall { ok, msg in
            self.connection?.invalidate()
            self.connection = nil
            completion(ok, msg)
        }
    }

    // MARK: Install (SMJobBless)

    /// Installs the bundled `com.xraygui.helper` tool into /Library/PrivilegedHelperTools
    /// using `SMJobBless`. Requires both the app and the helper to be Developer ID signed
    /// with matching `SMPrivilegedExecutables` / `SMAuthorizedClients` designated
    /// requirements. On unsigned dev builds this fails with a clear message.
    func installHelper(completion: @escaping (Bool, String) -> Void) {
        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let authRef else {
            completion(false, "Failed to create authorization (\(status)).")
            return
        }
        defer { AuthorizationFree(authRef, []) }

        var authItem = kSMRightBlessPrivilegedHelper.withCString { cString in
            AuthorizationItem(name: cString, valueLength: 0, value: nil, flags: 0)
        }
        status = withUnsafeMutablePointer(to: &authItem) { itemPtr -> OSStatus in
            var rights = AuthorizationRights(count: 1, items: itemPtr)
            let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
            return AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
        }
        guard status == errAuthorizationSuccess else {
            completion(false, status == errAuthorizationCanceled
                ? "Authorization cancelled."
                : "Authorization denied (\(status)).")
            return
        }

        var cfError: Unmanaged<CFError>?
        let ok = SMJobBless(kSMDomainSystemLaunchd, HelperMachServiceName as CFString, authRef, &cfError)
        if ok {
            connection?.invalidate()
            connection = nil
            completion(true, "Helper installed successfully.")
        } else {
            let err = cfError?.takeRetainedValue()
            let detail = err.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
            completion(false, "SMJobBless failed: \(detail). The app and helper must be Developer ID signed.")
        }
    }
}
