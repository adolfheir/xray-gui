import Foundation
import SystemConfiguration

/// Watches the system network proxy configuration via `SCDynamicStore` and reports
/// when it changes from outside this app (e.g. the user edits proxies in System
/// Settings, or another VPN/proxy app hijacks them).
///
/// The guard is deliberately dependency-free: it knows nothing about `AppState`, the
/// UI, or logging. It does not read the actual proxy values, nor does it try to tell
/// whether a given change was caused by this app's own writes — the "don't fight
/// yourself" debouncing/ownership logic is the caller's responsibility. It only
/// observes the global proxies key and relays a single coalesced notification.
///
/// `SCDynamicStore` invokes its callback as a C function pointer, which cannot capture
/// Swift context. `self` is therefore threaded through `SCDynamicStoreContext.info` as
/// an unretained pointer and restored inside the callback via `takeUnretainedValue()`.
/// Because notifications can arrive in bursts (including ones triggered by this app's
/// own `networksetup` writes), the callback is debounced before `onProxyChanged` fires
/// on the main thread.
final class SystemProxyGuard {
    /// Invoked on the main thread (debounced) when the system network proxy
    /// configuration changes from outside this app.
    var onProxyChanged: (() -> Void)?

    /// Coalescing window for proxy-change notifications. Proxy edits frequently fire
    /// several `SCDynamicStore` callbacks in quick succession; we wait this long after
    /// the last one before notifying the owner.
    private let debounceInterval: TimeInterval = 0.6

    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var pendingNotify: DispatchWorkItem?

    /// Guards `start()`/`stop()` idempotency.
    private var isObserving = false

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Begins observing the global system proxies key. Idempotent: calling `start()`
    /// while already observing is a no-op.
    func start() {
        guard !isObserving else { return }

        // Thread `self` through the C callback via an unretained pointer. We must not
        // retain here (the store does not own us); `stop()`/`deinit` tear everything
        // down before `self` goes away.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil,
            "com.xraygui.sysproxyguard" as CFString,
            { _, _, info in
                // C callback: cannot capture context, so restore `self` from `info`.
                guard let info else { return }
                let guardSelf = Unmanaged<SystemProxyGuard>.fromOpaque(info).takeUnretainedValue()
                guardSelf.handleProxyChange()
            },
            &context
        ) else {
            return
        }

        // Global proxy settings key, e.g. "State:/Network/Global/Proxies".
        let proxiesKey = SCDynamicStoreKeyCreateProxies(nil)
        let keys = [proxiesKey] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.store = store
        runLoopSource = source
        isObserving = true
    }

    /// Stops observing and tears down the run loop source. Idempotent: safe to call
    /// when not currently observing.
    func stop() {
        pendingNotify?.cancel()
        pendingNotify = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        store = nil
        isObserving = false
    }

    // MARK: - Internals

    /// Called from the `SCDynamicStore` C callback (arbitrary thread). Debounces the
    /// burst of change notifications and forwards a single one on the main thread.
    private func handleProxyChange() {
        let work = DispatchWorkItem { [weak self] in
            self?.pendingNotify = nil
            self?.onProxyChanged?()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingNotify?.cancel()
            pendingNotify = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }
}
