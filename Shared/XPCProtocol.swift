import Foundation

let HelperMachServiceName = "com.xraygui.helper"

/// XPC surface exposed by the privileged helper.
///
/// TUN orchestration is centralized in the helper so that interface creation,
/// route-table mutation, DNS override, and the `tun2socks` bridge process all
/// share one atomic lifecycle and are torn down together — even if the GUI crashes.
///
/// `startTUN` receives a JSON-encoded `TunStartConfig` (see Shared/TunConfig.swift)
/// rather than many discrete arguments, so the contract can evolve without breaking
/// the `@objc` signature.
@objc protocol XrayHelperProtocol {
    /// Returns the helper's version string. Used to verify install/connection health.
    func getVersion(reply: @escaping (String) -> Void)

    /// Bring up TUN mode: launch the bridge (`tun2socks`-compatible) process as root,
    /// route default traffic through the tun device, pin the proxy server IP(s) to the
    /// original gateway to avoid a routing loop, and override system DNS.
    /// - Parameter configJSON: JSON-encoded `TunStartConfig`.
    /// - Returns: `(ok, message)`. On failure the helper rolls back any partial state.
    func startTUN(configJSON: Data, reply: @escaping (Bool, String) -> Void)

    /// Tear down TUN mode: kill the bridge process, restore the original default route,
    /// and reset DNS. Safe to call when not running (no-op).
    func stopTUN(reply: @escaping (Bool, String) -> Void)

    /// Reports whether the bridge process is currently alive plus a short status string.
    func getTUNStatus(reply: @escaping (Bool, String) -> Void)

    /// Stop TUN (if running) and self-uninstall the helper (remove plist + binary).
    func uninstall(reply: @escaping (Bool, String) -> Void)
}
