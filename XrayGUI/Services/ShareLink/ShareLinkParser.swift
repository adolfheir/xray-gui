import Foundation

/// Parses proxy *share links* (and whole subscriptions) into normalized ``ProxyNode`` values.
///
/// The parser is intentionally lenient: it accepts the many minor format variations
/// produced by Shadowrocket, v2rayN/v2rayNG, native Xray clients and Clash subscription
/// converters. It never throws and never crashes on malformed input — every failure path
/// returns `nil` (for a single link) or simply skips the offending line (for a subscription).
///
/// Supported URI schemes:
/// `vmess`, `vless`, `trojan`, `ss`, `ssr`, `socks`/`socks5`, `http`/`https`,
/// `hysteria2`/`hy2`, `tuic`.
///
/// Unsupported-by-Xray protocols (`ssr`, `hysteria2`, `tuic`) are still parsed and retained
/// so the user never silently loses a node.
enum ShareLinkParser {

    // MARK: - Public API

    /// Parse a single share link into a ``ProxyNode``.
    ///
    /// - Parameter link: A `scheme://…` share link, possibly URL-encoded and surrounded by whitespace.
    /// - Returns: A populated ``ProxyNode``, or `nil` if the link is empty, has an unknown scheme,
    ///   or is too malformed to extract a usable address/port.
    static func parse(_ link: String) -> ProxyNode? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[trimmed.startIndex..<schemeRange.lowerBound].lowercased()

        var node: ProxyNode?
        switch scheme {
        case "vmess":
            node = parseVMess(trimmed)
        case "vless":
            node = parseVLESS(trimmed)
        case "trojan":
            node = parseTrojan(trimmed)
        case "ss":
            node = parseShadowsocks(trimmed)
        case "ssr":
            node = parseSSR(trimmed)
        case "socks", "socks5":
            node = parseSocks(trimmed)
        case "http", "https":
            node = parseHTTP(trimmed, isTLS: scheme == "https")
        case "hysteria2", "hy2":
            node = parseHysteria2(trimmed)
        case "tuic":
            node = parseTUIC(trimmed)
        default:
            node = nil
        }

