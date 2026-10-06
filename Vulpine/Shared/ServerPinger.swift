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
        defer { connection.cancel() }

        let start = Date()
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    var finished = false
                    connection.stateUpdateHandler = { state in
                        guard !finished else { return }
                        switch state {
                        case .ready:
                            finished = true
                            cont.resume()
                        case .failed, .cancelled:
                            finished = true
                            cont.resume()
                        default:
                            break
                        }
                    }
                    connection.start(queue: DispatchQueue(label: "com.vulpine.ping"))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            guard first != nil else { return nil }
            return Int(Date().timeIntervalSince(start) * 1000)
        }
    }
}
