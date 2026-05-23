import Foundation

class XrayCoreManager {
    static let shared = XrayCoreManager()

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    // 守护状态：用户主动 stop() 时设为 false，阻止 terminationHandler 自动重启
    private var shouldKeepAlive = false
    private var currentConfigPath: String?
    private var restartCount = 0
    private let maxRestartCount = 5          // 连续崩溃上限
    private var lastStartTime: Date?

    var xrayBinaryPath: String {
        get { UserDefaults.standard.string(forKey: "xrayBinaryPath") ?? "" }
        set { UserDefaults.standard.setValue(newValue, forKey: "xrayBinaryPath") }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start(configPath: String) throws {
        guard !isRunning else { return }
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
            self?.handleTermination(exitCode: p.terminationStatus)
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

    func stop() {
        shouldKeepAlive = false       // 告知 terminationHandler 不要重启
        restartCount = 0
        cleanupProcess()
        Task { @MainActor in
            AppState.shared.isRunning = false
            AppState.shared.addLog("Xray stopped", level: .info)
        }
    }

    func restart(configPath: String? = nil) throws {
        let path = configPath ?? currentConfigPath
        guard let path else { throw XrayError.configNotFound }
        stop()
        Thread.sleep(forTimeInterval: 0.3)
        try start(configPath: path)
    }

    // MARK: - 守护逻辑

    private func handleTermination(exitCode: Int32) {
        cleanupProcess()

        Task { @MainActor in
            AppState.shared.isRunning = false
            AppState.shared.addLog("Xray exited (code \(exitCode))", level: exitCode == 0 ? .info : .error)
        }

        guard shouldKeepAlive, let configPath = currentConfigPath else { return }

        // 如果进程启动后极短时间就崩溃（< 2s），视为连续崩溃
        let aliveSeconds = lastStartTime.map { Date().timeIntervalSince($0) } ?? 99
        if aliveSeconds < 2 {
            restartCount += 1
        } else {
            restartCount = 0   // 运行超过 2s 才崩溃，重置计数
        }

        if restartCount >= maxRestartCount {
            shouldKeepAlive = false
            Task { @MainActor in
                AppState.shared.addLog("Xray crashed \(self.maxRestartCount) times consecutively, giving up.", level: .error)
            }
            return
        }

        // 指数退避：1s / 2s / 4s / 8s
        let delay = pow(2.0, Double(restartCount - 1))
        Task { @MainActor in
            AppState.shared.addLog("Restarting in \(Int(delay))s (attempt \(self.restartCount)/\(self.maxRestartCount))...", level: .warning)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldKeepAlive else { return }
            try? self.start(configPath: configPath)
        }
    }

    private func cleanupProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
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
