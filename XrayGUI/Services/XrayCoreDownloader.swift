import Foundation

/// Downloads the official Xray-core binary from GitHub releases for the host
/// architecture, unzips it, and installs the `xray` executable (plus the bundled
/// `geoip.dat` / `geosite.dat`) into Application Support so the app can run it
/// without the user manually locating a binary.
///
/// The flow is: resolve the latest release via ``UpdateChecker``, pick the macOS
/// asset that matches the running CPU, stream it to a temp file with progress
/// reporting, expand it with `/usr/bin/unzip`, then atomically swap the binary
/// into `~/Library/Application Support/XrayGUI/xray` and mark it executable.
enum XrayCoreDownloader {

    // MARK: - Public model

    /// The result of a successful install.
    struct InstallResult: Equatable {
        /// The release tag that was installed (e.g. "v1.8.24").
        let version: String
        /// Absolute path to the installed `xray` executable.
        let path: String
    }

    /// Errors surfaced by the download/install flow.
    enum DownloadError: Error, LocalizedError {
        /// No release asset matched the host architecture.
        case noMatchingAsset
        /// `/usr/bin/unzip` exited non-zero.
        case unzipFailed(String)
        /// The archive did not contain an `xray` executable.
        case binaryMissing
        /// Every source (official host + mirrors) failed to deliver a valid archive.
        case allSourcesFailed(String)

        var errorDescription: String? {
            switch self {
            case .noMatchingAsset:
                return "No Xray-core download is available for this Mac.".localized
            case .unzipFailed(let detail):
                let prefix = "Failed to extract the downloaded archive.".localized
                return detail.isEmpty ? prefix : "\(prefix)\n\(detail)"
            case .binaryMissing:
                return "The downloaded archive did not contain an xray binary.".localized
            case .allSourcesFailed(let detail):
                let prefix = "Download failed from GitHub and all mirrors.".localized
                return detail.isEmpty ? prefix : "\(prefix)\n\(detail)"
            }
        }
    }

    // MARK: - API

    /// Downloads and installs the latest Xray-core release for this Mac.
    ///
    /// - Parameter progress: Called on an arbitrary background queue with the
    ///   download completion fraction (0...1). Marshal to the main actor in the UI.
    /// - Returns: The installed version and binary path.
    static func installLatest(owner: String = "XTLS",
                              repo: String = "Xray-core",
                              progress: @escaping (Double) -> Void) async throws -> InstallResult {
        let resolved = try await resolveDownload(owner: owner, repo: repo)
        let zipURL = try await downloadWithFallback(resolved.url, progress: progress)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let binaryPath = try unzipAndInstall(zip: zipURL)
        return InstallResult(version: resolved.version, path: binaryPath)
    }

    // MARK: - Mirror fallback

    /// GitHub acceleration mirrors, tried in order when the official host is
    /// unreachable (e.g. from networks where github.com is blocked). Each entry is a
    /// ghproxy-style URL prefix: the full https GitHub URL is appended verbatim, e.g.
    /// `https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download/...`.
    static let mirrors = [
        "https://ghfast.top/",
        "https://mirror.ghproxy.com/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    ]

    /// The version tag plus the canonical (un-mirrored) github.com asset URL to fetch.
    private struct ResolvedDownload {
        let version: String
        let url: URL
    }

    /// Resolves which version and asset URL to download. Prefers the GitHub API
    /// (gives the real asset list); if that fails — typically because api.github.com
    /// is blocked — falls back to reading the latest tag from the `releases/latest`
    /// redirect (through a mirror if needed) and building the asset URL from
    /// Xray-core's stable naming convention.
    private static func resolveDownload(owner: String, repo: String) async throws -> ResolvedDownload {
        if let release = try? await UpdateChecker.latestRelease(owner: owner, repo: repo),
           let asset = selectAsset(from: release.assets) {
            return ResolvedDownload(version: release.tagName, url: asset.downloadURL)
        }
        let tag = try await resolveLatestTag(owner: owner, repo: repo)
        let asset = assetNameForHost()
        guard let url = URL(string:
            "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(asset)") else {
            throw DownloadError.noMatchingAsset
        }
        return ResolvedDownload(version: tag, url: url)
    }

    /// The Xray-core release asset file name for the host architecture.
    private static func assetNameForHost() -> String {
        isAppleSilicon ? "Xray-macos-arm64-v8a.zip" : "Xray-macos-64.zip"
    }

    /// Resolves the latest release tag by following the `releases/latest` redirect,
    /// trying the official host first and then each mirror.
    private static func resolveLatestTag(owner: String, repo: String) async throws -> String {
        let latest = "https://github.com/\(owner)/\(repo)/releases/latest"
        for base in [latest] + mirrors.map({ $0 + latest }) {
            guard let url = URL(string: base) else { continue }
            if let tag = try? await tagFromRedirect(url), !tag.isEmpty { return tag }
        }
        throw DownloadError.allSourcesFailed("")
    }

    /// Reads the release tag from the final (redirected) URL of a `releases/latest`
    /// request, e.g. `.../releases/tag/v1.8.24` → `v1.8.24`. Returns nil if the
    /// request did not redirect to a concrete tag.
    private static func tagFromRedirect(_ url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.setValue("XrayGUI", forHTTPHeaderField: "User-Agent")
        // Always resolve against the live "latest" redirect, never a cached one.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        guard let last = response.url?.lastPathComponent, last != "latest" else { return nil }
        return last
    }

    /// Downloads the asset, trying the canonical URL first and then each mirror
    /// prefix. A response is accepted only if the file begins with the ZIP magic
    /// bytes, so mirror error pages (served with HTTP 200) trigger the next fallback
    /// instead of being mistaken for a valid archive. Progress resets at each attempt.
    private static func downloadWithFallback(_ url: URL,
                                             progress: @escaping (Double) -> Void) async throws -> URL {
        var candidates = [url]
        candidates.append(contentsOf: mirrors.compactMap { URL(string: $0 + url.absoluteString) })

        var lastError: Error?
        for candidate in candidates {
            do {
                progress(0)
                let file = try await download(candidate, progress: progress)
                if (try? isZipArchive(file)) == true {
                    return file
                }
                try? FileManager.default.removeItem(at: file)
                lastError = DownloadError.unzipFailed("")
            } catch {
                lastError = error
            }
        }
        throw DownloadError.allSourcesFailed(lastError?.localizedDescription ?? "")
    }

    /// Whether the file starts with the local-file-header ZIP magic ("PK\u{03}\u{04}").
    private static func isZipArchive(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 2)
        return magic == Data([0x50, 0x4B])
    }