        node?.rawLink = trimmed
        return node
    }

    /// Decode a subscription payload into an array of ``ProxyNode``.
    ///
    /// The payload may be a single base64 blob (the common subscription format) or already-plaintext
    /// newline-separated links. This method first tries to base64-decode the whole trimmed input; if
    /// the decoded text yields at least one parseable link it is used, otherwise the raw input is treated
    /// as plaintext. Empty lines and pure comment lines (`#…`, `//…`) are dropped. Invalid links are
    /// skipped. Order is preserved and duplicates are **not** removed.
    ///
    /// - Parameter raw: The raw subscription text.
    /// - Returns: Every successfully parsed node, in source order.
    static func parseSubscription(_ raw: String) -> [ProxyNode] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Prefer a base64-decoded interpretation only if it actually produces parseable links.
        if let data = tolerantBase64Decode(trimmed),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty {
            let decodedNodes = splitAndParse(decoded)
            if !decodedNodes.isEmpty {
                return decodedNodes
            }
        }

        // Fall back to treating the raw input as plaintext.
        return splitAndParse(trimmed)
    }

    /// Decode base64 text tolerantly: accepts standard or URL-safe alphabets, with or without padding.
    ///
    /// - Parameter s: The (possibly whitespace-laden) base64 string.
    /// - Returns: The decoded bytes, or `nil` if the input is not valid base64 in any accepted form.
    ///   This deliberately does **not** fall back to raw UTF-8.
    static func tolerantBase64Decode(_ s: String) -> Data? {
        // Strip all whitespace/newlines that some sources interleave into base64 blobs.
        var cleaned = s.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleaned.isEmpty else { return nil }

        // Map URL-safe alphabet to standard.
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")

        // Pad to a multiple of 4.
        let remainder = cleaned.count % 4
        if remainder != 0 {
            cleaned.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
    }

    // MARK: - Subscription helpers

    /// Split a plaintext blob into lines and parse each, skipping blanks/comments/invalid entries.
    private static func splitAndParse(_ text: String) -> [ProxyNode] {
        var result: [ProxyNode] = []
        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if let node = parse(line) {
                result.append(node)
            }
        }
        return result
    }

    // MARK: - VMess

    /// Parse `vmess://` — base64 of a JSON object (v2rayN style). Legacy non-JSON forms return `nil`.
    private static func parseVMess(_ link: String) -> ProxyNode? {
        let body = stripScheme(link)
        guard let data = tolerantBase64Decode(body),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else {
            return nil
        }

        let address = stringValue(dict["add"]).trimmingCharacters(in: .whitespaces)
        guard let port = intValue(dict["port"]), !address.isEmpty else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(stringValue(dict["ps"]), fallback: "\(address):\(port)"),
            protocolType: .vmess,
            address: address,
            port: port
        )

        node.userId = nonEmptyOrNil(stringValue(dict["id"]))
        node.alterId = intValue(dict["aid"]) ?? 0
        node.encryption = nonEmptyOrNil(stringValue(dict["scy"])) ?? "auto"

        let net = nonEmptyOrNil(stringValue(dict["net"]))?.lowercased() ?? "tcp"
        node.network = net

        node.headerType = nonEmptyOrNil(stringValue(dict["type"]))
        node.host = nonEmptyOrNil(stringValue(dict["host"]))

        let path = nonEmptyOrNil(stringValue(dict["path"]))
        if net == "grpc" {
            node.serviceName = path
        } else {
            node.path = path
        }

        // TLS field can be "tls", "reality", "", or "none".
        let tlsRaw = stringValue(dict["tls"]).lowercased()
        switch tlsRaw {
        case "tls":     node.security = "tls"
        case "reality": node.security = "reality"
        case "xtls":    node.security = "xtls"
        default:        node.security = "none"
        }

        node.sni = nonEmptyOrNil(stringValue(dict["sni"]))
        node.alpn = nonEmptyOrNil(stringValue(dict["alpn"]))
        node.fingerprint = nonEmptyOrNil(stringValue(dict["fp"]))

        return node
    }

    // MARK: - VLESS

    /// Parse `vless://UUID@host:port?query#name`.
    private static func parseVLESS(_ link: String) -> ProxyNode? {
        guard let parts = splitURI(link) else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(parts.fragment, fallback: "\(parts.host):\(parts.port)"),
            protocolType: .vless,
            address: parts.host,
            port: parts.port
        )
        node.userId = nonEmptyOrNil(percentDecode(parts.userInfo))

        let q = parts.query
        node.encryption = nonEmptyOrNil(q["encryption"]) ?? "none"
        node.flow = nonEmptyOrNil(q["flow"])
        applyTransportAndTLS(from: q, to: &node, defaultSecurity: "none")
        return node
    }

    // MARK: - Trojan

    /// Parse `trojan://password@host:port?query#name`.
    private static func parseTrojan(_ link: String) -> ProxyNode? {
        guard let parts = splitURI(link) else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(parts.fragment, fallback: "\(parts.host):\(parts.port)"),
            protocolType: .trojan,
            address: parts.host,
            port: parts.port
        )
        node.password = nonEmptyOrNil(percentDecode(parts.userInfo))

        applyTransportAndTLS(from: parts.query, to: &node, defaultSecurity: "tls")
        return node
    }

    // MARK: - Shadowsocks

    /// Parse `ss://` in either SIP002 or legacy base64 encoding.
    private static func parseShadowsocks(_ link: String) -> ProxyNode? {
        var body = stripScheme(link)

        // Extract and strip the fragment (name) first.
        var name: String?
        if let hashIndex = body.firstIndex(of: "#") {
            name = percentDecode(String(body[body.index(after: hashIndex)...]))
            body = String(body[..<hashIndex])
        }

        // Strip a trailing plugin / query segment ("/?plugin=…" or "?plugin=…"); ignored.
        if let qIndex = body.firstIndex(of: "?") {
            body = String(body[..<qIndex])
        }
        if body.hasSuffix("/") { body.removeLast() }
        guard !body.isEmpty else { return nil }

        var method: String?
        var password: String?
        var host: String?
        var port: Int?

        if let atIndex = body.lastIndex(of: "@") {
            // SIP002: base64url(method:password)@host:port
            let userPart = String(body[..<atIndex])
            let hostPart = String(body[body.index(after: atIndex)...])

            if let decoded = decodeUserInfo(userPart),
               let colon = decoded.firstIndex(of: ":") {
                method = String(decoded[..<colon])
                password = String(decoded[decoded.index(after: colon)...])
            } else if let colon = userPart.firstIndex(of: ":") {
                // Already plain method:password (some exporters skip base64).
                method = percentDecode(String(userPart[..<colon]))
                password = percentDecode(String(userPart[userPart.index(after: colon)...]))
            } else {
                return nil
            }

            guard let hp = splitHostPort(hostPart) else { return nil }
            host = hp.host
            port = hp.port
        } else {
            // Legacy: base64(method:password@host:port)
            guard let data = tolerantBase64Decode(body),
                  let decoded = String(data: data, encoding: .utf8),
                  let atIdx = decoded.lastIndex(of: "@") else {
                return nil
            }
            let creds = String(decoded[..<atIdx])
            let hostPart = String(decoded[decoded.index(after: atIdx)...])
            guard let colon = creds.firstIndex(of: ":") else { return nil }
            method = String(creds[..<colon])
            password = String(creds[creds.index(after: colon)...])
            guard let hp = splitHostPort(hostPart) else { return nil }
            host = hp.host
            port = hp.port
        }

        guard let finalHost = host, let finalPort = port, !finalHost.isEmpty else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(name, fallback: "\(finalHost):\(finalPort)"),
            protocolType: .shadowsocks,
            address: finalHost,
            port: finalPort
        )
        node.method = method
        node.encryption = method   // mirror method into encryption
        node.password = password
        return node
    }

    // MARK: - ShadowsocksR

    /// Parse `ssr://base64url(host:port:protocol:method:obfs:base64url(password)/?params)`.
    private static func parseSSR(_ link: String) -> ProxyNode? {
        let body = stripScheme(link)
        guard let data = tolerantBase64Decode(body),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Split the main part from the query params.
        let mainPart: String
        var params: [String: String] = [:]
        if let qIndex = decoded.range(of: "/?") {
            mainPart = String(decoded[..<qIndex.lowerBound])
            let queryStr = String(decoded[qIndex.upperBound...])
            params = parseQuery(queryStr)
        } else if let qIndex = decoded.firstIndex(of: "?") {
            mainPart = String(decoded[..<qIndex])
            params = parseQuery(String(decoded[decoded.index(after: qIndex)...]))
        } else {
            mainPart = decoded
        }

        // host:port:protocol:method:obfs:base64pass
        let segs = mainPart.components(separatedBy: ":")
        guard segs.count >= 6 else { return nil }

        let host = segs[0]
        guard let port = Int(segs[1]), !host.isEmpty else { return nil }
        let ssrProtocol = segs[2]
        let method = segs[3]
        let obfs = segs[4]
        // Password may itself contain ':'? Spec uses single field; join the remainder defensively.
        let passwordB64 = segs[5...].joined(separator: ":")
        let password = decodeB64ToString(passwordB64) ?? passwordB64

        let remarks = params["remarks"].flatMap(decodeB64ToString)

        var node = ProxyNode(
            name: nonEmptyName(remarks, fallback: "\(host):\(port)"),
            protocolType: .ssr,
            address: host,
            port: port
        )
        node.ssrProtocol = nonEmptyOrNil(ssrProtocol)
        node.method = nonEmptyOrNil(method)
        node.encryption = nonEmptyOrNil(method)
        node.ssrObfs = nonEmptyOrNil(obfs)
        node.password = nonEmptyOrNil(password)
        node.ssrProtocolParam = params["protoparam"].flatMap(decodeB64ToString)
        node.ssrObfsParam = params["obfsparam"].flatMap(decodeB64ToString)
        return node
    }

    // MARK: - SOCKS

    /// Parse `socks://` / `socks5://`, with optional base64 userinfo (Shadowrocket style).
    private static func parseSocks(_ link: String) -> ProxyNode? {
        var body = stripScheme(link)

        var name: String?
        if let hashIndex = body.firstIndex(of: "#") {
            name = percentDecode(String(body[body.index(after: hashIndex)...]))
            body = String(body[..<hashIndex])
        }
        if let qIndex = body.firstIndex(of: "?") {
            body = String(body[..<qIndex])
        }

        var user: String?
        var pass: String?
        var hostPart = body

        if let atIndex = body.lastIndex(of: "@") {
            let userPart = String(body[..<atIndex])
            hostPart = String(body[body.index(after: atIndex)...])
            if let decoded = decodeUserInfo(userPart), let colon = decoded.firstIndex(of: ":") {
                user = String(decoded[..<colon])
                pass = String(decoded[decoded.index(after: colon)...])
            } else if let colon = userPart.firstIndex(of: ":") {
                user = percentDecode(String(userPart[..<colon]))
                pass = percentDecode(String(userPart[userPart.index(after: colon)...]))
            } else {
                user = nonEmptyOrNil(percentDecode(userPart))
            }
        }

        guard let hp = splitHostPort(hostPart), !hp.host.isEmpty else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(name, fallback: "\(hp.host):\(hp.port)"),
            protocolType: .socks,
            address: hp.host,
            port: hp.port
        )
        node.userId = nonEmptyOrNil(user ?? "")
        node.password = nonEmptyOrNil(pass ?? "")
        return node
    }

    // MARK: - HTTP

    /// Parse `http://` / `https://` only when it is clearly a proxy endpoint (explicit numeric port).
    private static func parseHTTP(_ link: String, isTLS: Bool) -> ProxyNode? {
        var body = stripScheme(link)

        var name: String?
        if let hashIndex = body.firstIndex(of: "#") {
            name = percentDecode(String(body[body.index(after: hashIndex)...]))
            body = String(body[..<hashIndex])
        }
        if let qIndex = body.firstIndex(of: "?") {
            body = String(body[..<qIndex])
        }

        // Reject anything with a path component — that looks like a normal web URL, not a proxy.
        if let slashIndex = body.firstIndex(of: "/") {
            let afterSlash = String(body[body.index(after: slashIndex)...])
            if !afterSlash.isEmpty { return nil }
            body = String(body[..<slashIndex])
        }

        var user: String?
        var pass: String?
        var hostPart = body
        if let atIndex = body.lastIndex(of: "@") {
            let userPart = String(body[..<atIndex])
            hostPart = String(body[body.index(after: atIndex)...])
            if let colon = userPart.firstIndex(of: ":") {
                user = percentDecode(String(userPart[..<colon]))
                pass = percentDecode(String(userPart[userPart.index(after: colon)...]))
            } else {
                user = nonEmptyOrNil(percentDecode(userPart))
            }
        }

        // Require an explicit numeric port to avoid swallowing ordinary web URLs.
        guard let hp = splitHostPort(hostPart), hp.hadExplicitPort, !hp.host.isEmpty else {
            return nil
        }

        var node = ProxyNode(
            name: nonEmptyName(name, fallback: "\(hp.host):\(hp.port)"),
            protocolType: .http,
            address: hp.host,
            port: hp.port
        )
        node.userId = nonEmptyOrNil(user ?? "")
        node.password = nonEmptyOrNil(pass ?? "")
        node.security = isTLS ? "tls" : "none"
        return node
    }

    // MARK: - Hysteria2

    /// Parse `hysteria2://` / `hy2://` (retained even though Xray cannot use it).
    private static func parseHysteria2(_ link: String) -> ProxyNode? {
        guard let parts = splitURI(link) else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(parts.fragment, fallback: "\(parts.host):\(parts.port)"),
            protocolType: .hysteria2,
            address: parts.host,
            port: parts.port
        )
        // Auth string carried as userinfo (Hysteria2 "auth").
        node.password = nonEmptyOrNil(percentDecode(parts.userInfo))
        let q = parts.query
        node.sni = nonEmptyOrNil(q["sni"]) ?? nonEmptyOrNil(q["peer"])
        if let insecure = q["insecure"] {
            node.allowInsecure = insecure == "1" || insecure.lowercased() == "true"
        }
        node.security = "tls"
        return node
    }

    // MARK: - TUIC

    /// Parse `tuic://uuid:password@host:port?query#name` (retained even though Xray cannot use it).
    private static func parseTUIC(_ link: String) -> ProxyNode? {
        guard let parts = splitURI(link) else { return nil }

        var node = ProxyNode(
            name: nonEmptyName(parts.fragment, fallback: "\(parts.host):\(parts.port)"),
            protocolType: .tuic,
            address: parts.host,
            port: parts.port
        )
        // userinfo is "uuid:password" for TUIC v5.
        let userInfo = parts.userInfo
        if let colon = userInfo.firstIndex(of: ":") {
            node.userId = nonEmptyOrNil(percentDecode(String(userInfo[..<colon])))
            node.password = nonEmptyOrNil(percentDecode(String(userInfo[userInfo.index(after: colon)...])))
        } else {
            node.userId = nonEmptyOrNil(percentDecode(userInfo))
        }
        let q = parts.query
        node.sni = nonEmptyOrNil(q["sni"]) ?? nonEmptyOrNil(q["peer"])
        node.alpn = nonEmptyOrNil(q["alpn"])
        node.security = "tls"
        return node
    }

    // MARK: - Shared transport / TLS query application

    /// Apply the common transport + TLS query parameters shared by VLESS/Trojan to `node`.
    private static func applyTransportAndTLS(
        from q: [String: String],
        to node: inout ProxyNode,
        defaultSecurity: String
    ) {
        // Transport network.
        let net = nonEmptyOrNil(q["type"])?.lowercased() ?? "tcp"
        node.network = net

        // Security.
        let security = nonEmptyOrNil(q["security"])?.lowercased() ?? defaultSecurity
        node.security = security

        // TLS / Reality common fields.
        node.sni = nonEmptyOrNil(q["sni"]) ?? nonEmptyOrNil(q["peer"])
        node.alpn = nonEmptyOrNil(q["alpn"])
        node.fingerprint = nonEmptyOrNil(q["fp"])
        if let insecure = q["allowInsecure"] ?? q["insecure"] {
            node.allowInsecure = insecure == "1" || insecure.lowercased() == "true"
        }
        node.publicKey = nonEmptyOrNil(q["pbk"])
        node.shortId = nonEmptyOrNil(q["sid"])
        node.spiderX = nonEmptyOrNil(q["spx"])

        // Headers / host / path.
        node.headerType = nonEmptyOrNil(q["headerType"])
        node.host = nonEmptyOrNil(q["host"])

        // gRPC.
        node.serviceName = nonEmptyOrNil(q["serviceName"])
        node.grpcMode = nonEmptyOrNil(q["mode"])

        // QUIC / mKCP.
        node.quicSecurity = nonEmptyOrNil(q["quicSecurity"])
        node.quicKey = nonEmptyOrNil(q["key"])
        node.seed = nonEmptyOrNil(q["seed"])

        // Path: for grpc the serviceName param is canonical, but some links carry the
        // service name in `path` too — keep `path` only for non-grpc transports.
        let path = nonEmptyOrNil(q["path"])
        if net == "grpc" {
            if node.serviceName == nil { node.serviceName = path }
        } else {
            node.path = path
        }
    }

    // MARK: - URI parsing

    /// The decomposed pieces of a `scheme://userinfo@host:port?query#fragment` URI.
    private struct URIParts {
        var userInfo: String
        var host: String
        var port: Int
        var query: [String: String]
        var fragment: String?
    }

    /// Decompose a userinfo-bearing URI. Returns `nil` if a host/port cannot be determined.
    private static func splitURI(_ link: String) -> URIParts? {
        var body = stripScheme(link)

        // Fragment.
        var fragment: String?
        if let hashIndex = body.firstIndex(of: "#") {
            fragment = percentDecode(String(body[body.index(after: hashIndex)...]))
            body = String(body[..<hashIndex])
        }

        // Query.
        var query: [String: String] = [:]
        if let qIndex = body.firstIndex(of: "?") {
            query = parseQuery(String(body[body.index(after: qIndex)...]))
            body = String(body[..<qIndex])
        }

        // Userinfo.
        var userInfo = ""
        var hostPort = body
        if let atIndex = body.lastIndex(of: "@") {
            userInfo = String(body[..<atIndex])
            hostPort = String(body[body.index(after: atIndex)...])
        }

        // Strip any trailing path slash on the authority.
        if let slashIndex = hostPort.firstIndex(of: "/") {
            hostPort = String(hostPort[..<slashIndex])
        }

        guard let hp = splitHostPort(hostPort), !hp.host.isEmpty else { return nil }
        return URIParts(userInfo: userInfo, host: hp.host, port: hp.port, query: query, fragment: fragment)
    }

    // MARK: - Low-level helpers

    /// Everything after the `scheme://`.
    private static func stripScheme(_ link: String) -> String {
        guard let range = link.range(of: "://") else { return link }
        return String(link[range.upperBound...])
    }

    /// Result of splitting an authority into host + port.
    private struct HostPort {
        var host: String
        var port: Int
        var hadExplicitPort: Bool
    }

    /// Split `host:port`, correctly handling bracketed IPv6 literals (`[::1]:443`).
    /// When no explicit port is present, defaults to 443 and flags `hadExplicitPort = false`.
    private static func splitHostPort(_ input: String) -> HostPort? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Bracketed IPv6: [addr] or [addr]:port
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let afterClose = s[s.index(after: close)...]
            if afterClose.hasPrefix(":") {
                let portStr = String(afterClose.dropFirst())
                guard let port = Int(portStr), (1...65535).contains(port) else { return nil }
                return HostPort(host: host, port: port, hadExplicitPort: true)
            }
            return HostPort(host: host, port: 443, hadExplicitPort: false)
        }

        // Unbracketed. A single colon => host:port. Multiple colons without brackets =>
        // ambiguous bare IPv6; treat the whole thing as the host with no explicit port.
        let colonCount = s.filter { $0 == ":" }.count
        if colonCount == 1, let colon = s.lastIndex(of: ":") {
            let host = String(s[..<colon])
            let portStr = String(s[s.index(after: colon)...])
            guard !host.isEmpty, let port = Int(portStr), (1...65535).contains(port) else {
                return nil
            }
            return HostPort(host: host, port: port, hadExplicitPort: true)
        }

        // No port (or a bare IPv6 without brackets).
        return HostPort(host: s, port: 443, hadExplicitPort: false)
    }

    /// Parse a query string into a `[key: value]` map, percent-decoding every value (and key).
    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") where !pair.isEmpty {
            if let eq = pair.firstIndex(of: "=") {
                let key = percentDecode(String(pair[..<eq]))
                let value = percentDecode(String(pair[pair.index(after: eq)...]))
                if !key.isEmpty { result[key] = value }
            } else {
                let key = percentDecode(pair)
                if !key.isEmpty { result[key] = "" }
            }
        }
        return result
    }

    /// Percent-decode a string, replacing `+` with space first (form-encoding tolerance).
    /// Falls back to the original string when decoding fails.
    private static func percentDecode(_ s: String) -> String {
        let withSpaces = s.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? s
    }

    /// Decode possibly-base64 userinfo (SIP002 / Shadowrocket). Returns `nil` if not valid base64
    /// or if the decoded bytes are not valid UTF-8.
    private static func decodeUserInfo(_ s: String) -> String? {
        guard let data = tolerantBase64Decode(s),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    /// Decode a base64 (standard or url-safe) field into a UTF-8 string.
    private static func decodeB64ToString(_ s: String) -> String? {
        guard let data = tolerantBase64Decode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Flexible value coercion (for JSON [String: Any])

    /// Coerce a JSON value (which may be a String, Int, Double, Bool, or NSNumber) to a String.
    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            // Preserve integer-ness where possible.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            if n.doubleValue == n.doubleValue.rounded() {
                return String(n.intValue)
            }
            return n.stringValue
        case let b as Bool:
            return b ? "true" : "false"
        default:
            return ""
        }
    }

    /// Coerce a JSON value to an Int. Accepts ints, numeric strings, and doubles.
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let i as Int:
            return i
        case let n as NSNumber:
            return n.intValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(trimmed) { return i }
            if let d = Double(trimmed) { return Int(d) }
            return nil
        case let d as Double:
            return Int(d)
        default:
            return nil
        }
    }

    /// Return `nil` for empty/whitespace-only strings, otherwise the trimmed-of-nothing original.
    private static func nonEmptyOrNil(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    /// A guaranteed non-empty display name, falling back when the candidate is missing/blank.
    private static func nonEmptyName(_ candidate: String?, fallback: String) -> String {
        if let c = candidate {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }
}
