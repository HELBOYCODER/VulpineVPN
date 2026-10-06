// UpstreamProxyChain.swift
// Upstream proxy chaining (port of the desktop "chain through upstream proxy"
// feature). Performs the first-hop handshake — SOCKS5 (no-auth greeting +
// CONNECT) or HTTP CONNECT — below the TLS layer using an NWProtocolFramer.
//
// The TLS/HTTP2 stack above is unaware of the proxy: the framer buffers the
// TLS ClientHello until the proxy tunnel is established, then passes all bytes
// through untouched.

import Foundation
import Network

/// Description of one chained connection. Set immediately before the
/// NWConnection is created and read by the framer's init (one upstream session
/// creates exactly one connection, so a single pending slot is enough).
enum ProxyChainRequest {

    struct Request {
        var scheme: H2UpstreamSession.ProxySpec.Scheme
        var targetHost: String
        var targetPort: Int
    }

    private static let lock = NSLock()
    private static var _pending: Request?

    static var pending: Request? {
        get { lock.lock(); defer { lock.unlock() }; return _pending }
        set { lock.lock(); _pending = newValue; lock.unlock() }
    }
}

final class ProxyConnectProtocol: NWProtocolFramerImplementation {

    static let definition = NWProtocolFramer.Definition(implementation: ProxyConnectProtocol.self)
    static var label: String { "ProxyConnect" }

    private let request: ProxyChainRequest.Request?
    private var sentHandshake = false
    private var handshakeDone = false
    private var pendingOutput = Data()   // app (TLS) bytes buffered during handshake
    private var inputBuffer = Data()     // proxy bytes accumulated during handshake

    required init(framer: NWProtocolFramer.Instance) {
        request = ProxyChainRequest.pending
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    // MARK: Output (app -> proxy)

    func handleOutput(framer: NWProtocolFramer.Instance,
                      message: NWProtocolFramer.Message,
                      messageLength: Int,
                      isComplete: Bool) {
        if !sentHandshake {
            sentHandshake = true
            framer.writeOutput(data: handshakeBytes())
        }

        // Read the current output message's bytes.
        var out = Data()
        _ = framer.parseOutput(minimumIncompleteLength: 0, maximumLength: max(messageLength, 0)) { buffer, _ in
            guard let buffer else { return 0 }
            out.append(contentsOf: buffer)
            return buffer.count
        }

        if handshakeDone {
            if !out.isEmpty { framer.writeOutput(data: out) }
        } else {
            pendingOutput.append(out)
        }
    }

    private func handshakeBytes() -> Data {
        guard let request else { return Data() }
        let host = request.targetHost
        let port = request.targetPort
        switch request.scheme {
        case .http:
            return Data("CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n".utf8)
        case .socks5:
            let hostBytes = Array(host.utf8)
            var out = Data([0x05, 0x01, 0x00])     // greeting: version 5, 1 method, no-auth
            out.append(0x05); out.append(0x01); out.append(0x00)
            out.append(0x03)                        // ATYP: domain name
            out.append(UInt8(hostBytes.count))
            out.append(contentsOf: hostBytes)
            out.append(UInt8((port >> 8) & 0xFF))
            out.append(UInt8(port & 0xFF))
            return out
        }
    }

    // MARK: Input (proxy -> app)

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        if handshakeDone {
            // Pass everything straight through to the layer above.
            let msg = NWProtocolFramer.Message(definition: Self.definition)
            _ = framer.deliverInputNoCopy(length: .max, message: msg, isComplete: true)
            return 0
        }

        var received = 0
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65536) { buffer, _ in
            guard let buffer else { return 0 }
            inputBuffer.append(contentsOf: buffer)
            received = buffer.count
            return buffer.count
        }
        guard received > 0 else { return 1 }

        guard let consumed = tryCompleteHandshake() else { return 1 }
        handshakeDone = true

        // Flush the buffered TLS ClientHello now that the tunnel is up.
        if !pendingOutput.isEmpty {
            framer.writeOutput(data: pendingOutput)
            pendingOutput.removeAll()
        }

        // Deliver any bytes the proxy sent after its handshake response.
        let leftover = Data(inputBuffer.dropFirst(consumed))
        inputBuffer.removeAll()
        if !leftover.isEmpty {
            let msg = NWProtocolFramer.Message(definition: Self.definition)
            framer.deliverInput(data: leftover, message: msg, isComplete: true)
        }
        return 0
    }

    /// Number of handshake-response bytes consumed, or nil when incomplete.
    private func tryCompleteHandshake() -> Int? {
        guard let request else { return nil }
        switch request.scheme {
        case .http:
            guard let range = inputBuffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: inputBuffer[..<range.lowerBound], as: UTF8.self)
            guard let statusLine = head.split(separator: "\r\n").first,
                  statusLine.contains(" 200") || statusLine.contains(" 2") else { return nil }
            return inputBuffer.distance(from: inputBuffer.startIndex, to: range.upperBound)
        case .socks5:
            guard inputBuffer.count >= 2, inputBuffer[0] == 0x05, inputBuffer[1] == 0x00 else {
                return nil
            }
            guard inputBuffer.count >= 5, inputBuffer[2] == 0x05, inputBuffer[3] == 0x00 else {
                return nil
            }
            let atyp = inputBuffer[4]
            switch atyp {
            case 0x01:
                guard inputBuffer.count >= 12 else { return nil }
                return 12
            case 0x03:
                guard inputBuffer.count >= 5 else { return nil }
                let len = Int(inputBuffer[5])
                let total = 4 + 1 + len + 2
                guard inputBuffer.count >= total else { return nil }
                return total
            case 0x04:
                guard inputBuffer.count >= 22 else { return nil }
                return 22
            default:
                return nil
            }
        }
    }
}
