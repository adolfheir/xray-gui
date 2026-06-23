import Foundation

/// Traffic / expiry metadata extracted from the `subscription-userinfo` response header.
///
/// Most panels (V2Board, SSPanel, etc.) emit a header such as
/// `subscription-userinfo: upload=1234; download=5678; total=10737418240; expire=1700000000`.
/// All fields are optional because a given panel may only emit a subset.
struct SubscriptionUserInfo: Equatable {
    /// Bytes uploaded, as reported by the panel.
    var upload: Int64?
    /// Bytes downloaded, as reported by the panel.
    var download: Int64?
    /// Total quota in bytes.
    var total: Int64?
    /// Expiry instant (decoded from a Unix timestamp in seconds).
    var expire: Date?
}

/// Fetches a remote subscription URL and turns its body into normalized `ProxyNode`s.
///
/// The flow mirrors what every Xray/V2Ray client does:
/// 1. GET the URL with a panel-friendly `User-Agent` (some panels gate content on it).
/// 2. Treat the body as a Base64 (or raw) blob of newline-separated share links and
///    hand it to `ShareLinkParser.parseSubscription(_:)`.
/// 3. Stamp every parsed node with the originating `Subscription.id`.
/// 4. Parse the optional `subscription-userinfo` header for traffic / expiry display.
///
/// This is a pure networking + parsing service: it owns no UI state and is safe to call
/// from any async context.
final class SubscriptionManager {
    /// Shared singleton used throughout the app.
    static let shared = SubscriptionManager()

    /// Errors surfaced while fetching or decoding a subscription.
    enum SubError: Error, LocalizedError {
        /// `Subscription.url` could not be turned into a valid `URL`.
        case badURL
        /// The underlying network request failed (timeout, DNS, TLS, offline…).
        case transport(Error)
        /// The server responded with a non-2xx HTTP status.
        case httpStatus(Int)
        /// The body could not be decoded as UTF-8.
        case undecodable
        /// The response decoded successfully but yielded zero usable nodes.
        case empty

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "The subscription URL is invalid."
            case .transport(let error):
                return "Could not reach the subscription server: \(error.localizedDescription)"
            case .httpStatus(let code):
                return "The subscription server returned HTTP \(code)."
            case .undecodable:
                return "The subscription response could not be decoded as text."
            case .empty:
                return "The subscription contained no valid proxy nodes."
            }
        }
    }

    /// Default User-Agent used when a subscription does not specify its own.
    private static let defaultUserAgent = "XrayGUI/1.0"

    /// Request timeout in seconds.
    private static let requestTimeout: TimeInterval = 20

    private let session: URLSession

    /// - Parameter session: Injectable for testing; defaults to a non-caching ephemeral session.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = SubscriptionManager.requestTimeout
            config.timeoutIntervalForResource = SubscriptionManager.requestTimeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches the subscription, parses its body into nodes, and extracts traffic metadata.
    ///
    /// - Parameter subscription: The subscription to refresh.
    /// - Returns: The parsed `nodes` (each stamped with `subscription.id`) and, when the
    ///   `subscription-userinfo` header is present, the decoded `userInfo`.
    /// - Throws: `SubError.badURL` if the URL is malformed, `SubError.badResponse` on a
    ///   non-2xx status or undecodable body, and `SubError.empty` if no nodes were parsed.
    func fetch(_ subscription: Subscription) async throws -> (nodes: [ProxyNode], userInfo: SubscriptionUserInfo?) {
        guard let url = URL(string: subscription.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SubError.badURL
        }

        var request = URLRequest(url: url, timeoutInterval: SubscriptionManager.requestTimeout)
        request.httpMethod = "GET"
        request.setValue(subscription.userAgent ?? SubscriptionManager.defaultUserAgent,
                         forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SubError.httpStatus(0)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SubError.httpStatus(http.statusCode)
        }

        guard let body = String(data: data, encoding: .utf8) else {
            throw SubError.undecodable
        }

        var nodes = ShareLinkParser.parseSubscription(body)
        guard !nodes.isEmpty else {
            throw SubError.empty
        }

        for index in nodes.indices {
            nodes[index].subscriptionId = subscription.id
        }

        let userInfo = SubscriptionManager.parseUserInfoHeader(from: http)
        return (nodes, userInfo)
    }

    // MARK: - Header parsing

    /// Reads the `subscription-userinfo` header (case-insensitively) and decodes it.
    private static func parseUserInfoHeader(from response: HTTPURLResponse) -> SubscriptionUserInfo? {
        let raw: String?
        if #available(macOS 13.0, *) {
            raw = response.value(forHTTPHeaderField: "subscription-userinfo")
        } else {
            raw = response.allHeaderFields.first { key, _ in
                (key as? String)?.caseInsensitiveCompare("subscription-userinfo") == .orderedSame
            }?.value as? String
        }
        guard let raw, !raw.isEmpty else { return nil }
        return decodeUserInfo(raw)
    }

    /// Decodes a `subscription-userinfo` value such as
    /// `upload=123; download=456; total=789; expire=1700000000`.
    ///
    /// Returns `nil` when none of the recognised keys are present.
    static func decodeUserInfo(_ value: String) -> SubscriptionUserInfo? {
        var info = SubscriptionUserInfo()
        var matchedAny = false

        // Fields are separated by ';' (commonly) but some panels use ','.
        let separators = CharacterSet(charactersIn: ";,")
        for component in value.components(separatedBy: separators) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = pair[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "upload":
                if let n = Int64(rawValue) { info.upload = n; matchedAny = true }
            case "download":
                if let n = Int64(rawValue) { info.download = n; matchedAny = true }
            case "total":
                if let n = Int64(rawValue) { info.total = n; matchedAny = true }
            case "expire":
                // Unix timestamp in seconds; 0 / empty means "no expiry".
                if let seconds = Double(rawValue), seconds > 0 {
                    info.expire = Date(timeIntervalSince1970: seconds)
                    matchedAny = true
                }
            default:
                continue
            }
        }

        return matchedAny ? info : nil
    }
}
