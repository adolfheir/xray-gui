import Foundation
import ServiceManagement

/// App-side client for the privileged helper. Manages the XPC connection, installs the
/// helper via `SMAppService` (macOS 13+), and forwards TUN start/stop calls.
///
/// `SMAppService.daemon` keeps the helper binary *inside* the app bundle
/// (`Contents/Library/LaunchServices/com.xraygui.helper`) and registers the launchd
/// job from the embedded `Contents/Library/LaunchDaemons/com.xraygui.helper.plist`.
/// This replaces the deprecated `SMJobBless`, which required Developer ID signing with
/// matching designated requirements and never worked on ad-hoc dev builds.
final class HelperClient {
    static let shared = HelperClient()

    private let daemonPlistName = "com.xraygui.helper.plist"
    private var connection: NSXPCConnection?

    private init() {}

    private var service: SMAppService {
        SMAppService.daemon(plistName: daemonPlistName)
    }

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

    /// Whether the helper is registered and enabled with launchd.
    var isHelperInstalled: Bool {
        service.status == .enabled
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

    // MARK: Install (SMAppService)

    /// Register the bundled helper as a privileged launchd daemon via `SMAppService`.
    /// On first run macOS may require the user to approve the background item in
    /// System Settings → General → Login Items & Extensions; in that case we open the
    /// pane and report a clear message so the user can approve and retry.
    func installHelper(completion: @escaping (Bool, String) -> Void) {
        let service = self.service

        switch service.status {
        case .enabled:
            completion(true, "Helper already installed.")
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            completion(false, "Approval required: enable XrayGUI under System Settings → General → Login Items & Extensions → Allow in the Background, then retry.")
            return
        default:
            break // .notRegistered / .notFound → register below
        }

        do {
            try service.register()
            // Drop any stale connection so the next call dials the freshly registered service.
            connection?.invalidate()
            connection = nil
            if service.status == .enabled {
                completion(true, "Helper installed successfully.")
            } else {
                SMAppService.openSystemSettingsLoginItems()
                completion(false, "Helper registered but needs approval. Enable XrayGUI under System Settings → General → Login Items & Extensions, then retry.")
            }
        } catch {
            completion(false, "Failed to register helper: \(error.localizedDescription)")
        }
    }

    /// Stop any running TUN, then unregister the launchd daemon via `SMAppService`.
    func uninstallHelper(completion: @escaping (Bool, String) -> Void) {
        let finishUnregister: () -> Void = { [weak self] in
            guard let self else { completion(false, "Client deallocated."); return }
            self.connection?.invalidate()
            self.connection = nil
            do {
                try self.service.unregister()
                completion(true, "Helper uninstalled.")
            } catch {
                completion(false, "Failed to unregister helper: \(error.localizedDescription)")
            }
        }
        // Best-effort: tear down TUN side effects before the daemon goes away.
        if let helper = proxy({ _, _ in finishUnregister() }) {
            helper.stopTUN { _, _ in finishUnregister() }
        } else {
            finishUnregister()
        }
    }
}
