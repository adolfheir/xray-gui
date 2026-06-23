import Foundation

/// Polls Xray-core's statistics API (through the `xray` CLI) and reports both
/// cumulative byte counters and a derived per-second throughput for the active
/// proxy outbound.
///
/// The manager shells out to `xray api statsquery` (falling back to
/// `xray api stats`) on a repeating background timer. Each tick sums the
/// `outbound>>>proxy>>>traffic>>>uplink` / `...>>>downlink` counters, computes
/// the rate against the previous sample, and delivers a `Snapshot` on the main
/// queue.
///
/// All mutable state is confined to a private serial queue, so `start`, `stop`
/// and the polling ticks may be invoked from any thread safely.
final class TrafficStatsManager {

    /// Shared singleton used across the app.
    static let shared = TrafficStatsManager()

    /// A single sample of traffic statistics.
    ///
    /// `*Total` values are the cumulative byte counters reported by Xray since
    /// the core started. `*Rate` values are bytes-per-second computed from the
    /// delta between the current and previous sample.
    struct Snapshot: Equatable {
        var uplinkTotal: Int64
        var downlinkTotal: Int64
        var uplinkRate: Int64
        var downlinkRate: Int64

        static let zero = Snapshot(uplinkTotal: 0, downlinkTotal: 0, uplinkRate: 0, downlinkRate: 0)
    }

    // MARK: - State (confined to `stateQueue`)

    /// Serial queue guarding all mutable state below and serialising ticks.
    private let stateQueue = DispatchQueue(label: "com.xraygui.trafficstats")

    private var timer: DispatchSourceTimer?
    private var polling = false

    /// True while a CLI query is in flight, used to skip overlapping ticks.
    private var queryInFlight = false

    private var previousUplinkTotal: Int64 = 0
    private var previousDownlinkTotal: Int64 = 0
    private var hasPreviousSample = false
    /// Monotonic timestamp (DispatchTime uptime nanoseconds) of the previous sample,
    /// so rate math is immune to wall-clock adjustments.
    private var lastSampleUptime: UInt64?

    // Captured configuration for the active polling session.
    private var xrayPath: String = ""
    private var apiPort: Int = 0
    private var onUpdate: ((Snapshot) -> Void)?

    private init() {}

    // MARK: - Public API

    /// Whether the manager is currently polling. Thread-safe.
    var isPolling: Bool {
        stateQueue.sync { polling }
    }

    /// Starts polling the Xray stats API.
    ///
    /// Any existing poller is stopped first. The poll runs every `interval`
    /// seconds on a background timer; results are delivered via `onUpdate` on
    /// the main queue.
    ///
    /// - Parameters:
    ///   - xrayPath: Absolute path to the `xray` executable.
    ///   - apiPort: Port of Xray's gRPC stats API (served on 127.0.0.1).
    ///   - interval: Seconds between polls. Values below 0.1 are clamped.
    ///   - onUpdate: Callback invoked on the main queue with each `Snapshot`.
    func start(xrayPath: String,
               apiPort: Int,
               interval: TimeInterval = 1,
               onUpdate: @escaping (Snapshot) -> Void) {
        let safeInterval = max(0.1, interval)

        stateQueue.sync {
            cancelTimerLocked()
            resetCountersLocked()

            self.xrayPath = xrayPath
            self.apiPort = apiPort
            self.onUpdate = onUpdate
            self.polling = true

            let newTimer = DispatchSource.makeTimerSource(queue: stateQueue)
            newTimer.schedule(deadline: .now() + safeInterval,
                              repeating: safeInterval,
                              leeway: .milliseconds(100))
            newTimer.setEventHandler { [weak self] in
                self?.tickLocked()
            }
            self.timer = newTimer
            newTimer.resume()
        }
    }

    /// Stops polling, cancels the timer and resets cumulative counters.
    func stop() {
        stateQueue.sync {
            cancelTimerLocked()
            resetCountersLocked()
            polling = false
            onUpdate = nil
        }
    }

    // MARK: - Polling (runs on `stateQueue`)

