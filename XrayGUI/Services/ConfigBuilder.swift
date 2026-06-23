import Foundation

/// `ConfigBuilder` turns a selected `ProxyNode`, the user's `RoutingSettings`, and
/// the local `ConfigBuildOptions` into a complete, valid Xray-core JSON configuration.
///
/// The builder is a *pure* service: it has no dependency on SwiftUI, `AppState`, or any
/// view layer. It only consumes the three shared model contracts and produces either a
/// `[String: Any]` dictionary (`buildConfigObject`) or serialized JSON `Data`
/// (`buildConfig`).
///
/// Design principles:
/// - **Never invent values.** Optional node fields are translated only when present;
///   otherwise Xray's own defaults are relied upon.
/// - **Omit empties.** Keys whose values are nil or empty are not inserted, keeping the
///   generated config compact and free of meaningless entries.
/// - **Explicit failures.** Unsupported protocols and missing mandatory credentials throw
///   a descriptive `BuildError` rather than emitting a broken config.
enum ConfigBuilder {

    // MARK: - Errors

    /// Errors raised while assembling an Xray configuration.
    enum BuildError: Error, LocalizedError {
        /// The node's protocol cannot be represented as an Xray outbound
        /// (ssr / hysteria2 / tuic).
        case unsupportedProtocol(ProxyProtocol)
        /// A mandatory field for the node's protocol is missing (e.g. a VLESS UUID,
        /// a Trojan password, a WireGuard secret key).
        case missingField(String)
        /// A strategy group has no Xray-supported member nodes, so no balancer
        /// outbounds can be generated.
        case emptyGroup

        var errorDescription: String? {
            switch self {
            case .unsupportedProtocol(let proto):
                return "Protocol \"\(proto.displayName)\" is not supported by Xray-core and cannot be converted into an outbound."
            case .missingField(let field):
                return "Required field \"\(field)\" is missing for the selected node."
            case .emptyGroup:
                return "The selected strategy group has no Xray-supported member nodes."
            }
        }
    }

    // MARK: - Public API

    /// Builds the complete Xray configuration and serializes it to pretty-printed JSON.
    ///
    /// Serialization uses `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` so the
    /// output is deterministic (stable key ordering) and readable (no escaped slashes).
    static func buildConfig(node: ProxyNode, routing: RoutingSettings, options: ConfigBuildOptions) throws -> Data {
        let object = try buildConfigObject(node: node, routing: routing, options: options)
        return try serialize(object)
    }

    /// Builds a balancer-backed Xray configuration from a strategy `group` (the
    /// pre-resolved member `nodes` define the balancer's outbounds and tag order) and
    /// serializes it to pretty-printed JSON.
    static func buildConfig(group: NodeGroup, nodes: [ProxyNode], routing: RoutingSettings, options: ConfigBuildOptions) throws -> Data {
        let object = try buildConfigObject(group: group, nodes: nodes, routing: routing, options: options)
        return try serialize(object)
    }

    /// Shared JSON serialization with deterministic key ordering and unescaped slashes.
    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Builds the complete Xray configuration as a JSON-compatible dictionary.
    ///
    /// The structure follows the Xray-core schema: `log`, `inbounds`, `outbounds`,
    /// `routing`, and (conditionally) `dns`, `stats`, `api`, and `policy`.
    static func buildConfigObject(node: ProxyNode, routing: RoutingSettings, options: ConfigBuildOptions) throws -> [String: Any] {
        // Single-node path: the proxy outbound (tag "proxy") is the implicit default,
        // so no balancer is involved.
        let outbounds = try buildOutbounds(node: node, options: options)
        let routingObject = buildRouting(routing: routing, options: options)
        return assembleConfig(outbounds: outbounds, routing: routingObject, settings: routing, options: options)
    }

