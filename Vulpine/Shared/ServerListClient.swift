import Foundation

/// Fetches the Mozilla VPN server list from Remote Settings and turns it into
/// typed models / proxy candidates. Port of the Kotlin ServerListClient.
public final class ServerListClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = ControlPlaneHttp.client) {
        self.session = session
    }

    private static let remoteSettingsURL =
        "https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records"

    public static let recommendedCountryCode = "REC"

    private static let excludedCountryNames: Set<String> = ["CatchAll Anycast"]

    public func fetchCountries() async throws -> [VpnCountry] {
        guard let url = URL(string: Self.remoteSettingsURL) else {
            throw ControlPlaneError.invalidURL(Self.remoteSettingsURL)
        }
        var request = URLRequest(url: url)
        request.applyMozillaVpnHeaders()
        let (data, response) = try await ControlPlaneHTTP.execute(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GuardianHTTPError(message: "Remote Settings fetch failed: HTTP \(response.statusCode)",
                                    statusCode: response.statusCode)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)).flatMap({ $0 as? JSONDict }) else {
            throw GuardianHTTPError(message: "Remote Settings returned invalid JSON", statusCode: response.statusCode)
        }
        let records = optArray(body, "data")
        var countries: [VpnCountry] = []
        for record in records {
            guard let recordDict = record as? JSONDict else { continue }
            let countryJson = optDict(recordDict, "country").isEmpty ? recordDict : optDict(recordDict, "country")
            let country = Self.parseCountry(countryJson)
            let isExcluded = Self.excludedCountryNames.contains { $0.caseInsensitiveCompare(country.name) == .orderedSame }
            if !country.code.isEmpty && !country.cities.isEmpty && !isExcluded {
                countries.append(country)
            }
        }
        AppLogger.i("ServerListClient", "fetched \(countries.count) countries from Remote Settings")
        return countries
    }

    private static func parseCountry(_ json: JSONDict) -> VpnCountry {
        VpnCountry(
            name: optString(json, "name"),
            code: optString(json, "code"),
            cities: optArray(json, "cities").compactMap { ($0 as? JSONDict).map(parseCity) })
    }

    private static func parseCity(_ json: JSONDict) -> VpnCity {
        VpnCity(
            name: optString(json, "name"),
            code: optString(json, "code"),
            servers: optArray(json, "servers").compactMap { ($0 as? JSONDict).map(parseServer) })
    }

    private static func parseServer(_ json: JSONDict) -> VpnServerNode {
        VpnServerNode(
            hostname: optString(json, "hostname"),
            port: optInt(json, "port", 0),
            quarantined: optBool(json, "quarantined", false),
            protocols: optArray(json, "protocols").compactMap { ($0 as? JSONDict).map(parseProtocol) })
    }

    private static func parseProtocol(_ json: JSONDict) -> VpnProtocol {
        VpnProtocol(
            name: optString(json, "name"),
            host: optString(json, "host"),
            port: optInt(json, "port", 0),
            scheme: optString(json, "scheme"),
            templateString: optString(json, "templateString"))
    }

    // MARK: - Target selection

    public static func defaultConnectTarget(server: VpnServerNode) -> (String, Int)? {
        for proto in server.protocols where proto.name == "connect" {
            let host = proto.host.isEmpty ? server.hostname : proto.host
            let port = proto.port != 0 ? proto.port : server.port
            return (host, port)
        }
        if server.protocols.isEmpty { return (server.hostname, server.port) }
        return nil
    }

    public static func candidates(forCountry countries: [VpnCountry], countryCode: String) -> [ProxyCandidate] {
        var out: [ProxyCandidate] = []
        for country in countries {
            guard country.code.caseInsensitiveCompare(countryCode) == .orderedSame else { continue }
            for city in country.cities {
                for server in city.servers where !server.quarantined {
                    guard let target = defaultConnectTarget(server: server) else { continue }
                    out.append(ProxyCandidate(host: target.0, port: target.1,
                                              countryCode: country.code, countryName: country.name,
                                              cityCode: city.code))
                }
            }
        }
        return out
    }

    public static func candidates(forCity countries: [VpnCountry], countryCode: String, cityCode: String) -> [ProxyCandidate] {
        candidates(forCountry: countries, countryCode: countryCode).filter {
            $0.cityCode.caseInsensitiveCompare(cityCode) == .orderedSame
        }
    }
}