    /// Performs one poll tick. Runs on `stateQueue`.
    private func tickLocked() {
        guard polling, !queryInFlight else { return }

        let path = xrayPath
        let port = apiPort
        guard !path.isEmpty, port > 0 else { return }

        queryInFlight = true

        // Run the (blocking) CLI invocation off the state queue so the timer
        // queue is not held for the duration of the process.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let stats = Self.queryTraffic(xrayPath: path, apiPort: port)
            self.stateQueue.async {
                self.queryInFlight = false
                guard self.polling else { return }
                if let stats {
                    self.handleSampleLocked(uplink: stats.uplink, downlink: stats.downlink)
                }
                // On nil (malformed/empty), skip this tick keeping previous totals.
            }
        }
    }

    /// Integrates a fresh sample, computes rates and emits a `Snapshot`.
    /// Runs on `stateQueue`.
    private func handleSampleLocked(uplink: Int64, downlink: Int64) {
        let now = DispatchTime.now().uptimeNanoseconds

        var uplinkRate: Int64 = 0
        var downlinkRate: Int64 = 0

        if hasPreviousSample, let last = lastSampleUptime, now > last {
            let elapsed = Double(now &- last) / 1_000_000_000
            if elapsed > 0 {
                let upDelta = max(0, uplink - previousUplinkTotal)
                let downDelta = max(0, downlink - previousDownlinkTotal)
                uplinkRate = Int64((Double(upDelta) / elapsed).rounded())
                downlinkRate = Int64((Double(downDelta) / elapsed).rounded())
            }
        }

        previousUplinkTotal = uplink
        previousDownlinkTotal = downlink
        lastSampleUptime = now
        hasPreviousSample = true

        let snapshot = Snapshot(uplinkTotal: uplink,
                                downlinkTotal: downlink,
                                uplinkRate: uplinkRate,
                                downlinkRate: downlinkRate)

        let callback = onUpdate
        DispatchQueue.main.async {
            callback?(snapshot)
        }
    }

    // MARK: - Locked helpers

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func resetCountersLocked() {
        previousUplinkTotal = 0
        previousDownlinkTotal = 0
        hasPreviousSample = false
        lastSampleUptime = nil
        queryInFlight = false
    }

    // MARK: - CLI invocation & parsing

    /// Summed uplink/downlink totals for the proxy outbound.
    private struct TrafficTotals {
        var uplink: Int64
        var downlink: Int64
    }

    /// Runs the xray stats CLI and parses the proxy outbound totals.
    ///
    /// Tries `statsquery` first, then falls back to `stats`. Returns `nil` on
    /// any failure (process error, empty/malformed output) so the caller can
    /// skip the tick without disturbing previous totals.
    private static func queryTraffic(xrayPath: String, apiPort: Int) -> TrafficTotals? {
        let server = "127.0.0.1:\(apiPort)"

        let primaryArgs = ["api", "statsquery", "--server=\(server)"]
        if let output = runProcess(xrayPath: xrayPath, args: primaryArgs),
           let totals = parseTotals(from: output) {
            return totals
        }

        let fallbackArgs = ["api", "stats", "--server=\(server)"]
        if let output = runProcess(xrayPath: xrayPath, args: fallbackArgs),
           let totals = parseTotals(from: output) {
            return totals
        }

        return nil
    }

    /// Launches `xrayPath` with `args`, returning captured stdout, or `nil` if
    /// the process failed to run or exited with a non-zero status with no
    /// usable output.
    private static func runProcess(xrayPath: String, args: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: xrayPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xrayPath)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Watchdog: terminate a hung CLI so this worker can't stall indefinitely.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)

        // Drain stdout before waiting to avoid deadlock on large output.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        // Drain stderr to prevent the child from blocking on a full pipe.
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard !data.isEmpty else { return nil }
        return data
    }

    /// Parses Xray stats JSON and sums the proxy outbound up/down counters.
    ///
    /// Expected shape: `{"stat":[{"name":"...","value":"123"}, ...]}`.
    /// `value` may be absent (treated as 0). Returns `nil` if the JSON cannot
    /// be decoded into the expected structure.
    private static func parseTotals(from data: Data) -> TrafficTotals? {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // A response with no "stat" key at all is treated as malformed/transient and
        // skipped (return nil) rather than recorded as a zero sample, which would
        // otherwise clobber the previous totals. A present-but-empty array is a valid
        // "no traffic yet" sample.
        guard root["stat"] != nil else { return nil }
        let stats = (root["stat"] as? [[String: Any]]) ?? []

        var uplink: Int64 = 0
        var downlink: Int64 = 0

        for entry in stats {
            guard let name = entry["name"] as? String else { continue }
            guard name.contains("outbound>>>proxy>>>traffic>>>") else { continue }

            let value = numericValue(entry["value"])
            if name.contains(">>>uplink") {
                uplink += value
            } else if name.contains(">>>downlink") {
                downlink += value
            }
        }

        return TrafficTotals(uplink: uplink, downlink: downlink)
    }

    /// Coerces a JSON stat `value` (string, number, or missing) into an Int64.
    private static func numericValue(_ raw: Any?) -> Int64 {
        switch raw {
        case let string as String:
            return Int64(string) ?? 0
        case let number as NSNumber:
            return number.int64Value
        default:
            return 0
        }
    }
}