    /// Builds a minimal, self-contained probe configuration for an on-demand
    /// *latency test*: a single ephemeral SOCKS inbound on `socksPort` feeding the
    /// one `node` outbound (Xray's implicit default).
    ///
    /// Deliberately omits DNS, stats/api, routing rules, mux and the HTTP inbound so
    /// the throwaway instance boots fast and never collides with the live core's
    /// ports. Used by `NodeLatencyProbe` to measure real end-to-end RTT *through* the
    /// node rather than a bare TCP handshake to its address.
    static func buildProbeConfig(node: ProxyNode, socksPort: Int, options: ConfigBuildOptions) throws -> Data {
        let proxy = try buildProxyOutbound(node: node, options: options)
        let config: [String: Any] = [
            "log": ["loglevel": "none"],
            "inbounds": [[
                "tag": "socks",
                "listen": "127.0.0.1",
                "port": socksPort,
                "protocol": "socks",
                "settings": ["udp": false, "auth": "noauth"]
            ]],
            "outbounds": [proxy] + auxiliaryOutbounds()
        ]
        return try serialize(config)
    }

    /// Builds the complete Xray configuration for a load-balancing strategy `group`.
    ///
    /// `nodes` are the group's pre-resolved member nodes (their order defines the
    /// `proxy-0`, `proxy-1`, … tag order). Unsupported protocols are filtered out; if
    /// no supported member remains, `BuildError.emptyGroup` is thrown.
    ///
    /// The generated config differs from the single-node path in three places: one
    /// proxy outbound per member, a `routing.balancers` entry that all proxy-bound
    /// rules route to via `balancerTag`, and (for `leastPing` / `leastLoad`) a
    /// top-level `observatory` health-probe block. `inbounds`, `dns`, and `stats`
    /// are identical to the single-node path.
    static func buildConfigObject(group: NodeGroup, nodes: [ProxyNode], routing: RoutingSettings, options: ConfigBuildOptions) throws -> [String: Any] {
        let members = nodes.filter(\.supportedByXray)
        guard !members.isEmpty else { throw BuildError.emptyGroup }

        let balancerTag = "balancer"

        // One proxy outbound per member, tagged "proxy-<index>" so the balancer's
        // "proxy-" selector prefix can match them.
        var outbounds: [[String: Any]] = []
        for (index, member) in members.enumerated() {
            var proxy = try buildProxyOutbound(node: member, options: options, tag: "proxy-\(index)")
            if options.enableMux {
                proxy["mux"] = [
                    "enabled": true,
                    "concurrency": options.muxConcurrency
                ]
            }
            outbounds.append(proxy)
        }
        outbounds.append(contentsOf: auxiliaryOutbounds())

        // Routing rules route the proxy action to the balancer instead of an outbound.
        var routingObject = buildRouting(routing: routing, options: options, balancerTag: balancerTag)
        routingObject["balancers"] = [[
            "tag": balancerTag,
            "selector": ["proxy-"],
            "strategy": ["type": group.strategy.rawValue]
        ]]

        var config = assembleConfig(outbounds: outbounds, routing: routingObject, settings: routing, options: options)

        // Observatory health probing (leastPing / leastLoad only).
        if group.strategy.needsObservatory {
            config["observatory"] = [
                "subjectSelector": ["proxy-"],
                "probeURL": nonEmpty(group.probeURL) ?? "https://www.gstatic.com/generate_204",
                "probeInterval": nonEmpty(group.probeInterval) ?? "5m"
            ]
        }

        return config
    }

