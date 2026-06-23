import Foundation
import ServiceManagement

/// Manages registration of XrayGUI as a macOS *Login Item* so the app can
/// launch automatically when the user signs in.
///
/// The implementation is built on top of `SMAppService.mainApp`, the modern
/// API introduced in macOS 13 (Ventura) that replaces the deprecated
/// `SMLoginItemSetEnabled` helper-bundle approach. No external helper target
/// or privileged operation is required: macOS surfaces the registration in
/// *System Settings → General → Login Items* where the user can override it.
///
/// This type is a pure, stateless service — it never caches state and always
/// reflects the live status reported by the system.
enum LaunchAtLogin {

    /// Whether the launch-at-login feature is available on the current OS.
    ///
    /// `SMAppService` requires macOS 13 or later, so this is `false` on any
    /// earlier system. Callers should hide or disable related UI when this
    /// returns `false`.
    static var isAvailable: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    /// Whether the app is currently registered as a login item and enabled.
    ///
    /// Returns `true` only when `SMAppService.mainApp.status` is `.enabled`.
    /// Any other status — `.notRegistered`, `.notFound`, `.requiresApproval`
    /// (the user has not yet approved the item in System Settings), or an
    /// unavailable OS — yields `false`.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Enables or disables launch at login.
    ///
    /// - Parameter enabled: Pass `true` to register the app as a login item,
    ///   `false` to unregister it.
    /// - Returns: `true` if the requested change was applied successfully;
    ///   `false` if the OS is too old or the underlying `SMAppService`
    ///   operation threw an error.
    ///
    /// Registering an already-registered item (or unregistering an
    /// already-unregistered one) is treated as a success by the system and
    /// will not throw.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        (try? apply(enabled)) != nil
    }

    /// Throwing variant of ``setEnabled(_:)`` that surfaces the underlying
    /// `SMAppService` error (e.g. the item still `requiresApproval` in System
    /// Settings) so the UI can tell the user why a change did not take effect.
    static func apply(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { throw LaunchError.unavailable }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    enum LaunchError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Launch at Login requires macOS 13 or later."
        }
    }
}
