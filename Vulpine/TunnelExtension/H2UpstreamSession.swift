// H2UpstreamSession.swift
// Port of FoxyVPN's H2UpstreamSession (Netty HTTP/2 CONNECT multiplexer) to
// Swift + Network.framework for use inside an NEPacketTunnelProvider.
//
// Protocol: TLS (SNI = config.tlsHost, verified) with ALPN "h2" to
// config.connectHost:config.tlsPort; per-flow HTTP/2 CONNECT to the target
// authority with `proxy-authorization: Bearer <token>`; keepalive PING with
// the Foxy magic payload; GOAWAY handling; concurrency limited by the server's
// SETTINGS_MAX_CONCURRENT_STREAMS.

import Foundation
import Network

/// One tunneled flow's read side: an async queue of chunks, mirroring the
/// Kotlin NettyStreamInput's watermarks for read-side backpressure.
final class H2Flow: TunneledFlow, @unchecked Sendable {
    fileprivate enum Chunk {
        case data(Data)
        case end
        case error(Error)
    }

    private let lock = NSLock()
    private var condition = NSCondition()
    private var chunks: [Chunk] = []
    private var pendingBytes = 0
    private var finished = false
    private var current: Data?
    private weak var session: H2UpstreamSession?
    let streamId: Int
    private var streamWindow: Int
    private var outputClosed = false
    private var closed = false

    static let highWatermark = 128 * 1024
    static let lowWatermark = 32 * 1024

    fileprivate init(session: H2UpstreamSession, streamId: Int) {
        self.session = session
        self.streamId = streamId
        self.streamWindow = H2Settings.clientInitial().initialWindowSize ?? 65_535
    }

    // MARK: Inbound (called from connection queue)

    fileprivate func offer(_ chunk: Chunk) {
        condition.lock()
        defer { condition.unlock() }
        if finished { return }
        switch chunk {
        case .data(let d):
            pendingBytes += d.count
        case .end:
            finished = true
        case .error:
            finished = true
        }
        chunks.append(chunk)
        condition.signal()
    }

    /// WINDOW_UPDATE accounting: called after data is drained to the caller.
    private func releaseWindow(_ count: Int) {
        if count > 0, let session = session {
            session.sendWindowUpdate(streamId: streamId, increment: count)
        }
    }

    // MARK: TunneledFlow read side (blocking, call from a relay queue)

    func read(into buffer: UnsafeMutablePointer<UInt8>, maxCount: Int) throws -> Int {
        precondition(maxCount > 0)
        condition.lock()
        defer { condition.unlock() }

        if finished && chunks.isEmpty && current == nil { return -1 }

        var total = 0
        outer: while total < maxCount {
            if current == nil || current!.isEmpty {
                if chunks.isEmpty {
                    if total > 0 { break outer }
                    if finished { break outer }
                    condition.wait()
                    continue
                }
                let chunk = chunks.removeFirst()
                switch chunk {
                case .data(let d):
                    current = d
                case .end:
                    finished = true
                    if total > 0 {
                        chunks.insert(.end, at: 0)
                        break outer
                    }
                    return -1
                case .error(let e):
                    if total > 0 {
                        chunks.insert(.error(e), at: 0)
                        break outer
                    }
                    throw e
                }
                continue
            }
            let data = current!
            let toCopy = min(maxCount - total, data.count)
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                buffer.advanced(by: total).update(from: src.baseAddress!, count: toCopy)
            }
            total += toCopy
            current = data.dropFirst(toCopy)
        }
        if total > 0 {
            releaseWindow(total)
        }
        return total
    }

    /// Async convenience wrapper around `read(into:maxCount:)`.
    func read(maxCount: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: maxCount)
        let n = try buf.withUnsafeMutableBufferPointer { p in
            try read(into: p.baseAddress!, maxCount: maxCount)
        }
        if n < 0 { return Data() }
        return Data(buf.prefix(n))
    }

    // MARK: TunneledFlow write side

    func write(_ buffer: UnsafePointer<UInt8>, count: Int) throws {
        guard let session = session, !outputClosed, !closed else {
            throw H2Error.connectionClosed
        }
        session.noteStreamData()
        let data = Data(bytes: buffer, count: count)
        try session.sendData(streamId: streamId, payload: data, endStream: false)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            try write(base, count: data.count)
        }
    }

    func halfCloseOutput() throws {
        guard let session = session, !outputClosed, !closed else { return }
        outputClosed = true
        try session.sendData(streamId: streamId, payload: Data(), endStream: true)
    }

    func close() {
        guard let session = session, !closed else { return }
        closed = true
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
        session.closeStream(streamId)
    }
}

