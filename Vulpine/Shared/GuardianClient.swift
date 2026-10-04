import Foundation

public let GUARDIAN_ENDPOINT_DEFAULT = "https://vpn.mozilla.org"

public struct GuardianHTTPError: Error, LocalizedError {
    public let message: String
    public let statusCode: Int?

    public init(message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    public var errorDescription: String? { message }
}

public struct QuotaExceededError: Error, LocalizedError {
    public let message: String
    public init(message: String = "account proxy quota exceeded") { self.message = message }
    public var errorDescription: String? { message }
}

public struct TokenInvalidError: Error, LocalizedError {
    public let message: String
    public init(message: String = "access token was rejected by Guardian") { self.message = message }
    public var errorDescription: String? { message }
}

/// Mozilla Guardian control-plane client: proxy passes, entitlement status and
/// activation against `vpn.mozilla.org/api/v1/fpn/*`. Port of GuardianClient.kt.
public final class GuardianClient: @unchecked Sendable {
    private let challengeSolver: FastlyChallengeSolver

    public init(challengeSolver: FastlyChallengeSolver? = nil) {
        self.challengeSolver = challengeSolver ?? FastlyChallengeSolver(cookieJar: ControlPlaneHttp.cookieJar)
    }

    public func fetchProxyPass(endpoint: String, accessToken: String) async throws -> ProxyPass {
        let url = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/fpn/token"
        let (data, response) = try await authorizedRequest("GET", url: url, accessToken: accessToken)
        switch response.statusCode {
        case 401, 403: throw TokenInvalidError()
        case 429: throw QuotaExceededError()
        default: break
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(response.statusCode) else {
            throw GuardianHTTPError(
                message: "failed to fetch proxy pass: HTTP \(response.statusCode): \(String(text.prefix(2048)))",
                statusCode: response.statusCode)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)).flatMap({ $0 as? JSONDict }) else {
            throw GuardianHTTPError(message: "proxy pass response was not valid JSON", statusCode: response.statusCode)
        }
        let token = optString(body, "token", "")
        if token.isEmpty {
            throw GuardianHTTPError(message: "proxy pass response did not contain a token", statusCode: response.statusCode)
        }
        let headerExpiry = optLong(body, "expires_at", 0)
        return ProxyPass(
            token: token,
            expiresAtEpochSeconds: headerExpiry > 0 ? headerExpiry : jwtExpiryEpochSeconds(token),
            quotaMax: response.value(forHTTPHeaderField: "X-Quota-Limit").flatMap(Int64.init),
            quotaRemaining: response.value(forHTTPHeaderField: "X-Quota-Remaining").flatMap(Int64.init),
            quotaReset: response.value(forHTTPHeaderField: "X-Quota-Reset").flatMap(Int64.init))
    }

    public func fetchUserInfo(endpoint: String, accessToken: String) async throws -> Entitlement {
        let url = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/fpn/status"
        let (data, response) = try await authorizedRequest("GET", url: url, accessToken: accessToken)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(response.statusCode) else {
            throw GuardianHTTPError(
                message: "failed to fetch account info: HTTP \(response.statusCode): \(String(text.prefix(2048)))",
                statusCode: response.statusCode)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)).flatMap({ $0 as? JSONDict }) else {
            throw GuardianHTTPError(message: "account info response was not valid JSON", statusCode: response.statusCode)
        }
        var entitlement = Self.parseEntitlement(body)

        if entitlement.limitedBandwidth {
            if let pass = try? await fetchProxyPass(endpoint: endpoint, accessToken: accessToken) {
                entitlement.quotaRemaining = pass.quotaRemaining ?? entitlement.quotaRemaining
            }
        }
        return entitlement
    }

    public func activateGuardian(endpoint: String, accessToken: String) async throws -> Entitlement {
        let url = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/fpn/activate"
        let (data, response) = try await authorizedRequest("POST", url: url, accessToken: accessToken)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(response.statusCode) else {
            throw GuardianHTTPError(
                message: "failed to activate guardian entitlement: HTTP \(response.statusCode): \(String(text.prefix(2048)))",
                statusCode: response.statusCode)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)).flatMap({ $0 as? JSONDict }) else {
            throw GuardianHTTPError(message: "activate response was not valid JSON", statusCode: response.statusCode)
        }
        return Self.parseEntitlement(body)
    }

    private static func parseEntitlement(_ body: JSONDict) -> Entitlement {
        let maxBytes: Int64?
        if hasKey(body, "maxBytes") && !isNull(body, "maxBytes") {
            let v = optLong(body, "maxBytes", -1)
            maxBytes = v >= 0 ? v : nil
        } else {
            maxBytes = nil
        }
        return Entitlement(
            subscribed: optBool(body, "subscribed", false),
            uid: optString(body, "uid"),
            maxBytes: maxBytes,
            limitedBandwidth: optBool(body, "limited_bandwidth", false))
    }

    private func authorizedRequest(_ method: String, url urlString: String,
                                   accessToken: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw ControlPlaneError.invalidURL(urlString) }

        func buildRequest() -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.applyMozillaVpnHeaders()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if method == "POST" { request.httpBody = Data() }
            return request
        }

        var (data, response) = try await ControlPlaneHTTP.execute(buildRequest())
        if response.statusCode == 406 {
            try await challengeSolver.solveAndInstall()
            (data, response) = try await ControlPlaneHTTP.execute(buildRequest())
        }
        return (data, response)
    }
}

/// Extracts the `exp` claim (epoch seconds) from a JWT payload, if present.
public func jwtExpiryEpochSeconds(_ token: String) -> Int64? {
    let parts = token.split(separator: ".").map(String.init)
    guard parts.count >= 2 else { return nil }
    var b64 = parts[1]
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let payloadData = Data(base64Encoded: b64),
          let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? JSONDict else { return nil }
    let exp = optLong(payload, "exp", 0)
    return exp > 0 ? exp : nil
}