    // MARK: - Asset selection

    /// Whether this Mac has Apple Silicon hardware, regardless of whether the app
    /// itself is running translated under Rosetta. Used to prefer the native build.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    /// Picks the macOS `.zip` asset matching the host architecture. Xray-core names
    /// these `Xray-macos-arm64-v8a.zip` and `Xray-macos-64.zip`. Falls back to the
    /// Intel build on Apple Silicon (runs via Rosetta) if no arm64 asset is present.
    static func selectAsset(from assets: [UpdateChecker.Asset]) -> UpdateChecker.Asset? {
        let macAssets = assets.filter {
            let lower = $0.name.lowercased()
            return lower.contains("macos") && lower.hasSuffix(".zip")
        }
        let arm = macAssets.first { $0.name.lowercased().contains("arm64") }
        let intel = macAssets.first { $0.name.lowercased().contains("macos-64") }
        return isAppleSilicon ? (arm ?? intel) : intel
    }

    // MARK: - Download

    /// Streams a URL to a stable temp file, reporting progress. The caller owns the
    /// returned file and is responsible for deleting it.
    private static func download(_ url: URL,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("XrayGUI", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: - Install

    /// Expands the archive and installs `xray` (and geo data, if present) into
    /// Application Support. Returns the absolute path to the installed binary.
    private static func unzipAndInstall(zip: URL) throws -> String {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory
            .appendingPathComponent("xray-core-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zip.path, "-d", extractDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DownloadError.unzipFailed(detail)
        }

        // The binary sits at the archive root; locate it defensively in case the
        // layout ever nests it under a folder.
        guard let extractedBinary = locateBinary(named: "xray", under: extractDir) else {
            throw DownloadError.binaryMissing
        }

        let destDir = try applicationSupportDir()
        let destBinary = destDir.appendingPathComponent("xray")

        if fm.fileExists(atPath: destBinary.path) {
            try fm.removeItem(at: destBinary)
        }
        try fm.moveItem(at: extractedBinary, to: destBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBinary.path)
        stripQuarantine(at: destBinary.path)

        // Move the geo data next to the binary if the release bundled it.
        let geoParent = extractedBinary.deletingLastPathComponent()
        for geo in ["geoip.dat", "geosite.dat"] {
            let src = geoParent.appendingPathComponent(geo)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destDir.appendingPathComponent(geo)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try? fm.moveItem(at: src, to: dst)
        }

        return destBinary.path
    }

    /// The app's Application Support directory (`.../XrayGUI`), created on demand.
    private static func applicationSupportDir() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("XrayGUI", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Finds a file with the given name anywhere under `root` (root first).
    private static func locateBinary(named name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    /// Best-effort removal of the quarantine xattr so the freshly downloaded binary
    /// can be exec'd without a Gatekeeper prompt. Harmless if the attribute is absent.
    private static func stripQuarantine(at path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-d", "com.apple.quarantine", path]
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}

// MARK: - Download delegate

/// Bridges `URLSessionDownloadTask` progress + completion into an async
/// continuation. A fresh instance is used per download.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is removed once this method returns, so move it somewhere stable.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray-core-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return } // success already handled in didFinishDownloadingTo
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