    /// Assembles the shared, path-independent parts of the config (`log`, `inbounds`,
    /// `dns`, `stats`/`api`/`policy`) around the already-built `outbounds` and
    /// `routing` objects.
    private static func assembleConfig(
        outbounds: [[String: Any]],
        routing routingObject: [String: Any],
        settings routing: RoutingSettings,
        options: ConfigBuildOptions
    ) -> [String: Any] {
        var config: [String: Any] = [:]

        // log
        config["log"] = ["loglevel": options.logLevel]

        // inbounds
        config["inbounds"] = buildInbounds(options: options)

        // outbounds
        config["outbounds"] = outbounds

        // routing
        config["routing"] = routingObject

        // dns (optional)
        if routing.enableDNS {
            config["dns"] = buildDNS(routing: routing)
        }

        // stats / api / policy (optional)
        if statsEnabled(options) {
            config["stats"] = [String: Any]()
            config["api"] = [
                "tag": "api",
                "services": ["StatsService"]
            ]
            config["policy"] = [
                "system": [
                    "statsInboundUplink": true,
                    "statsInboundDownlink": true,
                    "statsOutboundUplink": true,
                    "statsOutboundDownlink": true
                ],
                "levels": [
                    "0": [
                        "statsUserUplink": true,
                        "statsUserDownlink": true
                    ]
                ]
            ]
        }

        return config
    }

    // MARK: - Inbounds

    private static func buildInbounds(options: ConfigBuildOptions) -> [[String: Any]] {
        var inbounds: [[String: Any]] = []

        // Shared sniffing object (only emitted when sniffing is enabled).
        let sniffing: [String: Any]? = options.enableSniffing
            ? [
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": false
            ]
            : nil

        // SOCKS inbound
        if options.socksPort > 0 {
            var socks: [String: Any] = [
                "tag": "socks",
                "listen": options.listenAddress,
                "port": options.socksPort,
                "protocol": "socks",
                "settings": [
                    "udp": options.enableUDP,
                    "auth": "noauth"
                ]
            ]
            insertIfPresent(&socks, "sniffing", sniffing)
            inbounds.append(socks)
        }

        // HTTP inbound
        if options.httpPort > 0 {
            var http: [String: Any] = [
                "tag": "http",
                "listen": options.listenAddress,
                "port": options.httpPort,
                "protocol": "http"
            ]
            insertIfPresent(&http, "sniffing", sniffing)
            inbounds.append(http)
        }

        // API inbound (dokodemo-door → api)
        if statsEnabled(options) {
            inbounds.append([
                "tag": "api",
                "listen": "127.0.0.1",
                "port": options.apiPort,
                "protocol": "dokodemo-door",
                "settings": [
                    "address": "127.0.0.1",
                    "network": "tcp"
                ]
            ])
        }

        return inbounds
    }

    // MARK: - Outbounds

    private static func buildOutbounds(node: ProxyNode, options: ConfigBuildOptions) throws -> [[String: Any]] {
        // Proxy outbound MUST be first so that it acts as Xray's default outbound.
        var proxy = try buildProxyOutbound(node: node, options: options)

        // Apply mux on the proxy outbound when requested.
        if options.enableMux {
            proxy["mux"] = [
                "enabled": true,
                "concurrency": options.muxConcurrency
            ]
        }

        return [proxy] + auxiliaryOutbounds()
    }

    /// The non-proxy outbounds (`direct`, `block`) shared by both the single-node and
    /// the balancer paths.
    private static func auxiliaryOutbounds() -> [[String: Any]] {
        let direct: [String: Any] = [
            "protocol": "freedom",
            "tag": "direct",
            "settings": ["domainStrategy": "UseIP"]
        ]

        // blackhole with no response simply closes the connection (the default),
        // which is the desired "block" behavior. A "http" response would emit a
        // 403 and leak that traffic was intercepted.
        let block: [String: Any] = [
            "protocol": "blackhole",
            "tag": "block"
        ]

        return [direct, block]
    }

