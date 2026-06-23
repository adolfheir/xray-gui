import Network

/// Watches the system's network path with `NWPathMonitor` and reports changes that
/// likely warrant a reconnect (Wi-Fi switch, cable plug/unplug, loss/restore of
/// connectivity, or a switch between interfaces such as Wi-Fi → Ethernet).
///
/// This service is intentionally self-contained: it does not touch `AppState`, the UI,
/// or logging. The only way out is the `onPathChange` callback, which the owner wires
/// up to drive reconnection logic.
///
/// Threading model: `NWPathMonitor` delivers `pathUpdateHandler` callbacks on the queue
/// passed to `start(queue:)`. We use a dedicated serial queue so all comparison state
/// (`lastIsReachable`, `lastInterfaceNames`, `hasBaseline`) is mutated from a single
/// thread without locks. The public `onPathChange` is always re-dispatched to the main
/// thread so callers can update app state safely.
final class NetworkMonitor {

    /// Invoked on the main thread when the network path changes in a way that
    /// likely requires reconnecting (interface switch, or transition to/from
    /// a satisfied/usable path). `isReachable` reflects the new state.
    var onPathChange: ((_ isReachable: Bool) -> Void)?

    /// Serial queue that backs the monitor. All mutable comparison state below is
    /// confined to this queue because `pathUpdateHandler` runs here.
    private let queue = DispatchQueue(label: "com.xraygui.networkmonitor")

    /// The active monitor. `NWPathMonitor` cannot be reused after `cancel()`, so this
    /// is recreated on every `start()` and dropped on `stop()`.
    private var monitor: NWPathMonitor?

    /// Idempotency guard for `start()` / `stop()`.
    private var isMonitoring = false

    /// Whether we have already recorded the first ("baseline") path. The very first
    /// `pathUpdateHandler` fires immediately after `start()` and represents the current
    /// state, not a change — it should only seed the baseline, never trigger a callback.
    private var hasBaseline = false

    /// Last observed reachability (`path.status == .satisfied`).
    private var lastIsReachable = false

    /// Last observed set of available interface names, used as the "primary interface
    /// fingerprint" to detect interface-set changes (e.g. en0 → en1).
    private var lastInterfaceNames: Set<String> = []

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Begins monitoring. Idempotent: calling `start()` while already monitoring is a
    /// no-op. A fresh `NWPathMonitor` is created because a cancelled monitor cannot be
    /// restarted.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.isMonitoring else { return }
            isMonitoring = true
            hasBaseline = false

            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                self?.handle(path: path)
            }
            monitor.start(queue: queue)
        }
    }

    /// Stops monitoring and releases the underlying monitor. Idempotent: safe to call
    /// when not monitoring or multiple times.
    func stop() {
        queue.async { [weak self] in
            guard let self, isMonitoring else { return }
            isMonitoring = false
            monitor?.cancel()
            monitor = nil
            hasBaseline = false
        }
    }

    // MARK: - Path handling

    /// Evaluates a new path on the monitor queue, updates the cached baseline, and emits
    /// `onPathChange` (on the main thread) only when reachability or the available
    /// interface set actually changed. The first path after `start()` only seeds the
    /// baseline and never fires the callback.
    private func handle(path: NWPath) {
        let isReachable = path.status == .satisfied
        let interfaceNames = Set(path.availableInterfaces.map(\.name))

        // First callback: record the baseline only, do not report a "change".
        guard hasBaseline else {
            hasBaseline = true
            lastIsReachable = isReachable
            lastInterfaceNames = interfaceNames
            return
        }

        // De-duplicate: ignore updates that change neither reachability nor the
        // available interface set, to avoid spurious reconnect triggers.
        let reachabilityChanged = isReachable != lastIsReachable
        let interfacesChanged = interfaceNames != lastInterfaceNames
        guard reachabilityChanged || interfacesChanged else { return }

        lastIsReachable = isReachable
        lastInterfaceNames = interfaceNames

        DispatchQueue.main.async { [weak self] in
            self?.onPathChange?(isReachable)
        }
    }
}
