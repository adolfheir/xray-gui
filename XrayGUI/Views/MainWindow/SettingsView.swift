import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's settings screen: Xray-core binary, local inbounds, TUN mode + privileged
/// helper, system preferences, update checks and an About section. Uses a grouped
/// `Form` to match macOS System Settings styling.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // Mirrors of UserDefaults-backed manager paths so TextFields can bind to local
    // @State and we persist back via onChange.
    @State private var xrayPath: String = XrayCoreManager.shared.xrayBinaryPath
    @State private var tun2socksPath: String = TunManager.shared.tun2socksPath

    // Live helper status, refreshed on appear and after install/uninstall.
    @State private var helperInstalled: Bool = HelperClient.shared.isHelperInstalled
    // Live login-item status (the system may override it in System Settings).
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    @State private var isCheckingUpdate = false

    // Live state for the "Download" action that fetches Xray-core from GitHub.
    @State private var isDownloadingCore = false
    @State private var downloadProgress: Double = 0

    // Live state for the tun2socks "Download" action.
    @State private var isDownloadingTun2socks = false
    @State private var tun2socksDownloadProgress: Double = 0

    private let logLevels = ["debug", "info", "warning", "error", "none"]

    var body: some View {
        Form {
            xrayCoreSection
            inboundsSection
            tunSection
            systemSection
            updatesSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            xrayPath = XrayCoreManager.shared.xrayBinaryPath
            tun2socksPath = TunManager.shared.tun2socksPath
            helperInstalled = HelperClient.shared.isHelperInstalled
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    // MARK: - Xray Core

    private var xrayBinaryExists: Bool {
        !xrayPath.isEmpty && FileManager.default.fileExists(atPath: xrayPath)
    }

    private var xrayCoreSection: some View {
        Section("Xray Core".localized) {
            // Path gets a full-width row of its own so long paths aren't cramped.
            // Monospaced + single line; hover shows the full path.
            TextField("Binary path".localized, text: $xrayPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .help(xrayPath.isEmpty ? "Binary path".localized : xrayPath)
                .onChange(of: xrayPath) { newValue in
                    XrayCoreManager.shared.xrayBinaryPath = newValue
                }

            // Actions + live status on one row.
            HStack(spacing: 8) {
                Button("Browse…".localized) { browseForXrayBinary() }
                Button("Test".localized) { testXrayBinary() }
                    .disabled(!xrayBinaryExists)
                Spacer()
                Label {
                    Text((xrayBinaryExists ? "Binary found" : "Binary not found at this path").localized)
                } icon: {
                    Image(systemName: xrayBinaryExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(xrayBinaryExists ? .green : .red)
                .labelStyle(.titleAndIcon)
            }

            // Auto-download row.
            HStack(spacing: 8) {
                Button("Download from GitHub".localized) { downloadXrayBinary() }
                    .disabled(isDownloadingCore)
                if isDownloadingCore {
                    ProgressView(value: downloadProgress)
                        .frame(width: 120)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }

            Text("Downloads the latest Xray-core release for your Mac and installs it automatically.".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func downloadXrayBinary() {
        isDownloadingCore = true
        downloadProgress = 0
        Task {
            do {
                let result = try await XrayCoreDownloader.installLatest { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                await MainActor.run {
                    xrayPath = result.path
                    XrayCoreManager.shared.xrayBinaryPath = result.path
                    appState.infoMessage = "Installed Xray-core %@".localized(result.version)
                    isDownloadingCore = false
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    isDownloadingCore = false
                }
            }
        }
    }

    private func browseForXrayBinary() {
        if let path = chooseFile() {
            xrayPath = path
            XrayCoreManager.shared.xrayBinaryPath = path
        }
    }

    private func testXrayBinary() {
        let path = xrayPath
        guard FileManager.default.fileExists(atPath: path) else {
            appState.errorMessage = "Binary not found at this path".localized
            return
        }
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["version"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var output = ""
            do {
                try proc.run()
                proc.waitUntilExit()
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } catch {
                output = error.localizedDescription
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                appState.errorMessage = trimmed.isEmpty ? "No output from binary.".localized : trimmed
            }
        }
    }

    // MARK: - Local Inbounds

    private var inboundsSection: some View {
        Section("Local Inbounds".localized) {
            portRow(label: "SOCKS Port".localized, value: $appState.buildOptions.socksPort)
            portRow(label: "HTTP Port".localized, value: $appState.buildOptions.httpPort) {
                // Keep the system-proxy manager's port mirror in sync.
                SystemProxyManager.shared.httpPort = appState.buildOptions.httpPort
            }
            portRow(label: "API Port".localized, value: $appState.buildOptions.apiPort)

            Picker("Listen Address".localized, selection: $appState.buildOptions.listenAddress) {
                Text("Local only (127.0.0.1)".localized).tag("127.0.0.1")
                Text("Allow LAN (0.0.0.0)".localized).tag("0.0.0.0")
            }

            Toggle("Allow UDP".localized, isOn: $appState.buildOptions.enableUDP)
            Toggle("Sniffing".localized, isOn: $appState.buildOptions.enableSniffing)
            Toggle("Traffic Stats".localized, isOn: $appState.buildOptions.enableStatsAPI)
            Toggle("Mux".localized, isOn: $appState.buildOptions.enableMux)

            Picker("Log Level".localized, selection: $appState.buildOptions.logLevel) {
                ForEach(logLevels, id: \.self) { level in
                    Text(level).tag(level)
                }
            }
        }
        .onChange(of: appState.buildOptions.socksPort) { newValue in
            SystemProxyManager.shared.socksPort = newValue
        }
    }

    private func portRow(label: String, value: Binding<Int>, onChange: (() -> Void)? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, formatter: Self.portFormatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onChange(of: value.wrappedValue) { _ in onChange?() }
            Stepper("", value: value, in: 0 ... 65535)
                .labelsHidden()
        }
    }

    private static let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 65535
        f.allowsFloats = false
        return f
    }()

    // MARK: - TUN Mode

    private var tunSection: some View {
        Section("TUN Mode".localized) {
            HStack(spacing: 8) {
                TextField("tun2socks path".localized, text: $tun2socksPath)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tun2socksPath) { newValue in
                        TunManager.shared.tun2socksPath = newValue
                    }
                Button("Browse…".localized) { browseForTun2socks() }
            }

            Text("TUN mode requires a tun2socks binary and the signed privileged helper to route all traffic through the proxy.".localized)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Auto-download row, mirroring the Xray-core section.
            HStack(spacing: 8) {
                Button("Download from GitHub".localized) { downloadTun2socks() }
                    .disabled(isDownloadingTun2socks)
                if isDownloadingTun2socks {
                    ProgressView(value: tun2socksDownloadProgress)
                        .frame(width: 120)
                    Text("\(Int(tun2socksDownloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: helperInstalled ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(helperInstalled ? .green : .orange)
                Text((helperInstalled ? "Helper installed" : "Helper not installed").localized)
                    .font(.caption)
                    .foregroundStyle(helperInstalled ? .green : .orange)
            }

            HStack {
                Button("Install Helper".localized) { installHelper() }
                Button("Uninstall Helper".localized) { uninstallHelper() }
                    .disabled(!helperInstalled)
            }
        }
    }

    private func browseForTun2socks() {
        if let path = chooseFile() {
            tun2socksPath = path
            TunManager.shared.tun2socksPath = path
        }
    }

    private func downloadTun2socks() {
        isDownloadingTun2socks = true
        tun2socksDownloadProgress = 0
        Task {
            do {
                let result = try await Tun2socksDownloader.installLatest { fraction in
                    Task { @MainActor in tun2socksDownloadProgress = fraction }
                }
                await MainActor.run {
                    tun2socksPath = result.path
                    TunManager.shared.tun2socksPath = result.path
                    appState.infoMessage = "Installed tun2socks %@".localized(result.version)
                    isDownloadingTun2socks = false
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    isDownloadingTun2socks = false
                }
            }
        }
    }

    private func installHelper() {
        HelperClient.shared.installHelper { ok, msg in
            DispatchQueue.main.async {
                helperInstalled = HelperClient.shared.isHelperInstalled
                appState.errorMessage = ok ? "Helper installed successfully.".localized : msg
            }
        }
    }

    private func uninstallHelper() {
        HelperClient.shared.uninstallHelper { ok, msg in
            DispatchQueue.main.async {
                helperInstalled = HelperClient.shared.isHelperInstalled
                appState.errorMessage = ok ? "Helper uninstalled successfully.".localized : msg
            }
        }
    }

    // MARK: - System

    private var systemSection: some View {
        Section("System".localized) {
            Toggle("Launch at Login".localized, isOn: $launchAtLogin)
                .disabled(!LaunchAtLogin.isAvailable)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        try LaunchAtLogin.apply(newValue)
                    } catch {
                        // Surface the real reason (e.g. the item still requires
                        // approval in System Settings) instead of a generic message.
                        appState.errorMessage = error.localizedDescription
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }

            Picker("Language".localized, selection: $appState.appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Picker("Appearance".localized, selection: $appState.appTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName.localized).tag(theme)
                }
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section("Updates".localized) {
            HStack {
                Button("Check for Updates".localized) { checkForUpdates() }
                    .disabled(isCheckingUpdate)
                if isCheckingUpdate {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("Current version".localized + ": " + appVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checkForUpdates() {
        isCheckingUpdate = true
        Task {
            do {
                let release = try await UpdateChecker.latestRelease(owner: "XTLS", repo: "Xray-core")
                await MainActor.run {
                    appState.infoMessage = "Latest Xray-core: %@".localized(release.tagName)
                    isCheckingUpdate = false
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                    isCheckingUpdate = false
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About".localized) {
            HStack {
                Text(appName)
                    .font(.headline)
                Spacer()
                Text(appVersion)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Link("Xray-core on GitHub".localized,
                 destination: URL(string: "https://github.com/XTLS/Xray-core")!)
        }
    }

    // MARK: - Bundle info

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "XrayGUI"
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: - File picker

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.unixExecutable, .executable, .item]
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
