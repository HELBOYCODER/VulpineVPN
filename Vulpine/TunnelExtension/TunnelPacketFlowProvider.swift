// TunnelPacketFlowProvider.swift
// NEPacketTunnelProvider wiring for the Vulpine data plane.
//
// Architecture (mirrors FoxyVPN's hevd + LocalSocks5Server layout, collapsed
// into the Network Extension process):
//   NEPacketTunnelProvider
//     ├─ resolves the edge address (EdgeAddressResolver, DoH)
//     ├─ maintains one H2UpstreamSession (TLS+ALPN h2 CONNECT multiplexer)
//     └─ bridges each packet flow (from NWUDPSession-less TCP flows via
//        packet forwarding, or via an on-device local SOCKS5 listener) onto
//        HTTP/2 CONNECT streams, with health tracking + refusal backoff.
//
// Two consumer modes are supported:
//  1. Flow-based (default): the provider intercepts TCP flows with
//     `packetFlow.bindFlow`-style handling via `handleNewFlow` (iOS 17+ /
//     NWTCPProxyTransportProvider). For broad iOS compatibility we ship the
//     in-process SOCKS listener below as the primary path.
//  2. In-process SOCKS5 listener: the tunnel routes TCP to 127.0.0.1:<port>
//     where LocalSocks5Listener performs the SOCKS5 handshake and bridges each
//     connection to an h2 CONNECT stream. This mirrors the Kotlin
//     LocalSocks5Server + hev-socks5-tunnel arrangement.

import Foundation
import Network
import NetworkExtension

final class TunnelPacketFlowProvider: NEPacketTunnelProvider {

    private let logger = OSLogRelayLogger()
    private var session: H2UpstreamSession?
    private var health = UpstreamHealthTracker()
    private var socksListener: LocalSocks5Listener?
    private var unauthenticatedSession: H2UpstreamSession?
    private var currentConfig: RelayConfig?

    // Refusal backoff cache (port of unreachableTargets in LocalSocks5Server).
    private final class RefusalRecord {
        var strikes = 0
        var expiresAt = Date.distantPast
    }
    private let refusalLock = NSLock()
    private var refusedTargets: [String: RefusalRecord] = [:]
    private let refusalCacheCap = 256
    private let refusalBaseTTL: TimeInterval = 30
    private let refusalMaxTTL: TimeInterval = 10 * 60
    private let refusalsBeforePolicy = 3

    // MARK: NEPacketTunnelProvider

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        let settings = try tunnelSettings()
        try await setTunnelNetworkSettings(settings)

