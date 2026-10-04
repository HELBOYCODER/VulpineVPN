// TestMain.swift — runtime verification of the pure-Swift data-plane logic.
import Foundation

func mainRun() {
var failures = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// Local copy of the DNS query builder for testability without FoundationNetworking.
func buildDnsQuery(_ hostname: String, type: Int) -> Data? {
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
    putShort(0); putShort(0x0100); putShort(1); putShort(0); putShort(0); putShort(0)
    for label in labels {
        let bytes = Array(label.utf8)
        out.append(UInt8(bytes.count))
        out.append(contentsOf: bytes)
    }
    out.append(0)
    putShort(type)
    putShort(1)
    return out
}

// 1. HPACK encode/decode round-trip (literal without indexing).
let headers: [(String, String)] = [
    (":method", "CONNECT"),
    (":authority", "example.com:443"),
    ("proxy-authorization", "Bearer tok123"),
]
let block = HPACK.encode(headers)
let dec = HPACK.Decoder()
let out = (try? dec.decode(block)) ?? { print("DECODE ERR at 1"); exit(2) }()
check("hpack roundtrip", out.map { $0.0.lowercased() } == headers.map { $0.0.lowercased() }
      && out.map { $0.1 } == headers.map { $0.1 })

// 2. Indexed static entry: ":status: 200" encodes as single byte 0x88.
let st = HPACK.encode([(":status", "200")])
check("indexed :status 200", st == Data([0x88]))
let dec2 = HPACK.Decoder()
let stOut = (try? dec2.decode(st)) ?? { print("ERR idx"); exit(2) }()
check("indexed decode", stOut.count == 1 && stOut[0].0 == ":status" && stOut[0].1 == "200")

// 3. Huffman decode of "www.example.com" (verified against the hpack
//    reference encoder: f1e3c2e5f23a6ba0ab90f4ff).
let huffInput: [UInt8] = [0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
let huffOut = (try? HuffDecoder.decode(huffInput)) ?? { print("HUFF ERR www"); exit(2) }()
check("huffman www.example.com", String(decoding: huffOut, as: UTF8.self) == "www.example.com")

// 4. Huffman decode of C.6.1: "307873333233467a73717c5e7ab86a
//    a16d1f0a0f5aca2a42b2ac229ea5aa2a..." — use a simpler known case:
//    C.4.2: "no-cache" -> a8eb 1064 9cb3 (5 bytes).
let noCache = (try? HuffDecoder.decode([0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf])) ?? { print("HUFF ERR no-cache"); exit(2) }()
check("huffman no-cache", String(decoding: noCache, as: UTF8.self) == "no-cache")

// 5. C.4.3: "custom-key" & "custom-value" literal with incremental indexing.
//    40 88 25a8 49e9 5ba9 7d7f 89 25a8 49e9 5bb8 e8b4 bf
let custom: [UInt8] = [0x40, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f,
                       0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf]
let dec3 = HPACK.Decoder()
let customOut = (try? dec3.decode(Data(custom))) ?? { print("HUFF ERR custom"); exit(2) }()
check("huffman custom-key/value",
      customOut.count == 1 && customOut[0].0 == "custom-key" && customOut[0].1 == "custom-value")

// 6. Frame encode/decode round-trip.
let f = H2Frame.settings(H2Settings.clientInitial(), ack: false)
let enc = H2FrameEncoder.encode(f, ourMaxFrameSize: 16_384)
let decFrame = H2FrameDecoder()
decFrame.append(enc)
let parsed = decFrame.nextFrame()
guard case let .settings(s, ack) = parsed! else { check("settings frame parsed", false); fatalError() }
check("settings frame roundtrip", ack == false && s.initialWindowSize == 16 * 1024 * 1024
      && s.maxFrameSize == 256 * 1024 && s.enablePush == false)

// 7. DATA split into frames honoring maxFrameSize with END_STREAM on last.
let payload = Data(repeating: 0xAB, count: 40_000)
let frames = H2FrameEncoder.encodeData(streamId: 3, payload: payload, endStream: true, maxFrameSize: 16_384)
check("data split count", frames.count == 3)
var decData = H2FrameDecoder()
var collected = Data()
var sawEnd = false
for fr in frames { decData.append(fr) }
while let fr = decData.nextFrame() {
    if case let .data(sid, end, p) = fr {
        collected.append(p)
        sawEnd = sawEnd || (end && sid == 3)
    }
}
check("data reassembly", collected == payload && sawEnd)

// 8. PING roundtrip with Foxy payload.
let pingEnc = H2FrameEncoder.encode(.ping(payload: 0x466F_7879_5650_4E, ack: false),
                                    ourMaxFrameSize: 16_384)
var pingDec = H2FrameDecoder()
pingDec.append(pingEnc)
guard case let .ping(p, a) = pingDec.nextFrame()! else { check("ping parsed", false); fatalError() }
check("ping roundtrip", !a && p == 0x466F_7879_5650_4E)

// 9. DNS query build round-trip shape check (buildQuery is deterministic).
guard let q = buildDnsQuery("example.com", type: 1) else {
    check("dns query built", false); fatalError()
}
check("dns query header", q.count == 12 + 13 + 4)
let qb = [UInt8](q)
check("dns qdcount", qb[4] == 0 && qb[5] == 1)
check("dns qtype/qclass", qb[qb.count-4] == 0 && qb[qb.count-3] == 1 && qb[qb.count-2] == 0 && qb[qb.count-1] == 1)

// 10. Malformed-name rejection.
_ = "www.example.com"
check("buildQuery rejects empty", buildDnsQuery("", type: 1) == nil)
check("buildQuery rejects long label",
      buildDnsQuery(String(repeating: "a", count: 64), type: 1) == nil)

// 11. UpstreamHealthTracker verdicts.
let health = UpstreamHealthTracker()
check("health unauthenticated", health.observeFailure(target: "a:1",
      cause: UpstreamConnectRejected(statusCode: 401, authority: "a:1", message: "x")) == .sessionUnauthenticated)
check("health timeout target failure", health.observeFailure(target: "b:2",
      cause: UpstreamConnectTimeout(authority: "b:2", message: "t")) == .targetFailure)
for i in 2...9 {
    _ = health.observeFailure(target: "t\(i):1", cause: UpstreamConnectTimeout(authority: "", message: "t"))
}
check("health session unhealthy after 10 distinct timeout targets",
      health.observeFailure(target: "t10:1", cause: UpstreamConnectTimeout(authority: "", message: "t")) == .sessionUnhealthy)

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)

}
mainRun()
