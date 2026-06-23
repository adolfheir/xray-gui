import Foundation

/// Generates the cryptographic material needed for a REALITY-secured outbound.
///
/// The X25519 keypair is produced by shelling out to `xray x25519`, because that is the
/// canonical implementation and stays in lockstep with whatever Xray-core build the user
/// has installed (different versions have shipped slightly different output formatting,
/// which `parseKeypair` tolerates). Only the public key is ever stored on a `ProxyNode`;
/// the private key is the *server* secret and is merely surfaced to the user for copying.
///
/// The shortId is generated locally — it is just a random hex string, so there is no need
/// to spawn a process for it.
enum RealityKeygen {
    /// Run `xray x25519` and return the parsed keypair.
    ///
    /// - Throws: `KeygenError.binaryMissing` when the configured xray binary is absent,
    ///   `KeygenError.launchFailed` when the process cannot be started, and
    ///   `KeygenError.parseFailed` when the output does not contain both keys.
    static func generateKeypair() throws -> (privateKey: String, publicKey: String) {
        let path = XrayCoreManager.shared.xrayBinaryPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw KeygenError.binaryMissing
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["x25519"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            throw KeygenError.launchFailed(error.localizedDescription)
        }
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let pair = parseKeypair(output) else {
            throw KeygenError.parseFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pair
    }

    /// Scan `xray x25519` output line by line. Different versions print the keys as
    /// `Private key: …` / `Public key: …` or `PrivateKey: …` / `PublicKey: …`, so we match
    /// loosely on the substrings "rivate" / "ublic" and take everything after the colon.
    static func parseKeypair(_ output: String) -> (privateKey: String, publicKey: String)? {
        var privateKey: String?
        var publicKey: String?
        for line in output.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if line.contains("rivate") {
                privateKey = value
            } else if line.contains("ublic") {
                publicKey = value
            }
        }
        guard let priv = privateKey, let pub = publicKey else { return nil }
        return (priv, pub)
    }

    /// Generate a random 8-byte (16 hex character) shortId for REALITY.
    static func generateShortId() -> String {
        (0 ..< 8).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }

    enum KeygenError: Error, LocalizedError {
        case binaryMissing
        case launchFailed(String)
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "Xray binary not found. Please set the path in Settings.".localized
            case .launchFailed(let msg):
                return "Failed to run xray x25519: %@".localized(msg)
            case .parseFailed(let out):
                return "Could not parse keypair from xray output: %@".localized(out)
            }
        }
    }
}
