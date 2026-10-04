// HPACK.swift
// Small HPACK codec for the Vulpine HTTP/2 CONNECT tunnel.
// We send one request header shape (CONNECT + :authority + proxy-authorization)
// so encoding uses literal-without-indexing and no dynamic table.
// Decoding supports the static table, Huffman-coded literals, dynamic table
// inserts and dynamic table size updates (needed for server response headers).

import Foundation

enum HPACKError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { "HPACK error: invalid input" }
}

enum HPACK {
    /// Indexed static table entries, 1-based (RFC 7541 Appendix A).
    static let indexedStatic: [(String, String)] = [
        (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"),
        (":path", "/index.html"), (":scheme", "http"), (":scheme", "https"),
        (":status", "200"), (":status", "204"), (":status", "206"), (":status", "304"),
        (":status", "400"), (":status", "404"), (":status", "500"),
        ("accept-charset", ""), ("accept-encoding", "gzip, deflate"),
        ("accept-language", ""), ("accept-ranges", ""), ("accept", ""),
        ("access-control-allow-origin", ""), ("age", ""), ("allow", ""),
        ("authorization", ""), ("cache-control", ""), ("content-disposition", ""),
        ("content-encoding", ""), ("content-language", ""), ("content-length", ""),
        ("content-location", ""), ("content-range", ""), ("content-type", ""),
        ("cookie", ""), ("date", ""), ("etag", ""), ("expect", ""), ("expires", ""),
        ("from", ""), ("host", ""), ("if-match", ""), ("if-modified-since", ""),
        ("if-none-match", ""), ("if-range", ""), ("if-unmodified-since", ""),
        ("last-modified", ""), ("link", ""), ("location", ""), ("max-forwards", ""),
        ("proxy-authenticate", ""), ("proxy-authorization", ""), ("range", ""),
        ("referer", ""), ("refresh", ""), ("retry-after", ""), ("server", ""),
        ("set-cookie", ""), ("strict-transport-security", ""), ("transfer-encoding", ""),
        ("user-agent", ""), ("vary", ""), ("via", ""), ("www-authenticate", ""),
    ]

    // MARK: Encoding

    /// Encodes headers without a dynamic table (literal-without-indexing).
    static func encode(_ headers: [(String, String)]) -> Data {
        var out = Data()
        for (name, value) in headers {
            let lname = name.lowercased()
            if let idx = indexedStatic.firstIndex(where: { $0.0 == lname && $0.1 == value }) {
                putInteger(&out, idx + 1, prefixBits: 7, pattern: 0x80)
                continue
            }
            // Literal without indexing, new name.
            putInteger(&out, 0, prefixBits: 4, pattern: 0x00)
            putString(&out, lname)
            putString(&out, value)
        }
        return out
    }

    private static func putInteger(_ out: inout Data, _ value: Int, prefixBits: Int, pattern: UInt8) {
        let maxPrefix = (1 << prefixBits) - 1
        if value < maxPrefix {
            out.append(pattern | UInt8(value))
        } else {
            out.append(pattern | UInt8(maxPrefix))
            var rest = value - maxPrefix
            while rest >= 128 {
                out.append(UInt8((rest & 0x7F) | 0x80))
                rest >>= 7
            }
            out.append(UInt8(rest))
        }
    }

    private static func putString(_ out: inout Data, _ s: String) {
        let raw = Array(s.utf8)
        // No Huffman encoding (allowed by the spec).
        putInteger(&out, raw.count, prefixBits: 7, pattern: 0x00)
        out.append(contentsOf: raw)
    }

    // MARK: Decoding

    final class Decoder {
        private var dynamicTable: [(name: String, value: String)] = []
        private var dynamicSize = 0
        var maxDynamicTableSize = 4096

        func decode(_ block: Data) throws -> [(String, String)] {
            var headers: [(String, String)] = []
            let bytes = [UInt8](block)
            var pos = 0

            func readInteger(prefixBits: Int) throws -> Int {
                guard pos < bytes.count else { throw HPACKError.invalid("truncated integer") }
                let maxPrefix = (1 << prefixBits) - 1
                var value = Int(bytes[pos] & UInt8(maxPrefix))
                pos += 1
                if value < maxPrefix { return value }
                var shift = 0
                while true {
                    guard pos < bytes.count else { throw HPACKError.invalid("truncated integer") }
                    let b = Int(bytes[pos]); pos += 1
                    value += (b & 0x7F) << shift
                    shift += 7
                    if b & 0x80 == 0 { break }
                    if shift > 28 { throw HPACKError.invalid("integer overflow") }
                }
                return value
            }

            func readString() throws -> String {
                guard pos < bytes.count else { throw HPACKError.invalid("truncated string") }
                let huffman = bytes[pos] & 0x80 != 0
                let length = try readInteger(prefixBits: 7)
                guard pos + length <= bytes.count else { throw HPACKError.invalid("truncated string body") }
                let slice = Array(bytes[pos..<(pos + length)])
                pos += length
                let raw = huffman ? try HuffDecoder.decode(slice) : slice
                return String(decoding: raw, as: UTF8.self)
            }

            while pos < bytes.count {
                let first = bytes[pos]
                if first & 0x80 != 0 {
                    // Indexed header field.
                    let index = try readInteger(prefixBits: 7)
                    guard let pair = lookup(index: index) else {
                        throw HPACKError.invalid("bad index \(index)")
                    }
                    headers.append((pair.0, pair.1))
                } else if first & 0xE0 == 0x20 {
                    // Dynamic table size update.
                    let size = try readInteger(prefixBits: 5)
                    maxDynamicTableSize = size
                    resizeTable()
                } else if first & 0xC0 == 0x40 {
                    // Literal with incremental indexing -> insert into dynamic table.
                    let index = try readInteger(prefixBits: 6)
                    let name: String
                    if index == 0 {
                        name = try readString()
                    } else if let pair = lookup(index: index) {
                        name = pair.0
                    } else {
                        throw HPACKError.invalid("bad name index \(index)")
                    }
                    let value = try readString()
                    insert(name: name, value: value)
                    headers.append((name, value))
                } else {
                    // Literal without indexing (0x00) or never-indexed (0x10).
                    let index = try readInteger(prefixBits: 4)
                    let name: String
                    if index == 0 {
                        name = try readString()
                    } else if let pair = lookup(index: index) {
                        name = pair.0
                    } else {
                        throw HPACKError.invalid("bad name index \(index)")
                    }
                    let value = try readString()
                    headers.append((name, value))
                }
            }
            return headers
        }

        private func lookup(index: Int) -> (String, String)? {
            if index >= 1 && index <= indexedStatic.count {
                return indexedStatic[index - 1]
            }
            let dynIndex = index - indexedStatic.count - 1
            guard dynIndex >= 0 && dynIndex < dynamicTable.count else { return nil }
            return (dynamicTable[dynIndex].name, dynamicTable[dynIndex].value)
        }

        private func insert(name: String, value: String) {
            dynamicTable.insert((name, value), at: 0)
            dynamicSize += name.utf8.count + value.utf8.count + 32
            resizeTable()
        }

        private func resizeTable() {
            while dynamicSize > maxDynamicTableSize && !dynamicTable.isEmpty {
                let last = dynamicTable.removeLast()
                dynamicSize -= last.name.utf8.count + last.value.utf8.count + 32
            }
        }
    }
}

// MARK: - Huffman decode (RFC 7541 Appendix B, canonical decode)

enum HuffDecoder {
    // Canonical code table generated from RFC 7541 Appendix B (see HuffTable.swift).
    private static let entries = HuffTable.entries
    private static let firstCodeByLength = HuffTable.firstCodeByLength
    private static let eosSymbol = 256

