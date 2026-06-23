import Foundation

/// Queries the GitHub Releases API to discover newer versions of the XrayGUI app
/// itself and of bundled Xray-core, and exposes a semantic-version comparison helper.
///
/// This is a pure networking service: it performs an async HTTP GET against the
/// public GitHub REST API and decodes the `releases/latest` payload into a small,
/// UI-agnostic `Release` value. No authentication is used, so callers are subject
/// to GitHub's unauthenticated rate limits.
enum UpdateChecker {

    // MARK: - Public model

    /// A downloadable artifact attached to a release.
    struct Asset: Equatable {
        /// The asset file name (e.g. "XrayGUI-1.2.0.dmg").
        let name: String
        /// Direct browser download URL for the asset.
        let downloadURL: URL
    }

    /// A normalized GitHub release.
    struct Release: Equatable {
        /// The git tag of the release (e.g. "v1.2.0").
        let tagName: String
        /// The human-readable release title.
        let name: String
        /// The release notes / changelog body (Markdown).
        let body: String
        /// The release page on github.com.
        let htmlURL: URL
        /// All attached downloadable assets.
        let assets: [Asset]
        /// Whether GitHub flags this as a pre-release.
        let prerelease: Bool
        /// When the release was published, if available.
        let publishedAt: Date?
    }

    /// Errors surfaced by the update check.
    enum UpdateError: Error, LocalizedError {
        /// The server responded with a non-2xx status or an unexpected response type.
        case badResponse
        /// The response body could not be decoded into a `Release`.
        case decoding

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "The update server returned an unexpected response."
            case .decoding:
                return "The update information could not be read."
            }
        }
    }

    // MARK: - API

    /// Fetches the latest published release for the given repository.
    ///
    /// - Parameters:
    ///   - owner: The GitHub owner/org (e.g. "XTLS").
    ///   - repo: The repository name (e.g. "Xray-core").
    /// - Returns: The decoded `Release`.
    /// - Throws: `UpdateError.badResponse` on a non-2xx status, `UpdateError.decoding`
    ///   on a malformed body, or the underlying `URLSession` error on transport failure.
    static func latestRelease(owner: String, repo: String) async throws -> Release {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/releases/latest"

        guard let url = components.url else {
            throw UpdateError.badResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Always hit the network so "Check for Updates" never returns a stale release.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("XrayGUI", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }

        let decoder = JSONDecoder()
        let payload: ReleasePayload
        do {
            payload = try decoder.decode(ReleasePayload.self, from: data)
        } catch {
            throw UpdateError.decoding
        }

        return payload.normalized()
    }

    /// Compares two version strings and reports whether `remote` is strictly newer
    /// than `local`.
    ///
    /// A leading "v"/"V" is stripped, the string is split on ".", and each component
    /// is compared numerically left-to-right. Missing trailing components are treated
    /// as 0, and any non-numeric suffix (e.g. "-beta", "rc1") is ignored by parsing
    /// the leading integer of each component.
    ///
    /// - Returns: `true` only when `remote` is strictly greater than `local`.
    static func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let remoteParts = versionComponents(remote)
        let localParts = versionComponents(local)
        let count = max(remoteParts.count, localParts.count)

        for index in 0 ..< count {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let l = index < localParts.count ? localParts[index] : 0
            if r != l {
                return r > l
            }
        }
        return false
    }

    // MARK: - Private helpers

    /// Splits a version string into numeric components, stripping a leading "v"/"V"
    /// and reducing each dot-separated component to its leading integer.
    private static func versionComponents(_ version: String) -> [Int] {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }
        return trimmed.split(separator: ".", omittingEmptySubsequences: false).map { component in
            leadingInteger(of: component)
        }
    }

    /// Parses the leading run of digits of a component, ignoring any non-numeric
    /// suffix such as "-beta" or "rc1". Returns 0 when no leading digit is present.
    private static func leadingInteger(of component: Substring) -> Int {
        var value = 0
        var sawDigit = false
        for character in component {
            guard let digit = character.wholeNumberValue, character.isNumber else { break }
            sawDigit = true
            value = value * 10 + digit
        }
        return sawDigit ? value : 0
    }

    // MARK: - Wire model

    /// Internal Codable mirror of the GitHub `releases/latest` JSON payload.
    private struct ReleasePayload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let assets: [AssetPayload]
        let prerelease: Bool
        let publishedAt: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case assets
            case prerelease
            case publishedAt = "published_at"
        }

        func normalized() -> Release {
            Release(
                tagName: tagName,
                name: name ?? tagName,
                body: body ?? "",
                htmlURL: htmlURL,
                assets: assets.map { Asset(name: $0.name, downloadURL: $0.browserDownloadURL) },
                prerelease: prerelease,
                publishedAt: publishedAt.flatMap(Self.parseDate)
            )
        }

        /// Parses an ISO8601 timestamp as returned by the GitHub API, tolerating both
        /// plain (`...Z`) and fractional-seconds variants.
        private static func parseDate(_ string: String) -> Date? {
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string)
        }
    }

    /// Internal Codable mirror of a release asset.
    private struct AssetPayload: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
