import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var xrayPath = UserDefaults.standard.string(forKey: "xrayBinaryPath") ?? ""
    @State private var httpPort = UserDefaults.standard.integer(forKey: "httpProxyPort").nonZero ?? 10809
    @State private var socksPort = UserDefaults.standard.integer(forKey: "socksProxyPort").nonZero ?? 10808
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Xray Core") {
                HStack {
                    TextField("Path to xray binary", text: $xrayPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") { browseBinary() }
                    Button("Test") { testBinary() }
                }
                .onChange(of: xrayPath) { new in
                    UserDefaults.standard.set(new, forKey: "xrayBinaryPath")
                    XrayCoreManager.shared.xrayBinaryPath = new
                }

                if !xrayPath.isEmpty {
                    if FileManager.default.fileExists(atPath: xrayPath) {
                        Label("Binary found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Binary not found at this path", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            Section("System Proxy Ports") {
                HStack {
                    Text("HTTP Proxy Port")
                    Spacer()
                    TextField("Port", value: $httpPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: httpPort) { new in
                            UserDefaults.standard.set(new, forKey: "httpProxyPort")
                            SystemProxyManager.shared.httpPort = new
                        }
                }
                HStack {
                    Text("SOCKS5 Proxy Port")
                    Spacer()
                    TextField("Port", value: $socksPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: socksPort) { new in
                            UserDefaults.standard.set(new, forKey: "socksProxyPort")
                            SystemProxyManager.shared.socksPort = new
                        }
                }
                Text("Make sure these match your Xray config's inbound ports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("TUN Mode") {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Privileged Helper", systemImage: "lock.shield")
                            .font(.subheadline.bold())
                        Text("TUN mode requires the privileged helper to create and manage the TUN interface. Sign the app and helper, then install the helper.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Install Helper") {
                            HelperClient.shared.installHelper { ok, msg in
                                Task { @MainActor in
                                    appState.errorMessage = ok ? "Helper installed successfully." : msg
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("System") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { new in setLaunchAtLogin(new) }
            }

            Section("About") {
                HStack {
                    Text("XrayGUI")
                    Spacer()
                    Text("0.1.0")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Xray Core")
                    Spacer()
                    Text(xrayVersion())
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Link("GitHub: XTLS/Xray-core", destination: URL(string: "https://github.com/XTLS/Xray-core")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            xrayPath = UserDefaults.standard.string(forKey: "xrayBinaryPath") ?? ""
            httpPort = UserDefaults.standard.integer(forKey: "httpProxyPort").nonZero ?? 10809
            socksPort = UserDefaults.standard.integer(forKey: "socksProxyPort").nonZero ?? 10808
        }
    }

    private func browseBinary() {
        let panel = NSOpenPanel()
        panel.title = "Select Xray Binary"
        panel.message = "Choose the xray executable"
        if panel.runModal() == .OK, let url = panel.url {
            xrayPath = url.path
        }
    }

    private func testBinary() {
        guard FileManager.default.fileExists(atPath: xrayPath) else {
            appState.errorMessage = "Binary not found at: \(xrayPath)"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: xrayPath)
        p.arguments = ["version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "No output"
        appState.errorMessage = output
    }

    private func xrayVersion() -> String {
        guard !xrayPath.isEmpty, FileManager.default.fileExists(atPath: xrayPath) else { return "Not configured" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: xrayPath)
        p.arguments = ["version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Use SMAppService (macOS 13+) for launch at login.
        // Requires a LoginItems entry in the app bundle or a helper launcher target.
        // Left as TODO until the app is signed and distributed.
    }
}
