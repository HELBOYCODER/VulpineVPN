// RelayConfig.swift
// Shared types for the Vulpine data plane, ported from FoxyVPN's
// vpn/upstream package (Kotlin). iOS / Network.framework target.

import Foundation
import os

/// Endpoint list for the edge, mirroring the Kotlin server list `hostname:port`.
public struct EdgeEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Full dial configuration for one upstream session.
public struct RelayConfig: Sendable {
    /// Host presented in TLS SNI / verified against the certificate.
    public var tlsHost: String
    /// TCP port of the edge.
    public var tlsPort: Int
    /// Optional alternate address to dial instead of `tlsHost` (edgeAddress override).
    public var edgeAddress: String?
    /// Bearer token sent as `proxy-authorization: Bearer <token>` on every CONNECT.
    public var bearerToken: String
    /// Addresses of DoH endpoints (IP literals) used to resolve `edgeAddress` hostnames.
    public var dohEndpointAddresses: [String]

    public init(tlsHost: String, tlsPort: Int, edgeAddress: String? = nil,
                bearerToken: String, dohEndpointAddresses: [String] = []) {
        self.tlsHost = tlsHost
        self.tlsPort = tlsPort
        self.edgeAddress = edgeAddress
        self.bearerToken = bearerToken
        self.dohEndpointAddresses = dohEndpointAddresses
    }

    /// The address actually dialed on TCP (custom edge address if configured).
    public var connectHost: String { edgeAddress?.isEmpty == false ? edgeAddress! : tlsHost }
}

// MARK: - Errors

/// Port of UpstreamConnectRejectedException: the edge answered CONNECT with a non-2xx status.
public struct UpstreamConnectRejected: Error, CustomStringConvertible {
    public let statusCode: Int?
    public let authority: String
    public let message: String

    public init(statusCode: Int?, authority: String, message: String) {
        self.statusCode = statusCode
        self.authority = authority
        self.message = message
    }

    public var description: String { message }
}

/// Port of UpstreamConnectTimeoutException: the edge never answered in time.
public struct UpstreamConnectTimeout: Error, CustomStringConvertible {
    public let authority: String
    public let message: String

    public init(authority: String, message: String) {
        self.authority = authority
        self.message = message
    }

    public var description: String { message }
}

/// Logging facade so the data plane can run in app, extension, and tests.
public protocol RelayLogging: Sendable {
    func log(_ level: RelayLogLevel, _ tag: String, _ message: String)
}

public enum RelayLogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error

    public static func < (a: RelayLogLevel, b: RelayLogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Minimal logger used by default; prints to os_log on Apple platforms.
public struct OSLogRelayLogger: RelayLogging {
    public init() {}
    public func log(_ level: RelayLogLevel, _ tag: String, _ message: String) {
        #if canImport(os)
        let relayLog = Logger(subsystem: "com.vulpine.tunnel", category: tag)
        switch level {
        case .debug: relayLog.debug("\(message, privacy: .public)")
        case .info: relayLog.info("\(message, privacy: .public)")
        case .warn: relayLog.warning("\(message, privacy: .public)")
        case .error: relayLog.error("\(message, privacy: .public)")
        }
        #else
        print("[\(tag)] \(level): \(message)")
        #endif
    }
}

// MARK: - Tunneled flow

/// A bidirectional byte pipe to one remote destination through the h2 CONNECT
/// tunnel. Equivalent to the Kotlin `TunneledStream` (input/output/close).
public protocol TunneledFlow: AnyObject, Sendable {
    /// Reads up to `buffer.count` bytes; returns 0 when no data is immediately
    /// available, -1 on end-of-stream. Throws on stream error.
    func read(into buffer: UnsafeMutablePointer<UInt8>, maxCount: Int) throws -> Int
    /// Writes all bytes, honoring HTTP/2 flow-control backpressure.
    func write(_ buffer: UnsafePointer<UInt8>, count: Int) throws
    /// Half-close: sends an empty DATA frame with END_STREAM.
    func halfCloseOutput() throws
    /// Full teardown of the stream (RST or close).
    func close()
}