    static func decode(_ input: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var code: UInt32 = 0
        var len: UInt8 = 0

        for byte in input {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> UInt8(bitIndex)) & 1
                code = (code << 1) | UInt32(bit)
                len += 1
                guard len <= 30, let first = firstCodeByLength[len] else { continue }
                if code >= first {
                    // Canonical codes of this length occupy [first, first + count).
                    // Find index via table scan bounded by same-length run.
                    if let sym = symbol(forCode: code, length: len) {
                        if sym == eosSymbol { throw HPACKError.invalid("EOS in Huffman string") }
                        out.append(UInt8(sym))
                        code = 0
                        len = 0
                    }
                }
            }
        }
        // Remaining bits must be all-ones padding, fewer than 8.
        if len >= 8 { throw HPACKError.invalid("huffman padding too long") }
        if len > 0 {
            let ones = (UInt32(1) << len) - 1
            if code != ones { throw HPACKError.invalid("invalid huffman padding") }
        }
        return out
    }

    private static func symbol(forCode code: UInt32, length: UInt8) -> Int? {
        var index = 0
        for (bits, first) in firstCodeByLength.sorted(by: { $0.key < $1.key }) {
            guard let count = countByLength[bits] else { continue }
            if bits == length {
                let offset = Int(code - first)
                guard offset >= 0 && offset < count else { return nil }
                return entries[index + offset].symbol
            }
            index += count
        }
        return nil
    }

    private static let countByLength: [UInt8: Int] = {
        var counts: [UInt8: Int] = [:]
        for e in entries { counts[e.bits, default: 0] += 1 }
        return counts
    }()
}
