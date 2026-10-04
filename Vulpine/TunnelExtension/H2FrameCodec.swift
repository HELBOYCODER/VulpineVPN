// H2FrameCodec.swift
// Minimal HTTP/2 framing layer for the client side of the Vulpine tunnel.
// Port of the Netty Http2FrameCodec subset used by FoxyVPN's H2UpstreamSession.
// We only need: SETTINGS, WINDOW_UPDATE, PING, GOAWAY, HEADERS (CONNECT),
// DATA, RST_STREAM — client-initiated streams, no HPACK dynamic table games
// beyond the small static table + literal encoding (server responses are
// decoded with full HPACK support via a small built-in decoder).

import Foundation

enum H2Error: Error, CustomStringConvertible {
    case connectionClosed
    case protocolError(String)
    case flowControlError(String)

    var description: String {
        switch self {
        case .connectionClosed: return "HTTP/2 connection closed"
        case .protocolError(let m): return "HTTP/2 protocol error: \(m)"
        case .flowControlError(let m): return "HTTP/2 flow-control error: \(m)"
        }
    }
}

// Frame types
enum H2FrameType: UInt8 {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case rstStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goAway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
}

// Frame flags
struct H2Flags: OptionSet {
    let rawValue: UInt8
    static let endStream = H2Flags(rawValue: 0x1)
    static let ack = H2Flags(rawValue: 0x1)
    static let endHeaders = H2Flags(rawValue: 0x4)
    static let padded = H2Flags(rawValue: 0x8)
    static let priority = H2Flags(rawValue: 0x20)
}

struct H2FrameHeader {
    var length: Int
    var type: H2FrameType
    var flags: H2Flags
    var streamId: Int
}

// MARK: - Settings

struct H2Settings: Equatable {
    var headerTableSize: UInt32?
    var enablePush: Bool?
    var maxConcurrentStreams: Int?
    var initialWindowSize: Int?
    var maxFrameSize: Int?
    var maxHeaderListSize: UInt32?

    static let defaultWindowSize = 65_535
    static let defaultMaxFrameSize = 16_384

    static func clientInitial() -> H2Settings {
        // Mirrors H2UpstreamSession's initialSettings: 16 MiB window, 256 KiB frames, push off.
        H2Settings(headerTableSize: nil, enablePush: false,
                   maxConcurrentStreams: nil,
                   initialWindowSize: 16 * 1024 * 1024,
                   maxFrameSize: 256 * 1024,
                   maxHeaderListSize: nil)
    }
}

// MARK: - Frames

enum H2Frame {
    case settings(H2Settings, ack: Bool)
    case windowUpdate(streamId: Int, increment: Int)
    case ping(payload: UInt64, ack: Bool)
    case goAway(lastStreamId: Int, errorCode: UInt32, debugData: Data)
    case headers(streamId: Int, endStream: Bool, headerBlock: Data)
    case data(streamId: Int, endStream: Bool, payload: Data)
    case rstStream(streamId: Int, errorCode: UInt32)
    case priorityPlaceholder // ignored
}

// MARK: - Codec

/// Parses an inbound byte stream into frames. Not thread-safe; use from the
/// connection's read path only.
final class H2FrameDecoder {
    private var buffer: [UInt8] = []
    var maxFrameSize: Int = H2Settings.defaultMaxFrameSize

    func append(_ data: Data) { buffer.append(contentsOf: [UInt8](data)) }

    func nextFrame() -> H2Frame? {
        guard buffer.count >= 9 else { return nil }
        let length = (Int(buffer[0]) << 16) | (Int(buffer[1]) << 8) | Int(buffer[2])
        guard let type = H2FrameType(rawValue: buffer[3]) else {
            guard buffer.count >= 9 + length else { return nil }
            buffer.removeFirst(9 + length)
            return nextFrame()
        }
        let flags = H2Flags(rawValue: buffer[4])
        var streamId = (Int(buffer[5]) << 24) | (Int(buffer[6]) << 16) | (Int(buffer[7]) << 8) | Int(buffer[8])
        streamId &= 0x7FFF_FFFF
        guard buffer.count >= 9 + length else { return nil }
        let payload = Data(buffer[9..<(9 + length)])
        buffer.removeFirst(9 + length)
        return decode(type: type, flags: flags, streamId: streamId, payload: payload)
    }

