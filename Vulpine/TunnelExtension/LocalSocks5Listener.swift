// LocalSocks5Listener.swift
// Port of FoxyVPN's LocalSocks5Server (SOCKS5 handshake + CONNECT bridging +
// UDP associate for DNS) to Swift / Network.framework, to run inside the
// packet tunnel extension. TCP CONNECT flows are bridged onto HTTP/2 CONNECT
// streams from the shared H2UpstreamSession; UDP ASSOCIATE is answered only
// for DNS (port 53) and relayed as TCP DoH is not used here — instead it is
// dropped on the floor locally, matching the Kotlin behavior of refusing
// non-DNS UDP and keeping DNS through the session's DNS path.

import Foundation
import Network

final class LocalSocks5Listener: @unchecked Sendable {

    static let connectionLimit = 512
    static let handshakeTimeout: TimeInterval = 10
    static let openStreamTimeout: TimeInterval = 30
    static let halfCloseDrainTimeout: TimeInterval = 2 * 60

    private let port: UInt16
    private let sessionProvider: @Sendable () -> H2UpstreamSession?
    private let onSessionUnhealthy: @Sendable () -> Void
    private let onSessionUnauthenticated: @Sendable (H2UpstreamSession) -> Void
    private let logger: RelayLogging
    private static let tag = "LocalSocks5Listener"

    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "com.vulpine.socks.listener")
    private var activeConnections = 0
    private let connectionLock = NSLock()
    private var unauthenticatedSession: H2UpstreamSession?

    // Refusal backoff cache.
    private final class RefusalRecord {
        var strikes = 0
        var expiresAt = Date.distantPast
    }
    private let refusalLock = NSLock()
    private var refusedTargets: [String: RefusalRecord] = [:]
    private let health = UpstreamHealthTracker()

    init(port: UInt16,
         sessionProvider: @escaping @Sendable () -> H2UpstreamSession?,
         onSessionUnhealthy: @escaping @Sendable () -> Void,
         onSessionUnauthenticated: @escaping @Sendable (H2UpstreamSession) -> Void,
         logger: RelayLogging) {
        self.port = port
        self.sessionProvider = sessionProvider
        self.onSessionUnhealthy = onSessionUnhealthy
        self.onSessionUnauthenticated = onSessionUnauthenticated
        self.logger = logger
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(.ipv4(.loopback), .init(rawValue: port)!)
        let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        guard let listener else {
            logger.log(.error, Self.tag, "failed to bind SOCKS5 listener on 127.0.0.1:\(port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.logger.log(.error, Self.tag, "SOCKS listener failed: \(error)")
            }
        }
        listener.start(queue: listenerQueue)
        self.listener = listener
        logger.log(.info, Self.tag, "SOCKS5 listener on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        refusalLock.lock()
        refusedTargets.removeAll()
        refusalLock.unlock()
        health.reset()
    }

    private func accept(_ connection: NWConnection) {
        connectionLock.lock()
        if activeConnections >= Self.connectionLimit {
            connectionLock.unlock()
            logger.log(.warn, Self.tag, "rejecting SOCKS5 client: connection limit (\(Self.connectionLimit)) reached")
            connection.cancel()
            return
        }
        activeConnections += 1
        connectionLock.unlock()

        connection.start(queue: listenerQueue)
        Task { [weak self] in
            defer {
                self?.connectionLock.lock()
                self?.activeConnections -= 1
                self?.connectionLock.unlock()
            }
            await self?.handle(connection)
        }
    }

    // MARK: SOCKS5 handshake

    private func handle(_ connection: NWConnection) async {
        do {
            let greeting = try await receiveExactly(connection, count: 2, timeout: Self.handshakeTimeout)
            guard greeting[0] == 0x05 else {
                logger.log(.debug, Self.tag, "rejecting client: unsupported SOCKS version \(greeting[0])")
                return
            }
            let nMethods = Int(greeting[1])
            guard nMethods > 0 else {
                try await send(connection, Data([0x05, 0xFF]))
                return
            }
            let methods = try await receiveExactly(connection, count: nMethods, timeout: Self.handshakeTimeout)
            guard methods.contains(0x00) else {
                try await send(connection, Data([0x05, 0xFF]))
                return
            }
            try await send(connection, Data([0x05, 0x00]))

            let request = try await receiveExactly(connection, count: 4, timeout: Self.handshakeTimeout)
            guard request[0] == 0x05 else {
                try await send(connection, socksReply(0x07))
                return
            }
            let cmd = request[1]
            switch cmd {
            case 0x01:
                try await handleConnect(connection, request)
            case 0x03:
                try await handleUdpAssociate(connection, request)
            default:
                try await send(connection, socksReply(0x07))
            }
        } catch {
            logger.log(.debug, Self.tag, "SOCKS5 client connection ended: \(error)")
            connection.cancel()
        }
    }

    private func handleConnect(_ connection: NWConnection, _ request: Data) async throws {
        guard let target = try await readTargetFromStream(connection) else {
            try await send(connection, socksReply(0x08))
            return
        }
        let targetKey = "\(target.host):\(target.port)"

        if isKnownUnreachable(targetKey) {
            logger.log(.debug, Self.tag, "refusing \(targetKey): the edge refused this destination moments ago")
            try await send(connection, socksReply(0x04))
            return
        }

        guard let session = await awaitUsableSession() else {
            try await send(connection, socksReply(0x05))
            return
        }
        if session === unauthenticatedSession {
            try await send(connection, socksReply(0x01))
            return
        }

        let tunneled: TunneledFlow
        do {
            tunneled = try await withTimeout(seconds: Self.openStreamTimeout) {
                try await session.openStream(targetHost: target.host, targetPort: target.port)
            }
        } catch {
            if shouldRememberRefusal(error) { rememberUnreachable(targetKey) }
            switch health.observeFailure(target: targetKey, cause: error) {
            case .targetFailure:
                break
            case .sessionUnhealthy:
                logger.log(.warn, Self.tag,
                           "upstream session looks unhealthy: several unrelated destinations failed without a single success; asking for a redial")
                onSessionUnhealthy()
            case .sessionUnauthenticated:
                logger.log(.warn, Self.tag,
                           "the edge rejected this session's proxy pass (\(error)); refusing further flows on it and redialling")
                unauthenticatedSession = session
                onSessionUnauthenticated(session)
            }
            try await send(connection, socksReply(replyCode(for: error)))
            return
        }

        health.observeSuccess()
        forgetUnreachable(targetKey)
        unauthenticatedSession = nil

        try await send(connection, socksReply(0x00))
        await relay(client: connection, tunneled: tunneled)
    }

    private func relay(client: NWConnection, tunneled: TunneledFlow) async {
        // client -> upstream
        let upstreamTask = Task {
            while true {
                let data: Data? = try? await withCheckedThrowingContinuation { cont in
                    client.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, complete, error in
                        if let error { cont.resume(throwing: error); return }
                        if let data, !data.isEmpty { cont.resume(returning: data); return }
                        cont.resume(returning: complete ? nil : Data())
                    }
                }
                guard let data, !data.isEmpty else { break }
                var payload = data
                try? payload.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    try tunneled.write(base, count: payload.count)
                }
            }
            try? tunneled.halfCloseOutput()
        }

        // upstream -> client
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { p in
                try? tunneled.read(into: p.baseAddress!, maxCount: p.count)
            }
            guard let n, n > 0 else { break }
            _ = try? await send(client, Data(buffer.prefix(n)))
        }
        client.send(content: nil, completion: .contentProcessed { _ in })
        // Allow the client->upstream direction a bounded drain, then tear down.
        let deadline = Date().addingTimeInterval(Self.halfCloseDrainTimeout)
        while Date() < deadline, !upstreamTask.isCancelled, upstreamTask.isCancelled == false {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            break
        }
        upstreamTask.cancel()
        tunneled.close()
        client.cancel()
    }

    private func handleUdpAssociate(_ connection: NWConnection, _ request: Data) async throws {
        guard let target = try await readTargetFromStream(connection) else {
            try await send(connection, socksReply(0x08))
            return
        }
        // DNS only (mirrors the Kotlin server: refuse non-53 UDP).
        guard target.port == 53 || target.port == 0 else {
            try await send(connection, socksReply(0x02))
            return
        }
        guard await awaitUsableSession() != nil else {
            try await send(connection, socksReply(0x05))
            return
        }
        // In the extension, DNS is answered by the tunnel's DNS settings
        // (virtual DNS server), so we acknowledge and keep the control
        // connection open; actual DNS datagrams do not traverse this socket.
        try await send(connection, socksReply(0x00))
        // Drain the client socket until it disconnects.
        while true {
            let chunk = try? await receiveExactly(connection, count: 1, timeout: .infinity)
            if chunk == nil || chunk!.isEmpty { break }
        }
    }

    // MARK: Session availability

    private func awaitUsableSession() async -> H2UpstreamSession? {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let session = sessionProvider(), session.isConnected { return session }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: SOCKS5 address parsing

    private struct SocksTarget {
        var host: String
        var port: Int
    }

    /// Reads ATYP + address + port from the client stream (after the fixed
    /// 4-byte request header has been consumed).
    private func readTargetFromStream(_ connection: NWConnection) async throws -> SocksTarget? {
        let atypData = try await receiveExactly(connection, count: 1, timeout: Self.handshakeTimeout)
        let atyp = atypData[atypData.startIndex]
        var host: String
        switch atyp {
        case 0x01:
            let raw = try await receiveExactly(connection, count: 4, timeout: Self.handshakeTimeout)
            host = [UInt8](raw).map { String($0) }.joined(separator: ".")
        case 0x03:
            let lenData = try await receiveExactly(connection, count: 1, timeout: Self.handshakeTimeout)
            let len = Int(lenData[lenData.startIndex])
            guard len > 0 else { return nil }
            let raw = try await receiveExactly(connection, count: len, timeout: Self.handshakeTimeout)
            host = String(data: raw, encoding: .ascii) ?? ""
            if host.isEmpty { return nil }
        case 0x04:
            let raw = try await receiveExactly(connection, count: 16, timeout: Self.handshakeTimeout)
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { ptr in
                raw.copyBytes(to: ptr.bindMemory(to: UInt8.self).baseAddress!, count: 16)
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            host = String(cString: buf)
        default:
            return nil
        }
        let portData = try await receiveExactly(connection, count: 2, timeout: Self.handshakeTimeout)
        let port = (Int(portData[portData.startIndex]) << 8) | Int(portData[portData.index(after: portData.startIndex)])
        return SocksTarget(host: host, port: port)
    }

    private func socksReply(_ code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    private func replyCode(for cause: Error) -> UInt8 {
        if let rejected = cause as? UpstreamConnectRejected, let status = rejected.statusCode {
            if UpstreamHealthTracker.targetUnreachableStatusCodes.contains(status) { return 0x04 }
            return 0x01
        }
        if cause is UpstreamConnectTimeout { return 0x06 }
        return 0x01
    }

    private func shouldRememberRefusal(_ cause: Error) -> Bool {
        guard let rejected = cause as? UpstreamConnectRejected, let status = rejected.statusCode else {
            return false
        }
        return UpstreamHealthTracker.targetUnreachableStatusCodes.contains(status)
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
        let ttl = min(30 * pow(2, Double(record.strikes - 1)), 10 * 60)
        record.expiresAt = Date().addingTimeInterval(ttl)
        refusedTargets[key] = record
        if refusedTargets.count > 256 {
            refusedTargets.removeValue(forKey: refusedTargets.keys.first!)
        }
    }

    private func forgetUnreachable(_ key: String) {
        refusalLock.lock(); defer { refusalLock.unlock() }
        refusedTargets.removeValue(forKey: key)
    }

    // MARK: Raw socket helpers

    private func receiveExactly(_ connection: NWConnection, count: Int, timeout: TimeInterval) async throws -> Data {
        var collected = Data()
        let deadline = timeout.isInfinite ? Date.distantFuture : Date().addingTimeInterval(timeout)
        while collected.count < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw URLError(.timedOut) }
            let need = count - collected.count
            let chunk: Data? = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: need, maximumLength: need) { data, _, complete, error in
                    if let error { cont.resume(throwing: error); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if complete { cont.resume(returning: nil); return }
                    cont.resume(returning: nil)
                }
            }
            guard let chunk, !chunk.isEmpty else {
                throw URLError(.networkConnectionLost)
            }
            collected.append(chunk)
        }
        return collected
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}