    /// Builds the protocol-specific proxy outbound (tag `proxy` by default, or a
    /// per-member `proxy-<index>` tag in the balancer path), including the transport
    /// `streamSettings` driven by `node.network` / `node.security`.
    private static func buildProxyOutbound(node: ProxyNode, options: ConfigBuildOptions, tag: String = "proxy") throws -> [String: Any] {
        guard node.supportedByXray else {
            throw BuildError.unsupportedProtocol(node.protocolType)
        }

        var outbound: [String: Any] = ["tag": tag]
        var settings: [String: Any] = [:]

        switch node.protocolType {
        case .vmess:
            outbound["protocol"] = "vmess"
            let id = try requireUserId(node)
            // alterId and security always have defaults, so the user object is complete here.
            let user: [String: Any] = [
                "id": id,
                "alterId": node.alterId ?? 0,
                "security": nonEmpty(node.encryption) ?? "auto"
            ]
            settings["vnext"] = [[
                "address": node.address,
                "port": node.port,
                "users": [user]
            ]]

        case .vless:
            outbound["protocol"] = "vless"
            let id = try requireUserId(node)
            var user: [String: Any] = [
                "id": id,
                "encryption": nonEmpty(node.encryption) ?? "none"
            ]
            insertIfPresent(&user, "flow", nonEmpty(node.flow))
            settings["vnext"] = [[
                "address": node.address,
                "port": node.port,
                "users": [user]
            ]]

        case .trojan:
            outbound["protocol"] = "trojan"
            guard let password = nonEmpty(node.password) else {
                throw BuildError.missingField("password")
            }
            var server: [String: Any] = [
                "address": node.address,
                "port": node.port,
                "password": password
            ]
            insertIfPresent(&server, "flow", nonEmpty(node.flow))
            settings["servers"] = [server]

        case .shadowsocks:
            outbound["protocol"] = "shadowsocks"
            guard let password = nonEmpty(node.password) else {
                throw BuildError.missingField("password")
            }
            // The cipher method may be stored in `method` or, as a fallback, `encryption`.
            guard let method = nonEmpty(node.method) ?? nonEmpty(node.encryption) else {
                throw BuildError.missingField("method")
            }
            settings["servers"] = [[
                "address": node.address,
                "port": node.port,
                "method": method,
                "password": password,
                "uot": options.enableUDP
            ]]

        case .socks:
            outbound["protocol"] = "socks"
            var server: [String: Any] = [
                "address": node.address,
                "port": node.port
            ]
            // Credentials are only added when both a username and password are present.
            if let user = nonEmpty(node.userId), let pass = nonEmpty(node.password) {
                server["users"] = [[
                    "user": user,
                    "pass": pass
                ]]
            }
            settings["servers"] = [server]

        case .http:
            outbound["protocol"] = "http"
            var server: [String: Any] = [
                "address": node.address,
                "port": node.port
            ]
            if let user = nonEmpty(node.userId), let pass = nonEmpty(node.password) {
                server["users"] = [[
                    "user": user,
                    "pass": pass
                ]]
            }
            settings["servers"] = [server]

        case .wireguard:
            outbound["protocol"] = "wireguard"
            guard let secretKey = nonEmpty(node.password) else {
                throw BuildError.missingField("secretKey")
            }
            guard let publicKey = nonEmpty(node.publicKey) else {
                throw BuildError.missingField("publicKey")
            }
            settings["secretKey"] = secretKey
            settings["peers"] = [[
                "publicKey": publicKey,
                "endpoint": "\(node.address):\(node.port)"
            ]]

        case .ssr, .hysteria2, .tuic:
            // Guarded by `node.supportedByXray` above; defensively re-throw.
            throw BuildError.unsupportedProtocol(node.protocolType)
        }

        outbound["settings"] = settings

        // streamSettings (transport + security)
        if let stream = buildStreamSettings(node: node) {
            outbound["streamSettings"] = stream
        }

        return outbound
    }

    // MARK: - streamSettings

