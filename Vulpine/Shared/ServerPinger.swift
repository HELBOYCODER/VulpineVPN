// ServerPinger.swift
// Port of the Kotlin vpn/PingUtil: measures TCP connect time to an edge
// address (no ICMP on iOS — TCP connect latency is the equivalent signal).

import Foundation
import Network

enum ServerPinger {
    static let timeout: TimeInterval = 4

    /// Measures TCP connect latency in milliseconds to host:port.
    /// Returns nil on failure or timeout.
    static func ping(host: String, port: Int) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: params)
        let start = Date()

        let connected: Bool = await withCheckedContinuation { cont in
            let lock = NSLock()
            var resumed = false
            func finish(_ ok: Bool) {
                lock.lock()
                let alreadyDone = resumed
                resumed = true
                lock.unlock()
                if !alreadyDone { cont.resume(returning: ok) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.vulpine.ping"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }

        connection.cancel()
        guard connected else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }
}
