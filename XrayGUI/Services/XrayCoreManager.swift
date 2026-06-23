import Foundation

/// Owns the Xray-core child process: launch, stdout/stderr piping, and a crash
/// supervisor with exponential backoff.
///
/// All mutable state is confined to a single serial queue (`stateQueue`) because the
/// process `terminationHandler` fires on an arbitrary background thread while the public
/// API is driven from the main actor. Restart is delegated back to `AppState` so that
/// proxy/TUN/traffic side effects are re-applied as a single source of truth.
final class XrayCoreManager {
    static let shared = XrayCoreManager()

    private let stateQueue = DispatchQueue(label: "com.xraygui.xraycore")

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    // Supervisor state (guarded by stateQueue).
    private var shouldKeepAlive = false
    private var currentConfigPath: String?
    private var restartCount = 0
    private let maxRestartCount = 5
    private var lastStartTime: Date?
    private var pendingRestart: DispatchWorkItem?

    var xrayBinaryPath: String {
        get { UserDefaults.standard.string(forKey: "xrayBinaryPath") ?? "" }
        set { UserDefaults.standard.setValue(newValue, forKey: "xrayBinaryPath") }
    }

    var isRunning: Bool { stateQueue.sync { process?.isRunning ?? false } }

    // MARK: - Public API (main actor)

    func start(configPath: String) throws {
        var thrown: Error?
        stateQueue.sync {
            do { try startLocked(configPath: configPath) }
            catch { thrown = error }
        }
        if let thrown { throw thrown }
    }

    func stop() {
        stateQueue.sync {
            shouldKeepAlive = false
            pendingRestart?.cancel()
            pendingRestart = nil
            restartCount = 0
            cleanupProcessLocked()
        }
        Task { @MainActor in
            AppState.shared.isRunning = false
            AppState.shared.addLog("Xray stopped", level: .info)
        }
    }

    func restart(configPath: String? = nil) throws {
        let path = stateQueue.sync { configPath ?? currentConfigPath }
        guard let path else { throw XrayError.configNotFound }
        stop()
        Thread.sleep(forTimeInterval: 0.3)
        try start(configPath: path)
    }

    // MARK: - Locked implementation (runs on stateQueue)

    private func startLocked(configPath: String) throws {
        guard !(process?.isRunning ?? false) else { return }
        guard !xrayBinaryPath.isEmpty, FileManager.default.fileExists(atPath: xrayBinaryPath) else {
            throw XrayError.binaryNotFound
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw XrayError.configNotFound
        }

        currentConfigPath = configPath
        shouldKeepAlive = true
        lastStartTime = Date()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xrayBinaryPath)
        proc.arguments = ["run", "-c", configPath]
        proc.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor in
                for line in lines { AppState.shared.addLog(line, level: .info) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            Task { @MainActor in
                for line in lines { AppState.shared.addLog(line, level: .error) }
            }
        }

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            stateQueue.async { self.handleTerminationLocked(process: p, exitCode: p.terminationStatus) }
        }

        try proc.run()
        process = proc
        outputPipe = outPipe
        errorPipe = errPipe

        Task { @MainActor in
            AppState.shared.isRunning = true
            AppState.shared.addLog("Xray started: \(configPath)", level: .info)
        }
    }

    /// Crash supervisor. Runs on stateQueue. Ignores stale handlers from previous
    /// processes and delegates the actual restart to `AppState` so side effects are
    /// re-applied together.
    private func handleTerminationLocked(process terminated: Process, exitCode: Int32) {
        // Ignore terminations from a process that is no longer the active one.
        guard terminated === process || process == nil else { return }
        cleanupProcessLocked()

        Task { @MainActor in
            AppState.shared.isRunning = false
            AppState.shared.addLog("Xray exited (code \(exitCode))", level: exitCode == 0 ? .info : .error)
        }

        guard shouldKeepAlive, let configPath = currentConfigPath else { return }

        // A process that died within 2s of launch is treated as a crash loop.
        let aliveSeconds = lastStartTime.map { Date().timeIntervalSince($0) } ?? 99
        restartCount = aliveSeconds < 2 ? restartCount + 1 : 0

        if restartCount >= maxRestartCount {
            shouldKeepAlive = false
            Task { @MainActor in
                AppState.shared.addLog("Xray crashed \(self.maxRestartCount) times consecutively, giving up.", level: .error)
                AppState.shared.teardownProxySideEffects()
            }
            return
        }

        let delay = pow(2.0, Double(restartCount - 1)) // 1s / 2s / 4s / 8s
        Task { @MainActor in
            AppState.shared.addLog("Restarting in \(Int(delay))s (attempt \(self.restartCount)/\(self.maxRestartCount))...", level: .warning)
        }

        // Cancellable so a user-initiated stop() can abort a pending restart.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            stateQueue.async {
                guard self.shouldKeepAlive else { return }
                self.pendingRestart = nil
                _ = configPath // captured for clarity; AppState re-reads its own selection
                Task { @MainActor in AppState.shared.handleCoreCrashRestart() }
            }
        }
        pendingRestart = work
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cleanupProcessLocked() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        outputPipe = nil
        errorPipe = nil
    }
}

enum XrayError: Error, LocalizedError {
    case binaryNotFound
    case configNotFound
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "Xray binary not found. Please set the path in Settings."
        case .configNotFound: return "Config file not found."
        case .startFailed(let msg): return "Failed to start Xray: \(msg)"
        }
    }
}