    /// Builds the `streamSettings` object for the proxy outbound from the node's
    /// transport (`network`) and security (`security`) descriptors.
    private static func buildStreamSettings(node: ProxyNode) -> [String: Any]? {
        let network = normalizeNetwork(node.network)
        let security = normalizeSecurity(node.security)

        var stream: [String: Any] = [
            "network": network,
            "security": security
        ]

        // Security-specific settings.
        switch security {
        case "tls", "xtls":
            // XTLS shares the same client-side settings object as TLS.
            var tls: [String: Any] = [
                "serverName": nonEmpty(node.sni) ?? nonEmpty(node.host) ?? node.address
            ]
            // `allowInsecure` was removed in the Xray-core v25+ line (migrated to
            // `pinnedPeerCertSha256`); its mere presence — even as `false` — makes the
            // newer core reject the whole config. Emit it only when the node requests
            // it AND the installed core still understands it.
            if node.allowInsecure, XrayCoreManager.shared.coreSupportsAllowInsecure {
                tls["allowInsecure"] = true
            }
            let alpn = split(node.alpn)
            insertIfPresent(&tls, "alpn", alpn.isEmpty ? nil : alpn)
            insertIfPresent(&tls, "fingerprint", nonEmpty(node.fingerprint))
            stream["tlsSettings"] = tls

        case "reality":
            // publicKey is mandatory for REALITY; if the link omitted it the config
            // will (correctly) fail `xray -test` so the user is told. Optional fields
            // are omitted when empty rather than emitted blank.
            var reality: [String: Any] = [
                "serverName": nonEmpty(node.sni) ?? nonEmpty(node.host) ?? node.address,
                "publicKey": nonEmpty(node.publicKey) ?? "",
                "fingerprint": nonEmpty(node.fingerprint) ?? "chrome"
            ]
            insertIfPresent(&reality, "shortId", nonEmpty(node.shortId))
            insertIfPresent(&reality, "spiderX", nonEmpty(node.spiderX))
            stream["realitySettings"] = reality

        default:
            // "none" / "" — no security object.
            break
        }

        // Transport-specific settings. Only emitted when the network is non-tcp, or
        // when it is tcp but using HTTP header obfuscation.
        let headerType = nonEmpty(node.headerType)
        let needsTransport = (network != "tcp") || (network == "tcp" && headerType == "http")

        if needsTransport {
            switch network {
            case "ws":
                var ws: [String: Any] = ["path": nonEmpty(node.path) ?? "/"]
                if let host = nonEmpty(node.host) {
                    ws["headers"] = ["Host": host]
                }
                stream["wsSettings"] = ws

            case "httpupgrade":
                var hu: [String: Any] = ["path": nonEmpty(node.path) ?? "/"]
                insertIfPresent(&hu, "host", nonEmpty(node.host))
                stream["httpupgradeSettings"] = hu

            case "xhttp":
                var xhttp: [String: Any] = [
                    "path": nonEmpty(node.path) ?? "/",
                    "mode": nonEmpty(node.grpcMode) ?? "auto"
                ]
                insertIfPresent(&xhttp, "host", nonEmpty(node.host))
                stream["xhttpSettings"] = xhttp

            case "grpc":
                stream["grpcSettings"] = [
                    "serviceName": nonEmpty(node.serviceName) ?? nonEmpty(node.path) ?? "",
                    "multiMode": node.grpcMode == "multi"
                ]

            case "http":
                var http: [String: Any] = ["path": nonEmpty(node.path) ?? "/"]
                let hosts = split(node.host)
                insertIfPresent(&http, "host", hosts.isEmpty ? nil : hosts)
                stream["httpSettings"] = http

            case "quic":
                stream["quicSettings"] = [
                    "security": nonEmpty(node.quicSecurity) ?? "none",
                    "key": nonEmpty(node.quicKey) ?? "",
                    "header": ["type": nonEmpty(node.headerType) ?? "none"]
                ]

            case "kcp":
                var kcp: [String: Any] = [
                    "header": ["type": nonEmpty(node.headerType) ?? "none"]
                ]
                insertIfPresent(&kcp, "seed", nonEmpty(node.seed))
                stream["kcpSettings"] = kcp

            case "tcp":
                // tcp + headerType == "http": HTTP obfuscation header.
                let hosts = split(node.host)
                var request: [String: Any] = [
                    "path": [nonEmpty(node.path) ?? "/"]
                ]
                if !hosts.isEmpty {
                    request["headers"] = ["Host": hosts]
                }
                stream["tcpSettings"] = [
                    "header": [
                        "type": "http",
                        "request": request
                    ]
                ]

            default:
                // Unknown transport: pass the network through without extra settings.
                break
            }
        }

        return stream
    }

