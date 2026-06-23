import Darwin
import Foundation

/// Measures *real* end-to-end latency through a single proxy node.
///
/// Unlike a bare TCP handshake to the node's address (which only proves the server
/// IP:port is reachable and says nothing about whether the proxy actually carries
/// traffic), this spins up a throwaway Xray instance — one ephemeral SOCKS inbound
/// feeding only that node's outbound — issues a probe request through it via
/// ``LatencyTester/urlLatency(throughSOCKSPort:testURL:timeout:)``, then tears the
/// instance down. The reported time is the round-trip of actually reaching the test
/// URL *through the node*.
///
/// This is on-demand and isolated per node, so it works for any node in the list
/// (not just the currently connected one) and never disturbs the live core. Callers
/// should bound concurrency (each probe is a short-lived `xray` process).
enum NodeLatencyProbe {

    /// Run a through-proxy latency probe for `node`.
    ///
    /// - Parameters:
    ///   - node: The node to measure. Must be Xray-representable.
    ///   - xrayPath: Absolute path to the `xray` binary (the same one the app runs).
    ///   - options: Build options used to render the node's outbound.
    ///   - testURL: The URL fetched through the node. Defaults to a 204 endpoint.
    ///   - timeout: Per-request timeout for the probe HTTP call, in seconds.
    /// - Returns: Round-trip latency in milliseconds, or `nil` on any failure
    ///   (binary missing, unsupported protocol, boot timeout, probe failure).
    static func measure(
        node: ProxyNode,
        xrayPath: String,
        options: ConfigBuildOptions,
        testURL: URL = URL(string: "http://www.gstatic.com/generate_204")!,
        timeout: TimeInterval = 8
    ) async -> Int? {
        await withProbeInstance(node: node, xrayPath: xrayPath, options: options) { port in
            await LatencyTester.urlLatency(throughSOCKSPort: port, testURL: testURL, timeout: timeout)
        }
    }

    /// Run a through-proxy *download speed* test for `node`, reporting Mbps.
    /// Spins up the same throwaway instance as ``measure(node:xrayPath:options:testURL:timeout:)``
    /// but streams a large file through it. Consumes real bandwidth, so call on demand.
    static func measureSpeed(
        node: ProxyNode,
        xrayPath: String,
        options: ConfigBuildOptions,
        timeout: TimeInterval = 12
    ) async -> Double? {
        await withProbeInstance(node: node, xrayPath: xrayPath, options: options) { port in
            await LatencyTester.downloadSpeed(throughSOCKSPort: port, timeout: timeout)
        }
    }

    // MARK: - Throwaway instance

    /// Boots a throwaway Xray instance (one ephemeral SOCKS inbound feeding only
    /// `node`'s outbound), invokes `body` with the live SOCKS port, then tears the
    /// instance down. Returns `nil` if the instance can't be built/booted.
    private static func withProbeInstance<T>(
        node: ProxyNode,
        xrayPath: String,
        options: ConfigBuildOptions,
        _ body: (Int) async -> T?
    ) async -> T? {
        guard node.supportedByXray else { return nil }
        guard !xrayPath.isEmpty, FileManager.default.isExecutableFile(atPath: xrayPath) else { return nil }
        guard let port = freeTCPPort() else { return nil }

        // Render a minimal probe config bound to the ephemeral SOCKS port.
        let configData: Data
        do {
            configData = try ConfigBuilder.buildProbeConfig(node: node, socksPort: port, options: options)
        } catch {
            return nil
        }

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray-probe-\(UUID().uuidString).json")
        do { try configData.write(to: configURL) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: configURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xrayPath)
        process.arguments = ["run", "-c", configURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        // Wait for the throwaway instance to start accepting connections before probing.
        guard await waitForPort(port, timeout: 3) else { return nil }

        return await body(port)
    }

    // MARK: - Helpers

    /// Asks the kernel for a free loopback TCP port by binding to port 0 and reading
    /// back the assigned port. There is a small TOCTOU window between releasing the
    /// socket here and Xray binding it, but a collision merely fails this one probe.
    private static func freeTCPPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // let the OS choose

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { return nil }

        let port = Int(UInt16(bigEndian: bound.sin_port))
        return port > 0 ? port : nil
    }

    /// Polls the loopback `port` until a TCP connection succeeds or `timeout` elapses.
    private static func waitForPort(_ port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await LatencyTester.tcpPing(host: "127.0.0.1", port: port, timeout: 0.5) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
        return false
    }
}