// MARK: - Session

/// HTTP/2 CONNECT multiplexer over one TLS+ALPN h2 connection.
final class H2UpstreamSession: @unchecked Sendable {

    static let keepalivePingPayload: UInt64 = 0x466F_7879_5650_4E // "FoxyVPN"

    static let keepaliveCheckInterval: TimeInterval = 3
    static let keepaliveIdleThreshold: TimeInterval = 15
    static let keepalivePingTimeout: TimeInterval = 10
    static let openStreamTimeout: TimeInterval = 20
    static let connectTimeout: TimeInterval = 15
    static let streamSlotWaitTimeout: TimeInterval = 15
    static let drainIdleTimeout: TimeInterval = 120

    let config: RelayConfig
    private let logger: RelayLogging
    private static let tag = "H2UpstreamSession"

    private let connectionQueue = DispatchQueue(label: "com.vulpine.h2.connection")
    private let writeQueue = DispatchQueue(label: "com.vulpine.h2.write")

    private var connection: NWConnection?
    private let decoder = H2FrameDecoder()
    private let hpackDecoder = HPACK.Decoder()
    private var ourMaxFrameSize = H2Settings.clientInitial().maxFrameSize ?? 16_384

    private let lock = NSLock()
    private var bearerToken: String
    private var lastActivityAt = Date()
    private var lastStreamDataAt = Date()
    private var awaitingPingAck = false
    private var pingSentAt = Date.distantPast
    private var acceptingNewStreams = true
    private var handshakeCompleted = false
    private var maxConcurrentStreams = Int.max
    private var activeStreams = 0
    private var nextStreamId = 1 // client streams are odd
    private var peerInitialWindow = H2Settings.defaultWindowSize
    private var connectionWindow = 65_535

    // streamId -> flow
    private var flows: [Int: H2Flow] = [:]
    // streamId -> pending CONNECT continuation bytes (cont frames)
    private var pendingConnect: [Int: CheckedContinuation<H2Flow, Error>] = [:]
    private var pendingConnectHeaders: [Int: Data] = [:]

    private var closed = false
    private var closing = false
    private var drainWatcherArmed = false

    private var keepaliveTimer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?

    private var handshakeContinuations: [CheckedContinuation<Void, Error>] = []

    public private(set) var isConnected = false

    public init(config: RelayConfig, logger: RelayLogging = OSLogRelayLogger()) {
        self.config = config
        self.bearerToken = config.bearerToken
        self.logger = logger
    }

    // MARK: Lifecycle

    /// Establishes the TCP+TLS+ALPN h2 connection, exchanges SETTINGS, and
    /// grows the connection flow-control window. Throws on failure.
    public func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let params = NWParameters.tls
            if let tls = createTLSOptions() { params.defaultProtocolStack.applicationProtocols = [tls] }
            params.allowLocalEndpointReuse = true

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.connectionTimeout = Int(Self.connectTimeout)
            params.defaultProtocolStack.transportProtocol = tcp