    // MARK: - Routing

    /// Builds the `routing` object.
    ///
    /// When `balancerTag` is non-nil the config has no implicit default proxy outbound
    /// (a balancer is not an outbound), so two things change: every rule that would
    /// route to the "proxy" outbound instead routes to the balancer via `balancerTag`,
    /// and the modes that relied on the implicit default (`global`, `bypassMainland`,
    /// `custom`) gain an explicit catch-all rule sending the remainder to the balancer.
    private static func buildRouting(routing: RoutingSettings, options: ConfigBuildOptions, balancerTag: String? = nil) -> [String: Any] {
        var rules: [[String: Any]] = []

        /// Routes a rule to the proxy action: an `outboundTag: "proxy"` in the
        /// single-node path, or a `balancerTag` in the balancer path.
        func applyProxyAction(_ rule: inout [String: Any]) {
            if let balancerTag {
                rule["balancerTag"] = balancerTag
            } else {
                rule["outboundTag"] = "proxy"
            }
        }

        /// A catch-all rule routing everything left to the proxy action. Only needed
        /// in the balancer path, where there is no implicit default outbound.
        func balancerCatchAll() -> [String: Any]? {
            guard let balancerTag else { return nil }
            return [
                "type": "field",
                "port": "0-65535",
                "balancerTag": balancerTag
            ]
        }

        // 1. API rule (must come first so stats traffic is short-circuited).
        if statsEnabled(options) {
            rules.append([
                "type": "field",
                "inboundTag": ["api"],
                "outboundTag": "api"
            ])
        }

        // 2. User custom rules (enabled only).
        for rule in routing.customRules where rule.enabled {
            // Skip rules that match nothing actionable.
            if rule.domains.isEmpty && rule.ips.isEmpty && nonEmpty(rule.port) == nil {
                continue
            }
            var mapped: [String: Any] = ["type": "field"]
            if rule.outbound == .proxy {
                applyProxyAction(&mapped)
            } else {
                mapped["outboundTag"] = outboundTag(for: rule.outbound)
            }
            insertIfPresent(&mapped, "domain", rule.domains.isEmpty ? nil : rule.domains)
            insertIfPresent(&mapped, "ip", rule.ips.isEmpty ? nil : rule.ips)
            insertIfPresent(&mapped, "port", nonEmpty(rule.port))
            insertIfPresent(&mapped, "network", nonEmpty(rule.network))
            rules.append(mapped)
        }

        // 3. Bypass LAN / private networks.
        if routing.bypassLAN {
            rules.append([
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "direct"
            ])
        }

        // 4. Block ads.
        if routing.blockAds {
            rules.append([
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            ])
        }

        // 5. Mode-specific preset rules.
        switch routing.mode {
        case .global:
            // Everything proxied. In the single-node path the proxy outbound is the
            // implicit default; in the balancer path an explicit catch-all is needed.
            if let catchAll = balancerCatchAll() { rules.append(catchAll) }

        case .bypassMainland:
            rules.append([
                "type": "field",
                "domain": ["geosite:cn"],
                "outboundTag": "direct"
            ])
            rules.append([
                "type": "field",
                "ip": ["geoip:cn"],
                "outboundTag": "direct"
            ])
            // Remainder → proxy (implicit default for single-node; explicit for balancer).
            if let catchAll = balancerCatchAll() { rules.append(catchAll) }

        case .directMainlandProxyRest:
            rules.append([
                "type": "field",
                "ip": ["geoip:cn"],
                "outboundTag": "direct"
            ])
            rules.append([
                "type": "field",
                "port": "0-65535",
                "outboundTag": "direct"
            ])

        case .direct:
            rules.append([
                "type": "field",
                "port": "0-65535",
                "outboundTag": "direct"
            ])

        case .custom:
            // No preset: only custom + LAN/ads rules above apply. In the balancer path
            // anything unmatched would have no default outbound, so route it to the
            // balancer as a catch-all.
            if let catchAll = balancerCatchAll() { rules.append(catchAll) }
        }

        return [
            "domainStrategy": routing.domainStrategy,
            "rules": rules
        ]
    }

