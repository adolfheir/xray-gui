import AppKit
import Foundation

/// Observes macOS system sleep/wake transitions and forwards them to the owner via
/// closures. This is a building block for connection robustness: a tunnel that was
/// alive before the Mac slept usually needs to be re-established after wake, since
/// sockets and the upstream connection are typically torn down across sleep.
///
/// The monitor is deliberately dependency-free: it knows nothing about `AppState`,
/// the UI, or logging. It only registers `NSWorkspace` observers and relays events.
/// Wiring (e.g. restarting Xray-core on wake) is the caller's responsibility.
///
/// `NSWorkspace` notifications are already delivered on the main thread, but callbacks
/// are re-dispatched through `DispatchQueue.main.async` defensively so the contract
/// ("invoked on the main thread") holds regardless of how the system delivers them.
final class PowerEventMonitor {
    /// Invoked on the main thread after the Mac wakes from sleep.
    var onWake: (() -> Void)?

    /// Invoked on the main thread when the Mac is about to sleep.
    var onSleep: (() -> Void)?

    /// Tokens for the registered `NSWorkspace` observers, kept so `stop()` can remove them.
    private var observerTokens: [NSObjectProtocol] = []

    /// Idempotency guard: true while observers are registered.
    private var isObserving = false

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Registers observers for system wake and sleep notifications. Idempotent: calling
    /// `start()` while already observing is a no-op and will not register duplicates.
    func start() {
        guard !isObserving else { return }
        isObserving = true

        let center = NSWorkspace.shared.notificationCenter

        let wakeToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onWake?()
            }
        }

        let sleepToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onSleep?()
            }
        }

        observerTokens = [wakeToken, sleepToken]
    }

    /// Unregisters all observers. Idempotent: safe to call when not observing.
    func stop() {
        guard isObserving else { return }
        isObserving = false

        let center = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}