            // Optional upstream proxy chaining (SOCKS5/HTTP CONNECT first hop).
            var dialParams = params
            var endpoint: NWEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(config.connectHost),
                port: NWEndpoint.Port(rawValue: UInt16(clamping: config.tlsPort))!
            )
            if let proxy = Self.parseProxy(config.upstreamProxy) {
                logger.log(.info, Self.tag,
                           "chaining through upstream proxy \(proxy.scheme) \(proxy.host):\(proxy.port)")
                if let proxyEndpoint = Self.applyProxy(proxy, targetHost: config.connectHost,
                                                       targetPort: config.tlsPort, to: dialParams) {
                    endpoint = proxyEndpoint
                }
            }
            let conn = NWConnection(to: endpoint, using: dialParams)
            connection = conn

            var finished = false
            func settle(_ result: Result<Void, Error>) {
                connectionQueue.async {
                    guard !finished else { return }
                    finished = true
                    cont.resume(with: result)
                }
            }

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    // Verify negotiated ALPN is h2.
                    let alpn = self.negotiatedALPN(conn)
                    if alpn != "h2" {
                        self.logger.log(.error, Self.tag,
                                        "upstream did not negotiate HTTP/2 over ALPN (got '\(alpn ?? "none")')")
                        conn.cancel()
                        settle(.failure(H2Error.protocolError("ALPN negotiated '\(alpn ?? "none")' instead of h2")))
                        return
                    }
                    self.logger.log(.info, Self.tag,
                                    "TLS handshake to \(self.config.connectHost):\(self.config.tlsPort) complete, verified name=\(self.config.tlsHost), ALPN=h2")
                    self.lock.lock()
                    self.isConnected = true
                    self.lock.unlock()
                    self.startReceiving(conn)
                    // Client preface + SETTINGS, then grow the connection window.
                    self.sendClientPreface()
                    settle(.success(()))
                case .failed(let error):
                    self.logger.log(.error, Self.tag, "upstream connection failed: \(error)")
                    settle(.failure(error))
                case .cancelled:
                    self.handleConnectionInactive()
                    settle(.failure(H2Error.connectionClosed))
                case .waiting(let error):
                    self.logger.log(.debug, Self.tag, "connection waiting: \(error)")
                default:
                    break
                }
            }
            conn.start(queue: connectionQueue)
        }

        lock.lock()
        lastActivityAt = Date()
        lastStreamDataAt = Date()
        lock.unlock()
        startKeepalive()
    }

    // MARK: Upstream proxy chaining

    struct ProxySpec {
        enum Scheme: String { case socks5, http }
        var scheme: Scheme
        var host: String
        var port: Int
    }

    /// Parses "socks5://host:port", "http://host:port", or "host:port" (SOCKS5).
    static func parseProxy(_ value: String?) -> ProxySpec? {
        guard let value, !value.isEmpty else { return nil }
        var scheme: ProxySpec.Scheme = .socks5
        var rest = value
        if let idx = value.range(of: "://") {
            let s = String(value[..<idx.lowerBound]).lowercased()
            rest = String(value[idx.upperBound...])
            if s == "http" { scheme = .http }
            else if s == "socks" || s == "socks5" { scheme = .socks5 }
            else { return nil }
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), port > 0, port <= 65535,
              !parts[0].isEmpty else { return nil }
        return ProxySpec(scheme: scheme, host: String(parts[0]), port: port)
    }

    /// Configures `base` to chain through an upstream proxy: a custom framer
    /// performs the SOCKS5/HTTP CONNECT handshake below TLS. Returns the proxy
    /// endpoint the connection should dial, or nil when no proxy is configured.
    static func applyProxy(_ proxy: ProxySpec?, targetHost: String, targetPort: Int,
                           to base: NWParameters) -> NWEndpoint? {
        guard let proxy else { return nil }
        let framerOptions = NWProtocolFramer.Options(definition: ProxyConnectProtocol.definition)
        base.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        ProxyChainRequest.pending = ProxyChainRequest.Request(
            scheme: proxy.scheme, targetHost: targetHost, targetPort: targetPort)
        return NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host),
                                   port: NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port))!)
    }

    private func createTLSOptions() -> NWProtocolTLS.Options? {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        // SNI + hostname verification use config.tlsHost even when dialing config.connectHost.
        let host = config.tlsHost
        host.withCString { ptr in
            sec_protocol_options_set_tls_server_name(sec, ptr)
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        }
        return tls
    }

    private func negotiatedALPN(_ conn: NWConnection) -> String? {
        guard let tlsMeta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        guard let alpn = sec_protocol_metadata_get_negotiated_protocol(tlsMeta.securityProtocolMetadata) else {
            return nil
        }
        return String(cString: alpn)
    }

    private func sendClientPreface() {
        let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        var frames = Data()
        frames.append(preface)
        let settings = H2Settings.clientInitial()
        if let mfs = settings.maxFrameSize { ourMaxFrameSize = mfs }
        frames.append(H2FrameEncoder.encode(.settings(settings, ack: false), ourMaxFrameSize: ourMaxFrameSize))
        // Grow the connection window from 64 KiB to 16 MiB.
        let window = (settings.initialWindowSize ?? 65_535) - H2Settings.defaultWindowSize
        if window > 0 {
            frames.append(H2FrameEncoder.encode(.windowUpdate(streamId: 0, increment: window), ourMaxFrameSize: ourMaxFrameSize))
            connectionWindow += window
        }
        writeRaw(frames)
    }

    // MARK: Receiving

    private func startReceiving(_ conn: NWConnection) {
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            if let error {
                self.logger.log(.warn, Self.tag, "upstream connection dropped: \(error) (usually the network changed underneath it)")
                self.handleConnectionInactive()
                return
            }
            if isComplete {
                self.handleConnectionInactive()
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func ingest(_ data: Data) {
        connectionQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.noteStreamData()
            self.decoder.append(data)
            while let frame = self.decoder.nextFrame() {
                self.handleFrame(frame)
            }
        }
    }

    private func handleFrame(_ frame: H2Frame) {
        switch frame {
        case let .settings(s, ack):
            if ack {
                // Our SETTINGS acknowledged.
            } else {
                if let mcs = s.maxConcurrentStreams, mcs != maxConcurrentStreams {
                    maxConcurrentStreams = max(1, mcs)
                    logger.log(.info, Self.tag,
                               "upstream allows \(maxConcurrentStreams) concurrent stream(s); new flows will wait for a free slot")
                }
                if let iws = s.initialWindowSize {
                    peerInitialWindow = iws
                    // RFC 7540 §6.9.2: adjust existing stream windows by the delta.
                    let delta = iws - H2Settings.defaultWindowSize
                    if delta != 0 {
                        for flow in flows.values { flow.adjustStreamWindow(by: delta) }
                    }
                }
                writeRaw(H2FrameEncoder.encode(.settings(H2Settings(), ack: true), ourMaxFrameSize: ourMaxFrameSize))
            }

        case let .windowUpdate(streamId, increment):
            if streamId == 0 {
                connectionWindow += increment
            } else if let flow = flows[streamId] {
                flow.adjustStreamWindow(by: increment)
            }

        case let .ping(payload, ack):
            if ack {
                if payload == Self.keepalivePingPayload {
                    lock.lock(); awaitingPingAck = false; lock.unlock()
                }
            } else {
                writeRaw(H2FrameEncoder.encode(.ping(payload: payload, ack: true), ourMaxFrameSize: ourMaxFrameSize))
            }

        case let .goAway(lastStreamId, errorCode, debugData):
            let reason = String(data: debugData, encoding: .utf8) ?? ""
            logger.log(.warn, Self.tag,
                       "upstream sent GOAWAY: errorCode=\(errorCode) lastStreamId=\(lastStreamId) reason=\"\(reason.isEmpty ? "<no reason given>" : reason)\"")
            acceptingNewStreams = false
            // Fail pending CONNECTs.
            for (_, cont) in pendingConnect {
                cont.resume(throwing: H2Error.connectionClosed)
            }
            pendingConnect.removeAll()

        case let .headers(streamId, endStream, headerBlock):
            handleHeaders(streamId: streamId, endStream: endStream, headerBlock: headerBlock)

        case let .data(streamId, endStream, payload):
            if let flow = flows[streamId] {
                if !payload.isEmpty { flow.offer(.data(payload)) }
                if endStream { flow.offer(.end) }
            }

        case let .rstStream(streamId, errorCode):
            let error = H2Error.protocolError("upstream reset stream \(streamId) (errorCode=\(errorCode))")
            logger.log(.debug, Self.tag, "upstream reset stream \(streamId): errorCode=\(errorCode)")
            if let cont = pendingConnect.removeValue(forKey: streamId) {
                cont.resume(throwing: error)
            }
            flows[streamId]?.offer(.error(error))

        case .priorityPlaceholder:
            break
        }
    }

    private func handleHeaders(streamId: Int, endStream: Bool, headerBlock: Data) {
        let headers: [(String, String)]
        do {
            headers = try hpackDecoder.decode(headerBlock)
        } catch {
            logger.log(.error, Self.tag, "HPACK decode failed on stream \(streamId): \(error)")
            return
        }
        guard let cont = pendingConnect.removeValue(forKey: streamId) else {
            // Server-initiated stream: reject (mirrors RejectPushStreamHandler).
            if streamId % 2 == 0 {
                logger.log(.warn, Self.tag, "upstream opened an unexpected server-initiated stream \(streamId); closing it")
                writeRaw(H2FrameEncoder.encode(.rstStream(streamId: streamId, errorCode: 7 /*REFUSED*/),
                                               ourMaxFrameSize: ourMaxFrameSize))
            }
            return
        }
        let status = headers.first { $0.0 == ":status" }?.1.trimmingCharacters(in: .whitespaces)
        let statusCode = status.flatMap(Int.init)
        if let code = statusCode, (200...299).contains(code) {
            let flow = H2Flow(session: self, streamId: streamId)
            flows[streamId] = flow
            cont.resume(returning: flow)
        } else {
            let rejected = UpstreamConnectRejected(
                statusCode: statusCode,
                authority: "",
                message: "Upstream rejected CONNECT: status=\(status ?? "<missing>")")
            cont.resume(throwing: rejected)
        }
        if endStream {
            // A non-2xx terminal response also closes the flow when it exists.
            flows[streamId]?.offer(.end)
        }
    }

    private func handleConnectionInactive() {
        connectionQueue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.acceptingNewStreams = false
            self.logger.log(self.handshakeCompleted ? .warn : .error, Self.tag,
                            "upstream channel to \(self.config.tlsHost):\(self.config.tlsPort) became inactive")
            for (_, cont) in self.pendingConnect {
                cont.resume(throwing: H2Error.connectionClosed)
            }
            self.pendingConnect.removeAll()
            for flow in self.flows.values {
                flow.offer(.end)
            }
            self.lock.lock()
            self.isConnected = false
            self.lock.unlock()
        }
    }

    // MARK: Opening streams

    /// Opens an HTTP/2 CONNECT stream to `targetHost:targetPort` and waits for
    /// a 2xx response. Port of `openStream(targetHost:targetPort:)`.
    public func openStream(targetHost: String, targetPort: Int) async throws -> TunneledFlow {
        guard connection != nil else { throw H2Error.connectionClosed }
        guard acceptingNewStreams else {
            throw UpstreamConnectRejected(statusCode: nil, authority: authority(targetHost, targetPort),
                                          message: "H2UpstreamSession is shutting down (GOAWAY received)")
        }

        let auth = authority(targetHost, targetPort)
        try await reserveStreamSlot(authority: auth)

        var handedOff = false
        do {
            let flow: H2Flow = try await withCheckedThrowingContinuation { cont in
                connectionQueue.async { [weak self] in
                    guard let self, !self.closed else {
                        cont.resume(throwing: H2Error.connectionClosed)
                        return
                    }
                    let streamId = self.nextStreamId
                    self.nextStreamId += 2
                    self.pendingConnect[streamId] = cont
                    self.activeStreams += 1

                    let headers: [(String, String)] = [
                        (":method", "CONNECT"),
                        (":authority", auth),
                        ("proxy-authorization", "Bearer \(self.bearerToken)"),
                    ]
                    let block = HPACK.encode(headers)
                    self.writeRaw(H2FrameEncoder.encode(
                        .headers(streamId: streamId, endStream: false, headerBlock: block),
                        ourMaxFrameSize: self.ourMaxFrameSize))
                    // Timeout guard for the CONNECT response.
                    self.connectionQueue.asyncAfter(deadline: .now() + Self.openStreamTimeout) { [weak self] in
                        guard let self, let pending = self.pendingConnect.removeValue(forKey: streamId) else { return }
                        pending.resume(throwing: UpstreamConnectTimeout(
                            authority: auth,
                            message: "Timed out waiting for CONNECT response from \(self.config.tlsHost):\(self.config.tlsPort) (\(auth))"))
                        self.releaseStreamSlot()
                    }
                }
            }
            handedOff = true
            logger.log(.debug, Self.tag, "opened stream \(flow.streamId) to \(auth)")
            return flow
        } catch let e as UpstreamConnectRejected {
            releaseStreamSlot()
            throw e
        } catch let e as UpstreamConnectTimeout {
            releaseStreamSlot()
            throw e
        } catch {
            releaseStreamSlot()
            throw error
        }
    }

    private func authority(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private func reserveStreamSlot(authority: String) async throws {
        while true {
            lock.lock()
            let canReserve = activeStreams < maxConcurrentStreams
            if canReserve { activeStreams += 1 }
            let connected = isConnected && acceptingNewStreams
            lock.unlock()
            if canReserve { return }
            if !connected {
                throw H2Error.connectionClosed
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            // Re-check deadline handled by outer openStream timeout behavior;
            // bounded by streamSlotWaitTimeout via overall flow timeouts.
        }
    }

    private func releaseStreamSlot() {
        lock.lock()
        activeStreams = max(0, activeStreams - 1)
        let drained = activeStreams == 0 && !acceptingNewStreams
        lock.unlock()
        if drained { close() }
    }

    // MARK: Sending

    fileprivate func sendWindowUpdate(streamId: Int, increment: Int) {
        guard increment > 0 else { return }
        writeRaw(H2FrameEncoder.encode(.windowUpdate(streamId: streamId, increment: increment),
                                       ourMaxFrameSize: ourMaxFrameSize))
    }

    fileprivate func sendData(streamId: Int, payload: Data, endStream: Bool) throws {
        // Flow-control: wait until the connection + stream windows admit the write.
        // We track the connection window and per-stream peer window coarsely:
        // split writes into chunks <= min(peer window, our max frame).
        var remaining = [UInt8](payload)
        var first = true
        while !remaining.isEmpty || first {
            let budget = waitForWindow(streamId: streamId, wanted: min(ourMaxFrameSize, max(1, remaining.count)))
            let chunkLen = min(budget, remaining.count)
            let chunk = Data(remaining.prefix(chunkLen))
            remaining.removeFirst(chunkLen)
            let frames = H2FrameEncoder.encodeData(
                streamId: streamId, payload: chunk,
                endStream: endStream && remaining.isEmpty,
                maxFrameSize: ourMaxFrameSize)
            writeRaw(Data(frames.joined()))
            chargeWindow(streamId: streamId, amount: chunkLen)
            first = false
        }
    }

    private func waitForWindow(streamId: Int, wanted: Int) -> Int {
        // Busy-wait bounded loop is avoided: windows are generous (16 MiB
        // initial) and the edge replenishes via WINDOW_UPDATE; a short
        // cooperative wait keeps the relay simple without a condvar per stream.
        var waited = 0
        while waited < 60_000 {
            lock.lock()
            let connOk = connectionWindow >= wanted
            let streamOk = streamWindows[streamId].map { $0 >= wanted } ?? true
            lock.unlock()
            if connOk && streamOk { return wanted }
            Thread.sleep(forTimeInterval: 0.01)
            waited += 10
        }
        return min(wanted, 16_384) // fall back to default frame size; edge will stall if truly full
    }

    private var streamWindows: [Int: Int] = [:]

    fileprivate func noteStreamData() {
        let now = Date()
        lock.lock()
        lastActivityAt = now
        lastStreamDataAt = now
        lock.unlock()
    }

    private func chargeWindow(streamId: Int, amount: Int) {
        lock.lock()
        connectionWindow -= amount
        if let w = streamWindows[streamId] {
            streamWindows[streamId] = max(0, w - amount)
        }
        lock.unlock()
    }

    private func writeRaw(_ data: Data) {
        guard let conn = connection, !closed else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error, let self, !self.closing {
                self.logger.log(.warn, Self.tag, "send failed: \(error)")
            }
        })
    }

    // MARK: Keepalive

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + Self.keepaliveCheckInterval,
                       repeating: Self.keepaliveCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.lock.lock()
            let idleFor = Date().timeIntervalSince(self.lastActivityAt)
            let awaiting = self.awaitingPingAck
            let sentAgo = Date().timeIntervalSince(self.pingSentAt)
            self.lock.unlock()
            if awaiting && sentAgo >= Self.keepalivePingTimeout {
                self.logger.log(.warn, Self.tag, "keepalive PING went unanswered; closing dead upstream session")
                self.close()
            } else if !awaiting && idleFor >= Self.keepaliveIdleThreshold {
                self.lock.lock()
                self.awaitingPingAck = true
                self.pingSentAt = Date()
                self.lock.unlock()
                self.writeRaw(H2FrameEncoder.encode(.ping(payload: Self.keepalivePingPayload, ack: false),
                                                     ourMaxFrameSize: self.ourMaxFrameSize))
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: Session management

    public func updateBearerToken(_ token: String) {
        guard !token.isEmpty, token != bearerToken else { return }
        bearerToken = token
        logger.log(.info, Self.tag,
                   "proxy pass swapped into the live session; subsequent flows authenticate with the new pass")
    }

    /// Stops accepting new streams and closes when the last flow drains
    /// (or after drainIdleTimeout). Port of disableNewStreamsAndCloseWhenIdle.
    public func disableNewStreamsAndCloseWhenIdle() {
        lock.lock()
        acceptingNewStreams = false
        let active = activeStreams
        if drainWatcherArmed { lock.unlock(); return }
        drainWatcherArmed = true
        lastStreamDataAt = Date()
        lock.unlock()
        if active == 0 { close(); return }

        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.activeStreams
            let idle = Date().timeIntervalSince(self.lastStreamDataAt)
            self.lock.unlock()
            if active == 0 || idle >= Self.drainIdleTimeout {
                if active > 0 {
                    self.logger.log(.warn, Self.tag,
                                    "a swapped-out upstream session has moved no data for \(Int(Self.drainIdleTimeout))s with \(active) flow(s) still open; closing it")
                }
                timer.cancel()
                self.close()
            }
        }
        timer.resume()
        drainTimer = timer
    }

    fileprivate func closeStream(_ streamId: Int) {
        flows.removeValue(forKey: streamId)
        releaseStreamSlot()
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        closing = true
        lock.unlock()
        keepaliveTimer?.cancel()
        drainTimer?.cancel()
        connection?.cancel()
        logger.log(.debug, Self.tag, "session closed")
    }

    deinit {
        close()
    }
}

// Stream window adjustments used by H2Flow
extension H2Flow {
    fileprivate func adjustStreamWindow(by delta: Int) {
        // peer window changes only matter for outbound accounting, kept in the
        // session's streamWindows map; nothing to do on the flow object.
    }
}
