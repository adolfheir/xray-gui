import Foundation

/// Downloads the tun2socks binary (xjasonlyu/tun2socks) from GitHub releases for the
/// host architecture, unzips it, and installs the executable into Application Support
/// as `tun2socks` so TUN mode can route through it without the user manually locating
/// a binary.
///
/// Mirrors ``XrayCoreDownloader``'s flow — API-or-redirect release resolution, mirror
/// fallback for networks where github.com is blocked, a streamed download with progress
/// reporting, and `/usr/bin/unzip` expansion — but targets tun2socks' asset naming and
/// installs a single binary (no bundled geo data).
enum Tun2socksDownloader {

    // MARK: - Public model

    /// The result of a successful install.
    struct InstallResult: Equatable {
        /// The release tag that was installed (e.g. "v2.6.0").
        let version: String
        /// Absolute path to the installed `tun2socks` executable.
        let path: String
    }

    /// Errors surfaced by the download/install flow.
    enum DownloadError: Error, LocalizedError {
        /// No release asset matched the host architecture.
        case noMatchingAsset
        /// `/usr/bin/unzip` exited non-zero.
        case unzipFailed(String)
        /// The archive did not contain a tun2socks executable.
        case binaryMissing
        /// Every source (official host + mirrors) failed to deliver a valid archive.
        case allSourcesFailed(String)

        var errorDescription: String? {
            switch self {
            case .noMatchingAsset:
                return "No tun2socks download is available for this Mac.".localized
            case .unzipFailed(let detail):
                let prefix = "Failed to extract the downloaded archive.".localized
                return detail.isEmpty ? prefix : "\(prefix)\n\(detail)"
            case .binaryMissing:
                return "The downloaded archive did not contain a tun2socks binary.".localized
            case .allSourcesFailed(let detail):
                let prefix = "Download failed from GitHub and all mirrors.".localized
                return detail.isEmpty ? prefix : "\(prefix)\n\(detail)"
            }
        }
    }

    // MARK: - API

    /// Downloads and installs the latest tun2socks release for this Mac.
    ///
    /// - Parameter progress: Called on an arbitrary background queue with the download
    ///   completion fraction (0...1). Marshal to the main actor in the UI.
    /// - Returns: The installed version and binary path.
    static func installLatest(owner: String = "xjasonlyu",
                              repo: String = "tun2socks",
                              progress: @escaping (Double) -> Void) async throws -> InstallResult {
        let resolved = try await resolveDownload(owner: owner, repo: repo)
        let zipURL = try await downloadWithFallback(resolved.url, progress: progress)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let binaryPath = try unzipAndInstall(zip: zipURL)
        return InstallResult(version: resolved.version, path: binaryPath)
    }

    // MARK: - Mirror fallback

    /// GitHub acceleration mirrors, tried in order when the official host is
    /// unreachable. Each entry is a ghproxy-style URL prefix prepended to the full
    /// https GitHub URL.
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

    /// Resolves which version and asset URL to download. Prefers the GitHub API (gives
    /// the real asset list); if that fails — typically because api.github.com is
    /// blocked — falls back to reading the latest tag from the `releases/latest`
    /// redirect (through a mirror if needed) and building the asset URL from tun2socks'
    /// stable naming convention.
    private static func resolveDownload(owner: String, repo: String) async throws -> ResolvedDownload {
        if let release = try? await UpdateChecker.latestRelease(owner: owner, repo: repo),
           let asset = selectAsset(from: release.assets) {
            return ResolvedDownload(version: release.tagName, url: asset.downloadURL)
        }
        let tag = try await resolveLatestTag(owner: owner, repo: repo)
        guard let url = URL(string:
            "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(assetNameForHost())") else {
            throw DownloadError.noMatchingAsset
        }
        return ResolvedDownload(version: tag, url: url)
    }

