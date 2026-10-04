import Foundation

// MARK: - Connection / login state

public enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
}

public enum LoginStepState: String {
    case credentials
    case twoFactor
}

// MARK: - Server list models

public struct VpnProtocol: Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var scheme: String
    public var templateString: String

    public init(name: String, host: String = "", port: Int = 0, scheme: String = "", templateString: String = "") {
        self.name = name
        self.host = host
        self.port = port
        self.scheme = scheme
        self.templateString = templateString
    }
}

public struct VpnServerNode: Equatable, Sendable {
    public var hostname: String
    public var port: Int
    public var quarantined: Bool
    public var protocols: [VpnProtocol]

    public init(hostname: String, port: Int = 0, quarantined: Bool = false, protocols: [VpnProtocol] = []) {
        self.hostname = hostname
        self.port = port
        self.quarantined = quarantined
        self.protocols = protocols
    }
}

public struct VpnCity: Equatable, Sendable {
    public var name: String
    public var code: String
    public var servers: [VpnServerNode]

    public init(name: String, code: String, servers: [VpnServerNode] = []) {
        self.name = name
        self.code = code
        self.servers = servers
    }
}

public struct VpnCountry: Equatable, Sendable {
    public var name: String
    public var code: String
    public var cities: [VpnCity]

    public init(name: String, code: String, cities: [VpnCity] = []) {
        self.name = name
        self.code = code
        self.cities = cities
    }
}

public struct ProxyCandidate: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var countryCode: String
    public var countryName: String
    public var cityCode: String

    public var authority: String { "\(host):\(port)" }

    public init(host: String, port: Int, countryCode: String, countryName: String, cityCode: String = "") {
        self.host = host
        self.port = port
        self.countryCode = countryCode
        self.countryName = countryName
        self.cityCode = cityCode
    }
}

// MARK: - Entitlement / auth

public struct Entitlement: Equatable, Sendable {
    public var subscribed: Bool
    public var uid: String
    public var maxBytes: Int64?
    public var limitedBandwidth: Bool
    public var quotaRemaining: Int64?

    public init(subscribed: Bool, uid: String, maxBytes: Int64?, limitedBandwidth: Bool, quotaRemaining: Int64? = nil) {
        self.subscribed = subscribed
        self.uid = uid
        self.maxBytes = maxBytes
        self.limitedBandwidth = limitedBandwidth
        self.quotaRemaining = quotaRemaining
    }
}

public struct RuntimeAuth: Equatable, Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAtEpochSeconds: Int64

    public init(accessToken: String, refreshToken: String?, expiresAtEpochSeconds: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtEpochSeconds = expiresAtEpochSeconds
    }
}

// MARK: - Guardian proxy pass

public struct ProxyPass: Equatable, Sendable {
    public var token: String
    public var expiresAtEpochSeconds: Int64?
    public var quotaMax: Int64?
    public var quotaRemaining: Int64?
    public var quotaReset: Int64?

    public init(token: String, expiresAtEpochSeconds: Int64?, quotaMax: Int64? = nil, quotaRemaining: Int64? = nil, quotaReset: Int64? = nil) {
        self.token = token
        self.expiresAtEpochSeconds = expiresAtEpochSeconds
        self.quotaMax = quotaMax
        self.quotaRemaining = quotaRemaining
        self.quotaReset = quotaReset
    }
}

// MARK: - Lightweight JSON object helpers (mirror org.json opt* semantics)

public typealias JSONDict = [String: Any]

public func optString(_ dict: JSONDict, _ key: String, _ fallback: String = "") -> String {
    if let s = dict[key] as? String { return s }
    if let n = dict[key] as? NSNumber { return n.stringValue }
    return fallback
}

public func optInt(_ dict: JSONDict, _ key: String, _ fallback: Int = 0) -> Int {
    (dict[key] as? NSNumber)?.intValue ?? fallback
}

public func optBool(_ dict: JSONDict, _ key: String, _ fallback: Bool = false) -> Bool {
    (dict[key] as? NSNumber)?.boolValue ?? fallback
}

public func optLong(_ dict: JSONDict, _ key: String, _ fallback: Int64 = 0) -> Int64 {
    (dict[key] as? NSNumber)?.int64Value ?? fallback
}

public func optDict(_ dict: JSONDict, _ key: String) -> JSONDict {
    dict[key] as? JSONDict ?? [:]
}

public func optArray(_ dict: JSONDict, _ key: String) -> [Any] {
    dict[key] as? [Any] ?? []
}

public func hasKey(_ dict: JSONDict, _ key: String) -> Bool {
    dict[key] != nil && !(dict[key] is NSNull)
}

public func isNull(_ dict: JSONDict, _ key: String) -> Bool {
    dict[key] is NSNull
}