        guard let config = makeRelayConfig(options: options) else {
            throw TunnelError.missingConfiguration
        }
        currentConfig = config
        await dialSession(config: config)
        startSocksListener(config: config)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        socksListener?.stop()
        socksListener = nil
        session?.close()
        session = nil
        EdgeAddressResolver.invalidate()
        completionHandler()
    }

    private enum TunnelError: Error {
        case missingConfiguration
        case sessionUnauthenticated
    }

    // MARK: Configuration

    private func makeRelayConfig(options: [String: NSObject]?) -> RelayConfig? {
        guard let host = options?["edgeHost"] as? String,
              let port = (options?["edgePort"] as? NSNumber)?.intValue,
              let token = options?["proxyPassToken"] as? String else {
            return nil
        }
        let edgeAddress = options?["edgeAddress"] as? String
        let doh = (options?["dohEndpointAddresses"] as? [String]) ?? []
        return RelayConfig(tlsHost: host, tlsPort: port, edgeAddress: edgeAddress,
                           bearerToken: token, dohEndpointAddresses: doh)
    }

    private func tunnelSettings() throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: currentConfig?.connectHost ?? "10.111.0.1")
        settings.mtu = 1400
        let ipv4 = NEIPv4Settings(addresses: ["10.111.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        let dns = NEDNSSettings(servers: ["10.111.0.1"])
        dns.matchDomains = [""]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = dns
        let ipv6 = NEIPv6Settings(addresses: ["fd00:0:0:1110::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        return settings
    }

    // MARK: Session management

    private func dialSession(config: RelayConfig) async {
        // Resolve the edge address over DoH when a custom edge address is set.
        var edgeAddress = config.edgeAddress
        if let candidate = edgeAddress, !candidate.isEmpty, !isIPLiteral(candidate) {
            let resolved = await EdgeAddressResolver.resolve(
                hostname: candidate, endpointAddresses: config.dohEndpointAddresses)
            if let resolved {
                logger.log(.info, "TunnelProvider",
                           "resolved edge address \(candidate) over DoH -> \(resolved)")
                edgeAddress = resolved
            } else {
                logger.log(.info, "TunnelProvider",
                           "could not resolve \(candidate) over DoH; dialling by hostname")
            }
        }

        let dial = RelayConfig(tlsHost: config.tlsHost, tlsPort: config.tlsPort,
                               edgeAddress: edgeAddress, bearerToken: config.bearerToken,
                               dohEndpointAddresses: config.dohEndpointAddresses)
        let session = H2UpstreamSession(config: dial, logger: logger)
        self.session = session
        do {
            try await session.connect()
        } catch {
            logger.log(.error, "TunnelProvider", "failed to connect upstream session: \(error)")
            session.close()
            self.session = nil
        }
    }

    private func isIPLiteral(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private func redial() {
        Task {
            guard let config = currentConfig else { return }
            session?.close()
            health.reset()
            await dialSession(config: config)
        }
    }

    // MARK: SOCKS listener bridging

    private func startSocksListener(config: RelayConfig) {
        let listener = LocalSocks5Listener(
            port: 1080,
            sessionProvider: { [weak self] in
                guard let self, let session = self.session, session.isConnected else { return nil }
                return session
            },
            onSessionUnhealthy: { [weak self] in self?.redial() },
            onSessionUnauthenticated: { [weak self] session in
                self?.unauthenticatedSession = session
                self?.redial()
            },
            logger: logger
        )
        listener.start()
        socksListener = listener
    }

    // MARK: Flow bridging (modern flow API path)

    /// Handles a TCP flow captured by the packet tunnel (iOS 17+ flow API).
    /// Bridges the flow's read/write handles onto an h2 CONNECT stream.
    func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else { return false }
        Task {
            await bridge(tcpFlow: tcpFlow)
        }
        return true
    }

    private func bridge(tcpFlow: NEAppProxyTCPFlow) async {
        let remote = tcpFlow.remoteEndpoint
        guard let desc = remote as? CustomStringConvertible, desc.description.contains(":") else { return }
        // Parse "host:port" from the endpoint description.
        let parts = desc.description.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let p = UInt16(parts.last!) else { return }
        let host = parts.dropLast().joined(separator: ":")
        let port = NWEndpoint.Port(rawValue: p)!
        let targetHost = String(describing: host)
        let targetPort = Int(port.rawValue)
        let targetKey = "\(targetHost):\(targetPort)"

        if isKnownUnreachable(targetKey) {
            logger.log(.debug, "TunnelProvider", "refusing \(targetKey): the edge refused this destination moments ago")
            tcpFlow.cancelFlow()
            return
        }

        guard let session = await usableSession() else {
            tcpFlow.cancelFlow()
            return
        }
        if session === unauthenticatedSession {
            tcpFlow.cancelFlow()
            return
        }

        let tunneled: TunneledFlow
        do {
            tunneled = try await withTimeout(seconds: 30) {
                try await session.openStream(targetHost: targetHost, targetPort: targetPort)
            }
        } catch {
            await handleOpenFailure(targetKey: targetKey, targetPort: targetPort, cause: error)
            tcpFlow.cancelFlow()
            return
        }

        health.observeSuccess()
        forgetUnreachable(targetKey)
        unauthenticatedSession = nil

        do {
            try await tcpFlow.open(withLocalEndpoint: nil)
        } catch {
            tunneled.close()
            return
        }

        await bridgeFlow(tcpFlow: tcpFlow, tunneled: tunneled)
    }

    private func bridgeFlow(tcpFlow: NEAppProxyTCPFlow, tunneled: TunneledFlow) async {
        let relayToUpstream = Task {
            while true {
                guard let data = try await tcpFlow.readData() else { break }
                if data.isEmpty { break }
                let payload = data
                try payload.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    try tunneled.write(base, count: payload.count)
                }
            }
            try? tunneled.halfCloseOutput()
        }

        // Upstream -> flow
        while true {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let n = buffer.withUnsafeMutableBufferPointer { p in
                try? tunneled.read(into: p.baseAddress!, maxCount: p.count)
            }
            guard let n, n > 0 else { break }
            try? await tcpFlow.write(Data(buffer.prefix(n)))
        }
        try? await tcpFlow.write(Data()) // EOF
        relayToUpstream.cancel()
        tunneled.close()
    }

    private func usableSession() async -> H2UpstreamSession? {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let session = session, session.isConnected { return session }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: Failure handling (port of the SOCKS server's refusal logic)

    private func handleOpenFailure(targetKey: String, targetPort: Int, cause: Error) {
        logger.log(.debug, "TunnelProvider", "opening upstream stream failed for \(targetKey): \(cause)")
        if shouldRememberRefusal(cause) {
            rememberUnreachable(targetKey)
        }
        switch health.observeFailure(target: targetKey, cause: cause) {
        case .targetFailure:
            break
        case .sessionUnhealthy:
            logger.log(.warn, "TunnelProvider",
                       "upstream session looks unhealthy: several unrelated destinations failed without a single success; redialling")
            redial()
        case .sessionUnauthenticated:
            logger.log(.warn, "TunnelProvider",
                       "the edge rejected this session's proxy pass (\(cause)); refusing further flows locally and redialling")
            unauthenticatedSession = session
            redial()
        }
    }

    private func shouldRememberRefusal(_ cause: Error) -> Bool {
        guard let rejected = cause as? UpstreamConnectRejected, let code = rejected.statusCode else {
            return false
        }
        return UpstreamHealthTracker.targetUnreachableStatusCodes.contains(code)
    }

    private func isKnownUnreachable(_ key: String) -> Bool {
        refusalLock.lock(); defer { refusalLock.unlock() }
        guard let record = refusedTargets[key] else { return false }
        return Date() < record.expiresAt
    }

    private func rememberUnreachable(_ key: String) {
        refusalLock.lock(); defer { refusalLock.unlock() }
        let record = refusedTargets[key] ?? RefusalRecord()
        record.strikes += 1
        let ttl = min(refusalBaseTTL * pow(2, Double(record.strikes - 1)), refusalMaxTTL)
        record.expiresAt = Date().addingTimeInterval(ttl)
        refusedTargets[key] = record
        if refusedTargets.count > refusalCacheCap {
            // Evict the oldest entry by expiry.
            refusedTargets.removeValue(forKey: refusedTargets.keys.first!)
        }
    }

    private func forgetUnreachable(_ key: String) {
        refusalLock.lock(); defer { refusalLock.unlock() }
        if refusedTargets.removeValue(forKey: key) != nil {
            logger.log(.debug, "TunnelProvider", "\(key) succeeded; clearing its refusal backoff")
        }
    }
}

// MARK: - Small async helpers

extension NEAppProxyTCPFlow {
    /// Tears down both directions of the flow (no `cancelWithError` on iOS).
    func cancelFlow() {
        closeReadWithError(nil)
        closeWriteWithError(nil)
    }

    /// Reads available data; returns nil on flow end/error.
    func readData() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            self.readData { data, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: data)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            write(data) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

/// `withTimeoutOrNull`-style helper for async throws.
func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw UpstreamConnectTimeout(authority: "", message: "operation timed out after \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