    private static func outboundTag(for outbound: RuleOutbound) -> String {
        switch outbound {
        case .proxy: return "proxy"
        case .block: return "block"
        case .direct: return "direct"
        }
    }

    // MARK: - DNS

    private static func buildDNS(routing: RoutingSettings) -> [String: Any] {
        // Remote DNS servers (used for proxied lookups). Fall back to a sane default.
        let remoteServers = routing.remoteDNS
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var servers: [Any] = remoteServers.isEmpty ? ["1.1.1.1"] : remoteServers

        // Domestic DNS server scoped to Chinese domains/IPs.
        let directDNS = routing.directDNS
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "223.5.5.5"
        servers.append([
            "address": directDNS,
            "domains": ["geosite:cn"],
            "expectIPs": ["geoip:cn"]
        ])

        return [
            "servers": servers,
            "queryStrategy": "UseIP"
        ]
    }

    // MARK: - Helpers

    /// Inserts a value into `dict` under `key` only when the value is meaningfully
    /// present: nil values are skipped, as are empty strings, arrays, and dictionaries.
    private static func insertIfPresent(_ dict: inout [String: Any], _ key: String, _ value: Any?) {
        guard let value else { return }
        if let string = value as? String, string.isEmpty { return }
        if let array = value as? [Any], array.isEmpty { return }
        if let map = value as? [String: Any], map.isEmpty { return }
        dict[key] = value
    }

    /// Splits a comma/space-separated CSV string into trimmed, non-empty components.
    /// Returns an empty array for nil/blank input.
    private static func split(_ csv: String?) -> [String] {
        guard let csv else { return [] }
        return csv
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns the trimmed string if it is non-empty, otherwise nil.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Requires and returns a non-empty VMess/VLESS UUID, throwing otherwise.
    private static func requireUserId(_ node: ProxyNode) throws -> String {
        guard let id = nonEmpty(node.userId) else {
            throw BuildError.missingField("userId")
        }
        return id
    }

    /// Stats/API are only emitted when explicitly enabled AND a valid API port is set;
    /// an apiPort of 0 would otherwise produce an invalid dokodemo-door inbound.
    private static func statsEnabled(_ options: ConfigBuildOptions) -> Bool {
        options.enableStatsAPI && options.apiPort > 0
    }

    /// Normalizes transport aliases to Xray's canonical `streamSettings.network` values.
    private static func normalizeNetwork(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "h2", "http": return "http"
        case "mkcp": return "kcp"
        case "splithttp", "xhttp": return "xhttp"
        case "", "tcp": return "tcp"
        default: return value
        }
    }

    /// Normalizes the security descriptor, treating blank as "none".
    ///
    /// Modern Xray-core removed the standalone `"xtls"` stream security value;
    /// XTLS-Vision is now carried by the user-level `flow` field (already emitted
    /// for VLESS/Trojan) paired with `"tls"`. We therefore remap `xtls` → `tls` so
    /// the generated streamSettings use a value Xray accepts.
    private static func normalizeSecurity(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty { return "none" }
        if value == "xtls" { return "tls" }
        return value
    }
}