    private func decode(type: H2FrameType, flags: H2Flags, streamId: Int, payload: Data) -> H2Frame? {
        switch type {
        case .data:
            var body = payload
            if flags.contains(.padded) {
                guard let padLen = body.first, body.count > padLen else { return nil }
                body = body.dropFirst().dropLast(Int(padLen))
            }
            return .data(streamId: streamId, endStream: flags.contains(.endStream), payload: body)

        case .headers:
            var body = payload
            if flags.contains(.padded) {
                guard let padLen = body.first, body.count > padLen else { return nil }
                body = body.dropFirst().dropLast(Int(padLen))
            }
            if flags.contains(.priority) {
                guard body.count >= 5 else { return nil }
                body = body.dropFirst(5)
            }
            return .headers(streamId: streamId, endStream: flags.contains(.endStream), headerBlock: body)

        case .rstStream:
            guard payload.count >= 4 else { return nil }
            let code = payload.prefix(4).reduce(0) { ($0 << 8) | UInt32($1 & 0xFF) }
            return .rstStream(streamId: streamId, errorCode: code)

        case .settings:
            guard payload.count % 6 == 0 else { return nil }
            var s = H2Settings()
            if !flags.contains(.ack) {
                let bytes = [UInt8](payload)
                var i = 0
                while i + 6 <= bytes.count {
                    let id = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
                    var v: UInt32 = 0
                    for k in 2...5 { v = (v << 8) | UInt32(bytes[i + k]) }
                    switch id {
                    case 0x1: s.headerTableSize = v
                    case 0x2: s.enablePush = v != 0
                    case 0x3: s.maxConcurrentStreams = Int(clamping: v)
                    case 0x4: s.initialWindowSize = Int(clamping: v)
                    case 0x5: s.maxFrameSize = Int(clamping: v); maxFrameSize = Int(clamping: v)
                    case 0x6: s.maxHeaderListSize = v
                    default: break
                    }
                    i += 6
                }
            }
            return .settings(s, ack: flags.contains(.ack))

        case .ping:
            guard payload.count >= 8 else { return nil }
            var v: UInt64 = 0
            for byte in payload.prefix(8) { v = (v << 8) | UInt64(byte) }
            return .ping(payload: v, ack: flags.contains(.ack))

        case .goAway:
            guard payload.count >= 8 else { return nil }
            let bytes = [UInt8](payload)
            let last = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            var code: UInt32 = 0
            for k in 4...7 { code = (code << 8) | UInt32(bytes[k]) }
            let debug = payload.count > 8 ? payload.subdata(in: 8..<payload.count) : Data()
            return .goAway(lastStreamId: last & 0x7FFF_FFFF, errorCode: code, debugData: debug)

        case .windowUpdate:
            guard payload.count >= 4 else { return nil }
            let bytes = [UInt8](payload)
            let inc = (Int(bytes[0]) & 0x7F) << 24 | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            return .windowUpdate(streamId: streamId, increment: inc)

        case .priority, .pushPromise, .continuation:
            return .priorityPlaceholder
        }
    }
}

// MARK: - Encoder

enum H2FrameEncoder {
    static func encode(_ frame: H2Frame, ourMaxFrameSize: Int) -> Data {
        var out = Data()
        switch frame {
        case let .settings(s, ack):
            var payload = Data()
            if !ack {
                func put(_ id: UInt16, _ v: UInt32) {
                    payload.append(UInt8(id >> 8)); payload.append(UInt8(id & 0xFF))
                    for shift in stride(from: 24, through: 0, by: -8) {
                        payload.append(UInt8((v >> UInt32(shift)) & 0xFF))
                    }
                }
                if let v = s.headerTableSize { put(0x1, v) }
                if let v = s.enablePush { put(0x2, v ? 1 : 0) }
                if let v = s.maxConcurrentStreams { put(0x3, UInt32(clamping: v)) }
                if let v = s.initialWindowSize { put(0x4, UInt32(v)) }
                if let v = s.maxFrameSize { put(0x5, UInt32(v)) }
            }
            writeHeader(&out, length: payload.count, type: .settings,
                        flags: ack ? .ack : [], streamId: 0)
            out.append(payload)

        case let .windowUpdate(streamId, increment):
            writeHeader(&out, length: 4, type: .windowUpdate, flags: [], streamId: streamId)
            putUint32(&out, UInt32(increment) & 0x7FFF_FFFF)

        case let .ping(payload, ack):
            writeHeader(&out, length: 8, type: .ping, flags: ack ? .ack : [], streamId: 0)
            var v = payload
            var bytes = [UInt8](repeating: 0, count: 8)
            for i in stride(from: 7, through: 0, by: -1) { bytes[i] = UInt8(v & 0xFF); v >>= 8 }
            out.append(contentsOf: bytes)

        case let .goAway(lastStreamId, errorCode, debugData):
            writeHeader(&out, length: 8 + debugData.count, type: .goAway, flags: [], streamId: 0)
            putUint32(&out, UInt32(lastStreamId) & 0x7FFF_FFFF)
            putUint32(&out, errorCode)
            out.append(debugData)

        case let .headers(streamId, endStream, headerBlock):
            let flags: H2Flags = endStream ? [.endStream, .endHeaders] : [.endHeaders]
            writeHeader(&out, length: headerBlock.count, type: .headers,
                        flags: flags, streamId: streamId)
            out.append(headerBlock)

        case let .data(streamId, endStream, payload):
            writeHeader(&out, length: payload.count, type: .data,
                        flags: endStream ? .endStream : [], streamId: streamId)
            out.append(payload)

        case let .rstStream(streamId, errorCode):
            writeHeader(&out, length: 4, type: .rstStream, flags: [], streamId: streamId)
            putUint32(&out, errorCode)

        case .priorityPlaceholder:
            break
        }
        return out
    }

    /// Splits DATA into frames no larger than `maxFrameSize` and applies END_STREAM.
    static func encodeData(streamId: Int, payload: Data, endStream: Bool, maxFrameSize: Int) -> [Data] {
        var frames: [Data] = []
        var offset = 0
        let bytes = [UInt8](payload)
        if bytes.isEmpty {
            return [encode(.data(streamId: streamId, endStream: endStream, payload: Data()),
                           ourMaxFrameSize: maxFrameSize)]
        }
        while offset < bytes.count {
            let chunkLen = min(maxFrameSize, bytes.count - offset)
            let isLast = (offset + chunkLen) == bytes.count
            let chunk = Data(bytes[offset..<(offset + chunkLen)])
            frames.append(encode(.data(streamId: streamId, endStream: isLast && endStream,
                                       payload: chunk), ourMaxFrameSize: maxFrameSize))
            offset += chunkLen
        }
        return frames
    }

    private static func writeHeader(_ out: inout Data, length: Int, type: H2FrameType,
                                    flags: H2Flags, streamId: Int) {
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(type.rawValue)
        out.append(flags.rawValue)
        putUint32(&out, UInt32(streamId) & 0x7FFF_FFFF)
    }

    private static func putUint32(_ out: inout Data, _ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8((v >> UInt32(shift)) & 0xFF))
        }
    }
}
