import AppKit
import SwiftUI

/// A modal sheet for manually creating or editing a single `ProxyNode`.
///
/// Fields are grouped (basics / credentials / transport / security) and shown
/// conditionally on the selected protocol, transport and security so the form only ever
/// exposes options relevant to the current node. The REALITY section can generate an
/// X25519 keypair via `RealityKeygen`; the resulting private key (a *server* secret that
/// is never persisted on the node) is surfaced in a copyable area for the user.
struct NodeEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Working copy. Mutations are only committed to `AppState` on Save.
    @State private var draft: ProxyNode
    /// Whether we are editing an existing node (vs. creating a new one).
    private let isEditing: Bool

    @State private var errorText: String?
    /// Last generated REALITY private key, shown for copying. Never stored on the node.
    @State private var generatedPrivateKey: String?

    init(node: ProxyNode?) {
        if let node {
            _draft = State(initialValue: node)
            isEditing = true
        } else {
            var fresh = ProxyNode(name: "", protocolType: .vless, address: "", port: 443)
            fresh.security = "reality"
            fresh.encryption = "none"
            _draft = State(initialValue: fresh)
            isEditing = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                basicsSection
                credentialsSection
                transportSection
                securitySection
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 480, height: 560)
    }

    // MARK: - Basics

    private var basicsSection: some View {
        Section("Basics".localized) {
            TextField("Name".localized, text: $draft.name)
            Picker("Protocol".localized, selection: $draft.protocolType) {
                ForEach(ProxyProtocol.allCases.filter(\.isSupportedByXray), id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
            TextField("Address".localized, text: $draft.address)
            HStack {
                Text("Port".localized)
                Spacer()
                TextField("", value: $draft.port, formatter: Self.portFormatter)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Stepper("", value: $draft.port, in: 1 ... 65535).labelsHidden()
            }
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section("Credentials".localized) {
            switch draft.protocolType {
            case .vmess:
                optionalField("UUID".localized, $draft.userId)
                HStack {
                    Text("Alter ID".localized)
                    Spacer()
                    TextField("", value: alterIdBinding, formatter: Self.alterIdFormatter)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                picker("Encryption".localized, optional: $draft.encryption,
                       options: ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"])
            case .vless:
                optionalField("UUID".localized, $draft.userId)
                picker("Encryption".localized, optional: $draft.encryption,
                       options: ["none"])
                picker("Flow".localized, optional: $draft.flow,
                       options: ["", "xtls-rprx-vision", "xtls-rprx-vision-udp443"])
            case .trojan:
                optionalField("Password".localized, $draft.password)
                picker("Flow".localized, optional: $draft.flow,
                       options: ["", "xtls-rprx-vision", "xtls-rprx-vision-udp443"])
            case .shadowsocks:
                optionalField("Password".localized, $draft.password)
                picker("Method".localized, optional: $draft.method,
                       options: ["aes-256-gcm", "aes-128-gcm", "chacha20-ietf-poly1305",
                                 "2022-blake3-aes-256-gcm", "2022-blake3-aes-128-gcm", "none"])
            case .socks, .http:
                optionalField("Username".localized, $draft.userId)
                optionalField("Password".localized, $draft.password)
            default:
                Text("This protocol has no editable credentials.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transport

    private var transportSection: some View {
        Section("Transport".localized) {
            Picker("Network".localized, selection: $draft.network) {
                ForEach(["tcp", "ws", "grpc", "http", "quic", "kcp", "httpupgrade", "xhttp"], id: \.self) { net in
                    Text(net).tag(net)
                }
            }

            switch draft.network {
            case "ws", "http", "httpupgrade":
                optionalField("Path".localized, $draft.path)
                optionalField("Host".localized, $draft.host)
            case "grpc":
                optionalField("Service Name".localized, $draft.serviceName)
                picker("gRPC Mode".localized, optional: $draft.grpcMode, options: ["gun", "multi"])
            case "xhttp":
                optionalField("Path".localized, $draft.path)
                optionalField("Host".localized, $draft.host)
                picker("Mode".localized, optional: $draft.grpcMode, options: ["", "auto", "packet-up", "stream-up"])
            case "kcp":
                optionalField("Header Type".localized, $draft.headerType)
                optionalField("Seed".localized, $draft.seed)
            case "quic":
                optionalField("Header Type".localized, $draft.headerType)
                optionalField("QUIC Security".localized, $draft.quicSecurity)
                optionalField("QUIC Key".localized, $draft.quicKey)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section("Security".localized) {
            Picker("Security".localized, selection: $draft.security) {
                ForEach(["none", "tls", "reality", "xtls"], id: \.self) { sec in
                    Text(sec).tag(sec)
                }
            }

            switch draft.security {
            case "tls", "xtls":
                optionalField("SNI".localized, $draft.sni)
                optionalField("ALPN".localized, $draft.alpn)
                fingerprintPicker
                Toggle("Allow Insecure".localized, isOn: $draft.allowInsecure)
            case "reality":
                optionalField("SNI (Server Name)".localized, $draft.sni)
                HStack(spacing: 8) {
                    TextField("Public Key".localized, text: stringBinding($draft.publicKey))
                        .textFieldStyle(.roundedBorder)
                    Button("Generate Keypair".localized) { generateKeypair() }
                }
                optionalField("Short ID".localized, $draft.shortId)
                optionalField("SpiderX".localized, $draft.spiderX)
                fingerprintPicker
                if let generatedPrivateKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Private key (configure on your server — not stored here):".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(generatedPrivateKey)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            IconButton("doc.on.clipboard", tooltip: "Copy".localized) {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(generatedPrivateKey, forType: .string)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private var fingerprintPicker: some View {
        picker("Fingerprint".localized, optional: $draft.fingerprint,
               options: ["", "chrome", "firefox", "safari", "randomized", "ios", "edge"])
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel".localized) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save".localized : "Add".localized) { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func generateKeypair() {
        do {
            let pair = try RealityKeygen.generateKeypair()
            draft.publicKey = pair.publicKey
            generatedPrivateKey = pair.privateKey
            if (draft.shortId ?? "").isEmpty {
                draft.shortId = RealityKeygen.generateShortId()
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() {
        let trimmedAddress = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            errorText = "Address is required.".localized
            return
        }
        guard draft.port >= 1, draft.port <= 65535 else {
            errorText = "Port must be between 1 and 65535.".localized
            return
        }
        draft.address = trimmedAddress
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.name = trimmedName.isEmpty ? "\(trimmedAddress):\(draft.port)" : trimmedName

        if isEditing {
            appState.updateNode(draft)
        } else {
            appState.addNode(draft)
        }
        dismiss()
    }

    // MARK: - Binding helpers

    /// A text-field binding over an optional String; empty input maps back to nil.
    private func stringBinding(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private var alterIdBinding: Binding<Int> {
        Binding(
            get: { draft.alterId ?? 0 },
            set: { draft.alterId = $0 }
        )
    }

    private func optionalField(_ label: String, _ source: Binding<String?>) -> some View {
        TextField(label, text: stringBinding(source))
    }

    /// A picker over an optional String field. The empty option ("") maps to nil.
    private func picker(_ label: String, optional source: Binding<String?>, options: [String]) -> some View {
        Picker(label, selection: Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )) {
            ForEach(options, id: \.self) { opt in
                Text(opt.isEmpty ? "(none)".localized : opt).tag(opt)
            }
        }
    }

    // MARK: - Formatters

    private static let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65535
        f.allowsFloats = false
        return f
    }()

    private static let alterIdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 65535
        f.allowsFloats = false
        return f
    }()
}