    /// The tun2socks release asset file name for the host architecture.
    private static func assetNameForHost() -> String {
        isAppleSilicon ? "tun2socks-darwin-arm64.zip" : "tun2socks-darwin-amd64.zip"
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
    /// request, e.g. `.../releases/tag/v2.6.0` → `v2.6.0`.
    private static func tagFromRedirect(_ url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.setValue("XrayGUI", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        guard let last = response.url?.lastPathComponent, last != "latest" else { return nil }
        return last
    }

    /// Downloads the asset, trying the canonical URL first and then each mirror prefix.
    /// A response is accepted only if the file begins with the ZIP magic bytes, so
    /// mirror error pages (served with HTTP 200) trigger the next fallback instead of
    /// being mistaken for a valid archive. Progress resets at each attempt.
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

    /// Whether the file starts with the local-file-header ZIP magic ("PK").
    private static func isZipArchive(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 2)
        return magic == Data([0x50, 0x4B])
    }

    // MARK: - Asset selection

    /// Whether this Mac has Apple Silicon hardware, regardless of whether the app is
    /// running translated under Rosetta. Used to prefer the native build.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    /// Picks the macOS `.zip` asset matching the host architecture. tun2socks names
    /// these `tun2socks-darwin-arm64.zip` and `tun2socks-darwin-amd64.zip`. Falls back
    /// to the Intel build on Apple Silicon (runs via Rosetta) if no arm64 asset exists.
    static func selectAsset(from assets: [UpdateChecker.Asset]) -> UpdateChecker.Asset? {
        let macAssets = assets.filter {
            let lower = $0.name.lowercased()
            return lower.contains("darwin") && lower.hasSuffix(".zip")
        }
        let arm = macAssets.first { $0.name.lowercased().contains("arm64") }
        let intel = macAssets.first { $0.name.lowercased().contains("amd64") }
        return isAppleSilicon ? (arm ?? intel) : intel
    }

    // MARK: - Download

    /// Streams a URL to a stable temp file, reporting progress. The caller owns the
    /// returned file and is responsible for deleting it.
    private static func download(_ url: URL,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = Tun2socksDownloadDelegate(onProgress: progress)
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

    /// Expands the archive and installs the tun2socks binary into Application Support.
    /// Returns the absolute path to the installed binary.
    private static func unzipAndInstall(zip: URL) throws -> String {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory
            .appendingPathComponent("tun2socks-\(UUID().uuidString)", isDirectory: true)
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

        // The archive holds a single binary named `tun2socks-darwin-<arch>`; locate it
        // defensively in case the layout ever nests it under a folder.
        guard let extractedBinary = locateBinary(under: extractDir) else {
            throw DownloadError.binaryMissing
        }

        let destDir = try applicationSupportDir()
        // Normalise the installed name so the stored path is stable across versions.
        let destBinary = destDir.appendingPathComponent("tun2socks")

        if fm.fileExists(atPath: destBinary.path) {
            try fm.removeItem(at: destBinary)
        }
        try fm.moveItem(at: extractedBinary, to: destBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBinary.path)
        stripQuarantine(at: destBinary.path)

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

    /// Finds the tun2socks executable under `root`. The archive holds a single file
    /// whose name starts with `tun2socks`; match by prefix at the root first, then
    /// search recursively so a nested layout still resolves.
    private static func locateBinary(under root: URL) -> URL? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        if let direct = contents.first(where: { $0.lastPathComponent.hasPrefix("tun2socks") }) {
            return direct
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("tun2socks") {
            return url
        }
        return nil
    }

    /// Best-effort removal of the quarantine xattr so the freshly downloaded binary can
    /// be exec'd without a Gatekeeper prompt. Harmless if the attribute is absent.
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

/// Bridges `URLSessionDownloadTask` progress + completion into an async continuation.
/// A fresh instance is used per download.
private final class Tun2socksDownloadDelegate: NSObject, URLSessionDownloadDelegate {
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
            .appendingPathComponent("tun2socks-\(UUID().uuidString).zip")
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
