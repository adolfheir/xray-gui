import Foundation
import Network

/// Measures network latency to proxy nodes and through a local SOCKS5 proxy.
///
/// `LatencyTester` is a pure, stateless service. It exposes two independent
/// measurements:
///
/// - ``tcpPing(host:port:timeout:)`` performs a raw TCP handshake to a remote
///   endpoint and reports the time-to-connect in milliseconds. This is useful
///   as a fast, lightweight reachability/latency probe for a node's address.
/// - ``urlLatency(throughSOCKSPort:testURL:timeout:)`` issues a real HTTP
///   request routed through a locally running SOCKS5 proxy (e.g. the one
///   Xray-core exposes), reporting the round-trip time. This validates that the
///   proxy actually carries traffic end-to-end.
///
/// All timing uses a monotonic clock (`DispatchTime`) so results are unaffected
/// by wall-clock adjustments. Both methods return `nil` on failure or timeout
/// rather than throwing.
enum LatencyTester {

    // MARK: - TCP Ping

    /// Measures the time to establish a TCP connection to `host:port`.
    ///
    /// Uses the Network framework's `NWConnection`. The elapsed time is captured
    /// from just before `start(queue:)` until the connection reaches the
    /// `.ready` state, using a monotonic clock.
    ///
    /// - Parameters:
    ///   - host: The destination host (IP address or DNS name).
    ///   - port: The destination TCP port (1...65535).
    ///   - timeout: Maximum time to wait for the connection, in seconds.
    /// - Returns: The connect time in milliseconds, or `nil` on failure,
    ///   cancellation, an invalid port, or timeout.
    static func tcpPing(host: String, port: Int, timeout: TimeInterval = 5) async -> Int? {
        // Validate the port up-front; NWEndpoint.Port rejects out-of-range values.
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
              port > 0, port <= 65535 else {
            return nil
        }

        let endpointHost = NWEndpoint.Host(host)

        // Use a fast TCP configuration: no connection establishment retries and
        // an explicit handshake timeout as a secondary safety net.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(timeout.rounded(.up))
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        let connection = NWConnection(host: endpointHost, port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "com.xraygui.latencytester.tcp")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            // Guards against resuming the continuation more than once. Network
            // state callbacks and the timeout handler can race.
            let resumed = ManagedAtomicFlag()

            // Captured immediately before start() for an accurate measurement.
            let start = DispatchTime.now()

            @Sendable func finish(_ result: Int?) {
                guard resumed.trySet() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                    let ms = Int((Double(elapsedNanos) / 1_000_000).rounded())
                    finish(ms)
                case .failed, .cancelled:
                    finish(nil)
                case .waiting:
                    // `.waiting` indicates a transient error (e.g. no route). For a
                    // latency probe we treat it as a failure rather than waiting.
                    finish(nil)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            // Timeout safety net independent of TCP's own handshake timeout.
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - URL Latency Through SOCKS5

    /// Measures the round-trip time of an HTTP request routed through a local
    /// SOCKS5 proxy on `127.0.0.1:socksPort`.
    ///
    /// A successful response is any HTTP status in the 2xx or 3xx range
    /// (including 204, the typical "generate_204" connectivity-check response).
    ///
    /// - Parameters:
    ///   - socksPort: The local SOCKS5 listening port (e.g. Xray's inbound).
    ///   - testURL: The URL to request. Defaults to a lightweight 204 endpoint.
    ///   - timeout: Per-request timeout, in seconds.
    /// - Returns: The request round-trip time in milliseconds, or `nil` on
    ///   error, a non-success status, or timeout.
    static func urlLatency(
        throughSOCKSPort socksPort: Int,
        testURL: URL = URL(string: "http://www.gstatic.com/generate_204")!,
        timeout: TimeInterval = 8
    ) async -> Int? {
        guard socksPort > 0, socksPort <= 65535 else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil

        // Route all traffic through the local SOCKS5 proxy.
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: socksPort
        ]

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: testURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = DispatchTime.now()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            let ms = Int((Double(elapsedNanos) / 1_000_000).rounded())

            guard let http = response as? HTTPURLResponse else {
                // No HTTP response means we can't validate success.
                return nil
            }
            // Accept any 2xx or 3xx status as a successful connectivity check.
            guard (200 ... 399).contains(http.statusCode) else {
                return nil
            }
            return ms
        } catch {
            return nil
        }
    }
}

// MARK: - Atomic Flag

/// A minimal thread-safe one-shot flag used to ensure a continuation is resumed
/// exactly once across racing callbacks. Backed by an `os_unfair_lock`.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private var didSet = false
    private let lock = NSLock()

    /// Atomically transitions the flag from unset to set.
    /// - Returns: `true` exactly once (the first caller); `false` thereafter.
    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didSet { return false }
        didSet = true
        return true
    }
}
