// EdgeAddressResolver.swift
// Port of FoxyVPN's EdgeAddressResolver: DNS-over-HTTPS resolution of the
// edge hostname against IP-literal DoH endpoints, with a cache and per-endpoint
// failure backoff, raced across endpoints (first endpoint to answer wins).

import Foundation

enum EdgeAddressResolver {
    static let dohPath = "/dns-query"
    static let cacheTTL: TimeInterval = 5 * 60
    static let failureBackoff: TimeInterval = 30 * 60
    static let requestTimeout: TimeInterval = 3
    static let maxResponseBytes = 4096

    static let dnsTypeA = 1
    static let dnsTypeAAAA = 28

    private final class CacheBox: @unchecked Sendable {
        let lock = NSLock()
        var cache: [String: (addresses: [String], at: Date)] = [:]
        var suppressed: [String: Date] = [:]
    }
    private static let box = CacheBox()

    /// Resolves `hostname` over DoH using the configured endpoint addresses.
    /// Returns nil when the endpoints are unusable, the hostname is an address
    /// literal, or every endpoint is in backoff — in which case the caller
    /// dials by hostname via the system resolver.
    static func resolve(hostname: String, endpointAddresses: [String]) async -> String? {
        if endpointAddresses.isEmpty { return nil }

        let host = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        if host.isEmpty { return nil }
        if host.contains(where: { $0.asciiValue != nil && $0.asciiValue! >= 128 }) { return nil }
        if isAddressLiteral(host) { return nil }

        box.lock.lock()
        if let cached = box.cache[host], Date().timeIntervalSince(cached.at) < cacheTTL {
            box.lock.unlock()
            return cached.addresses.first
        }
        var endpoints: [String] = []
        for address in endpointAddresses {
            guard let url = endpointURL(for: address) else { continue }
            if let until = box.suppressed[url], until > Date() { continue }
            endpoints.append(url)
        }
        box.lock.unlock()

        if endpoints.isEmpty {
            return nil
        }

        guard let queryV4 = buildQuery(host, type: dnsTypeA),
              let queryV6 = buildQuery(host, type: dnsTypeAAAA) else {
            return nil
        }

        let addresses: [String] = await withTaskGroup(of: [String]?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    if let v4 = try? await queryOne(endpoint: endpoint, queryV4: queryV4, queryV6: queryV6) {
                        if !v4.isEmpty { return v4 }
                        return [] // endpoint reachable but empty answers
                    } else {
                        suppress(endpoint)
                        return nil
                    }
                }
            }
            for await result in group {
                if let result, !result.isEmpty {
                    group.cancelAll()
                    return result
                }
            }
            return []
        }

        if addresses.isEmpty {
            return nil
        }
        box.lock.lock()
        box.cache[host] = (addresses, Date())
        box.lock.unlock()
        return addresses.first
    }

    static func invalidate() {
        box.lock.lock()
        box.cache.removeAll()
        box.lock.unlock()
    }

    private static func suppress(_ endpoint: String) {
        box.lock.lock()
        box.suppressed[endpoint] = Date().addingTimeInterval(failureBackoff)
        box.lock.unlock()
    }

    private static func endpointURL(for address: String) -> String? {
        let host = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard isAddressLiteral(host) else { return nil }
        let authority = host.contains(":") ? "[\(host)]" : host
        return "https://\(authority)\(dohPath)"
    }

    private static func queryOne(endpoint: String, queryV4: Data, queryV6: Data) async throws -> [String] {
        let v4Response = try await post(endpoint: endpoint, query: queryV4)
        let v4 = parseAddresses(v4Response, wantType: dnsTypeA)
        if !v4.isEmpty { return v4 }

        let v6Response = try await post(endpoint: endpoint, query: queryV6)
        return parseAddresses(v6Response, wantType: dnsTypeAAAA)
    }

    private static func post(endpoint: String, query: Data) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= maxResponseBytes else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: DNS wire format

    static func buildQuery(_ hostname: String, type: Int) -> Data? {
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        if labels.isEmpty { return nil }

        var encodedNameBytes = 1
        for label in labels {
            let bytes = Array(label.utf8)
            if bytes.isEmpty || bytes.count > 63 { return nil }
            encodedNameBytes += 1 + bytes.count
        }
        if encodedNameBytes > 255 { return nil }

        var out = Data(capacity: 12 + encodedNameBytes + 4)
        func putShort(_ v: Int) {
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        putShort(0)                     // ID 0 (DoH tolerates a fixed id over TLS)
        putShort(0x0100)                // flags: recursion desired
        putShort(1)                     // QDCOUNT
        putShort(0); putShort(0); putShort(0)
        for label in labels {
            let bytes = Array(label.utf8)
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
        putShort(type)
        putShort(1)                     // class IN
        return out
    }

    static func parseAddresses(_ response: Data, wantType: Int) -> [String] {
        let bytes = [UInt8](response)
        if bytes.count < 12 { return [] }
        func u8(_ i: Int) -> Int { Int(bytes[i]) }
        func u16(_ i: Int) -> Int { (u8(i) << 8) | u8(i + 1) }

        if u8(3) & 0x0F != 0 { return [] }
        let questionCount = u16(4)
        let answerCount = u16(6)
        if answerCount == 0 { return [] }

        var offset = 12
        for _ in 0..<questionCount {
            guard let next = skipName(bytes, offset) else { return [] }
            offset = next + 4
        }

        let expectedRdLength = wantType == dnsTypeA ? 4 : 16
        var addresses: [String] = []
        for _ in 0..<answerCount {
            guard let next = skipName(bytes, offset) else { return addresses }
            offset = next
            if offset + 10 > bytes.count { return addresses }
            let type = u16(offset)
            let rdLength = u16(offset + 8)
            offset += 10
            if offset + rdLength > bytes.count { return addresses }
            if type == wantType && rdLength == expectedRdLength {
                let raw = Array(bytes[offset..<(offset + rdLength)])
                if let address = formatAddress(raw) {
                    addresses.append(address)
                }
            }
            offset += rdLength
        }
        return addresses
    }

    private static func formatAddress(_ raw: [UInt8]) -> String? {
        switch raw.count {
        case 4:
            return raw.map { String($0) }.joined(separator: ".")
        case 16:
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { ptr in
                raw.withUnsafeBufferPointer { src in
                    ptr.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: 16)
                }
            }
            var buf = [CChar](repeating: 0, count: 46) // INET6_ADDRSTRLEN
            var addrCopy = addr
            let ok = inet_ntop(AF_INET6, &addrCopy, &buf, socklen_t(46))
            guard ok != nil else { return nil }
            return String(cString: buf)
        default:
            return nil
        }
    }

    private static func skipName(_ message: [UInt8], _ start: Int) -> Int? {
        var offset = start
        var consumed = 0
        while offset < message.count {
            let length = Int(message[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 {
                return offset + 2 <= message.count ? offset + 2 : nil
            }
            if length > 63 { return nil }
            offset += 1 + length
            consumed += 1 + length
            if consumed > 255 { return nil }
        }
        return nil
    }

    private static func isAddressLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count != 4 { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber)
                && (Int(part) ?? 256) <= 255
        }
    }
}
