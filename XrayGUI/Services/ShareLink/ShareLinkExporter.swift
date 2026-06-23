import Foundation

/// Serializes a ``ProxyNode`` back into a *share link* URI — the inverse of ``ShareLinkParser``.
///
/// The exporter is best-effort and never throws: it returns the node's original
/// `rawLink` verbatim when present (the highest-fidelity option), otherwise it
/// reconstructs a URI for the protocols the app can natively produce
/// (`vless`, `vmess`, `trojan`, `shadowsocks`). Any other protocol, or a node
/// missing the fields a protocol requires, yields `nil`.
///
/// Query values are percent-encoded; empty/`nil` fields are simply omitted from
/// the query rather than emitted as blanks. The field → query-key mapping mirrors
/// the reverse direction in ``ShareLinkParser`` (`type`, `security`, `sni`, `fp`,
/// `pbk`, `sid`, `spx`, `flow`, `host`, `path`, `serviceName`, `alpn`, …).
enum ShareLinkExporter {

    // MARK: - Public API

    /// Serialize a node back to a share URI.
    ///
    /// - Parameter node: The node to serialize.
    /// - Returns: The node's original `rawLink` when present; otherwise a freshly
    ///   built URI for `vless`/`vmess`/`trojan`/`shadowsocks`. `nil` if the protocol
    ///   is unsupported for export or required fields are missing.
    static func export(_ node: ProxyNode) -> String? {
        if let raw = node.rawLink?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }

        switch node.protocolType {
        case .vless:
            return exportVLESS(node)
        case .vmess:
            return exportVMess(node)
        case .trojan:
            return exportTrojan(node)
        case .shadowsocks:
            return exportShadowsocks(node)
        default:
            return nil
        }
    }

    // MARK: - VLESS

    /// Build `vless://UUID@address:port?query#name`.
    private static func exportVLESS(_ node: ProxyNode) -> String? {
        guard let userId = nonEmpty(node.userId), !node.address.isEmpty else { return nil }

        var query: [(String, String)] = []
        appendIfPresent(&query, "encryption", node.encryption ?? "none")
        appendIfPresent(&query, "type", node.network)
        appendIfPresent(&query, "security", node.security)
        appendIfPresent(&query, "flow", node.flow)
        appendIfPresent(&query, "sni", node.sni)
        appendIfPresent(&query, "alpn", node.alpn)
        appendIfPresent(&query, "fp", node.fingerprint)
        appendIfPresent(&query, "pbk", node.publicKey)
        appendIfPresent(&query, "sid", node.shortId)
        appendIfPresent(&query, "spx", node.spiderX)
        appendIfPresent(&query, "host", node.host)
        appendIfPresent(&query, "headerType", node.headerType)
        if node.network == "grpc" {
            appendIfPresent(&query, "serviceName", node.serviceName)
            appendIfPresent(&query, "mode", node.grpcMode)
        } else {
            appendIfPresent(&query, "path", node.path)
        }
        if node.allowInsecure { appendIfPresent(&query, "allowInsecure", "1") }

        let auth = "\(percentEncode(userId))@\(node.address):\(node.port)"
        return "vless://" + auth + queryString(query) + fragment(node.name)
    }

    // MARK: - VMess

    /// Build `vmess://<base64(JSON)>` in the v2rayN object form.
    private static func exportVMess(_ node: ProxyNode) -> String? {
        guard !node.address.isEmpty else { return nil }

        var dict: [String: Any] = [
            "v": "2",
            "ps": node.name,
            "add": node.address,
            "port": "\(node.port)",
            "id": node.userId ?? "",
            "aid": "\(node.alterId ?? 0)",
            "scy": node.encryption ?? "auto",
            "net": node.network,
            "type": node.headerType ?? "none"
        ]

        if let host = nonEmpty(node.host) { dict["host"] = host }
        if node.network == "grpc" {
            if let svc = nonEmpty(node.serviceName) { dict["path"] = svc }
        } else if let path = nonEmpty(node.path) {
            dict["path"] = path
        }

        // TLS field: vmess uses "tls"/"reality"/"xtls" or empty for none.
        dict["tls"] = (node.security == "none") ? "" : node.security
        if let sni = nonEmpty(node.sni) { dict["sni"] = sni }
        if let alpn = nonEmpty(node.alpn) { dict["alpn"] = alpn }
        if let fp = nonEmpty(node.fingerprint) { dict["fp"] = fp }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              !data.isEmpty else {
            return nil
        }
        return "vmess://" + data.base64EncodedString()
    }

    // MARK: - Trojan

    /// Build `trojan://password@address:port?query#name`.
    private static func exportTrojan(_ node: ProxyNode) -> String? {
        guard let password = nonEmpty(node.password), !node.address.isEmpty else { return nil }

        var query: [(String, String)] = []
        appendIfPresent(&query, "type", node.network)
        appendIfPresent(&query, "security", node.security.isEmpty ? "tls" : node.security)
        appendIfPresent(&query, "sni", node.sni)
        appendIfPresent(&query, "alpn", node.alpn)
        appendIfPresent(&query, "fp", node.fingerprint)
        appendIfPresent(&query, "host", node.host)
        appendIfPresent(&query, "headerType", node.headerType)
        if node.network == "grpc" {
            appendIfPresent(&query, "serviceName", node.serviceName)
            appendIfPresent(&query, "mode", node.grpcMode)
        } else {
            appendIfPresent(&query, "path", node.path)
        }
        if node.allowInsecure { appendIfPresent(&query, "allowInsecure", "1") }

        let auth = "\(percentEncode(password))@\(node.address):\(node.port)"
        return "trojan://" + auth + queryString(query) + fragment(node.name)
    }

    // MARK: - Shadowsocks

    /// Build SIP002 `ss://base64url(method:password)@address:port#name`.
    private static func exportShadowsocks(_ node: ProxyNode) -> String? {
        let method = nonEmpty(node.method) ?? nonEmpty(node.encryption)
        guard let method, let password = nonEmpty(node.password), !node.address.isEmpty else {
            return nil
        }

        let userInfo = "\(method):\(password)"
        let encoded = base64URLEncode(userInfo)
        let auth = "\(encoded)@\(node.address):\(node.port)"
        return "ss://" + auth + fragment(node.name)
    }

    // MARK: - Helpers

    /// Append a `(key, value)` pair only when `value` is non-empty.
    private static func appendIfPresent(_ query: inout [(String, String)], _ key: String, _ value: String?) {
        guard let v = nonEmpty(value) else { return }
        query.append((key, v))
    }

    /// Assemble a `?k=v&k=v` query string with percent-encoded values, or "" when empty.
    private static func queryString(_ pairs: [(String, String)]) -> String {
        guard !pairs.isEmpty else { return "" }
        let joined = pairs
            .map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }
            .joined(separator: "&")
        return "?" + joined
    }

    /// Build a `#name` fragment with the name percent-encoded, or "" when blank.
    private static func fragment(_ name: String) -> String {
        guard let n = nonEmpty(name) else { return "" }
        return "#" + percentEncode(n)
    }

    /// Percent-encode a single query/fragment component conservatively.
    /// Only unreserved characters (RFC 3986) are left intact.
    private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Base64url-encode a UTF-8 string without padding (SIP002 userinfo form).
    private static func base64URLEncode(_ s: String) -> String {
        let data = Data(s.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Return `nil` for `nil`/empty/whitespace-only strings, otherwise the original.
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
