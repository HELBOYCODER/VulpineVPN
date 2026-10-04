import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Errors

public enum FxaAuthError: Error, LocalizedError {
    case api(message: String, errno: Int?, statusCode: Int?)
    case noPendingSession
    case refreshFailed(message: String, permanent: Bool)

    public var errorDescription: String? {
        switch self {
        case .api(let m, _, _): return m
        case .noPendingSession: return "No pending FxA session. Start sign-in again."
        case .refreshFailed(let m, _): return m
        }
    }

    public var isPermanentRefreshRejection: Bool {
        if case .refreshFailed(_, let permanent) = self { return permanent }
        return false
    }
}

public enum LoginStep { case credentials, twoFactor }

public enum SessionStatus {
    case active
    case needsLogin
    case unreachable
}

// MARK: - Constants

private let FXA_AUTH_SERVER = "https://api.accounts.firefox.com/v1"
private let FIREFOX_CLIENT_ID = "5882386c6d801776"
private let OAUTH_SCOPE = "profile https://identity.mozilla.com/apps/vpn"
private let PROTOCOL_VERSION = "identity.mozilla.com/picl/v1/"
private let PBKDF2_ROUNDS = 1000
private let STRETCHED_PW_LEN = 32
private let HKDF_LEN = 32
private let VERIFICATION_METHOD_EMAIL_2FA = "email-2fa"
private let FXA_ERRNO_INVALID_PARAMETER = 107
private let FXA_MAX_CHALLENGE_ATTEMPTS = 5
private let DEFAULT_ACCESS_TOKEN_TTL_SECONDS: Int64 = 24 * 60 * 60

// MARK: - Repository

public final class FxaAuthRepository: @unchecked Sendable {
    private let tokenStore: TokenStore
    private let challengeSolver: FastlyChallengeSolver
    private let lock = NSLock()
    private var _pendingSessionToken: String?

    public init(tokenStore: TokenStore, challengeSolver: FastlyChallengeSolver? = nil) {
        self.tokenStore = tokenStore
        self.challengeSolver = challengeSolver ?? FastlyChallengeSolver(cookieJar: ControlPlaneHttp.cookieJar)
    }

    private var pendingSessionToken: String? {
        get { lock.lock(); defer { lock.unlock() }; return _pendingSessionToken }
        set { lock.lock(); defer { lock.unlock() }; _pendingSessionToken = newValue }
    }

    // MARK: Login

    /// Starts a login. Returns true if a two-factor code is now required,
    /// false when the login completed end-to-end.
    @discardableResult
    public func startLogin(email: String, password: String) async throws -> Bool {
        let data = try await loginAttempt(email: email, password: password)
        guard let sessionToken = data["sessionToken"] as? String else {
            throw FxaAuthError.api(message: "login response had no sessionToken", errno: nil, statusCode: nil)
        }
        pendingSessionToken = sessionToken
        let verified = optBool(data, "verified", false)
        if !verified {
            return true
        }
        try await completeLogin(sessionToken: sessionToken)
        return false
    }

    /// Submits the emailed two-factor code and finishes the login.
    @discardableResult
    public func submitTwoFactorCode(code: String) async throws -> Bool {
        guard let sessionToken = pendingSessionToken else { throw FxaAuthError.noPendingSession }
        _ = try await fxaDo("POST", "/session/verify_code", sessionToken: sessionToken,
                            jsonBody: ["code": code])
        try await completeLogin(sessionToken: sessionToken)
        return false
    }

    // MARK: Session lifecycle

    public func restoreSession() async -> SessionStatus {
        guard let stored = try? tokenStore.loadAuth() else { return .needsLogin }
        if stored.refreshToken == nil && !tokenStore.hasValidAccessToken() {
            try? tokenStore.clear()
            return .needsLogin
        }
        if tokenStore.hasValidAccessToken() { return .active }

        do {
            _ = try await ensureFreshAccessToken()
            return .active
        } catch let failure as FxaAuthError {
            if case .refreshFailed(_, let permanent) = failure, permanent {
                AppLogger.w("FxaAuthRepository", "FxA rejected the stored session; signing out", failure)
                try? tokenStore.clear()
                return .needsLogin
            }
            AppLogger.w("FxaAuthRepository", "could not renew the session right now; staying signed in", failure)
            return .unreachable
        } catch {
            AppLogger.w("FxaAuthRepository", "unexpected error while restoring the session", error)
            return .unreachable
        }
    }

    public func ensureFreshAccessToken(force: Bool = false) async throws -> RuntimeAuth {
        guard let current = tokenStore.loadAuth() else {
            throw FxaAuthError.refreshFailed(message: "Not signed in", permanent: true)
        }
        if !force && tokenStore.hasValidAccessToken() { return current }

        guard let refreshToken = current.refreshToken else {
            throw FxaAuthError.refreshFailed(
                message: "The stored session has no refresh token; sign in again.",
                permanent: true)
        }

        let body: JSONDict = [
            "client_id": FIREFOX_CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": OAUTH_SCOPE,
        ]

        let tokenData: JSONDict
        do {
            tokenData = try await fxaDo("POST", "/oauth/token", jsonBody: body)
        } catch let rejected as FxaAuthError {
            if case .api(let message, _, let statusCode) = rejected {
                throw FxaAuthError.refreshFailed(
                    message: message,
                    permanent: statusCode == 400 || statusCode == 401 || statusCode == 403)
            }
            throw FxaAuthError.refreshFailed(message: "FxA rejected the refresh token", permanent: false)
        } catch {
            throw FxaAuthError.refreshFailed(
                message: "Could not reach the Firefox Accounts server",
                permanent: false)
        }

        let accessToken = optString(tokenData, "access_token")
        guard !accessToken.isEmpty else {
            throw FxaAuthError.refreshFailed(
                message: "FxA returned no access token for the refresh grant",
                permanent: false)
        }

        let renewedRefresh = optString(tokenData, "refresh_token")
        let renewed = RuntimeAuth(
            accessToken: accessToken,
            refreshToken: renewedRefresh.isEmpty ? refreshToken : renewedRefresh,
            expiresAtEpochSeconds: expiryFrom(tokenData))
        tokenStore.saveAuth(renewed)
        return renewed
    }

    public func currentAccessToken() async -> String? {
        do {
            return try await ensureFreshAccessToken().accessToken
        } catch let e as FxaAuthError {
            if case .refreshFailed(_, true) = e { return nil }
            return tokenStore.loadAuth()?.accessToken
        } catch {
            return tokenStore.loadAuth()?.accessToken
        }
    }

    public func refreshAccessToken() async -> RuntimeAuth? {
        do {
            return try await ensureFreshAccessToken(force: true)
        } catch {
            AppLogger.w("FxaAuthRepository", "access token renewal failed", error)
            return nil
        }
    }

    // MARK: - Internals

    private func expiryFrom(_ tokenData: JSONDict) -> Int64 {
        let expiresIn = optInt(tokenData, "expires_in", 0)
        let ttl: Int64 = expiresIn > 0 ? Int64(expiresIn) : DEFAULT_ACCESS_TOKEN_TTL_SECONDS
        return Int64(Date().timeIntervalSince1970) + ttl
    }

    private func completeLogin(sessionToken: String) async throws {
        let tokenData = try await oauthToken(sessionToken: sessionToken)
        guard let accessToken = tokenData["access_token"] as? String else {
            throw FxaAuthError.api(message: "oauth token response had no access_token", errno: nil, statusCode: nil)
        }
        let refresh = optString(tokenData, "refresh_token")
        tokenStore.saveAuth(RuntimeAuth(
            accessToken: accessToken,
            refreshToken: refresh.isEmpty ? nil : refresh,
            expiresAtEpochSeconds: expiryFrom(tokenData)))
        pendingSessionToken = nil
    }

    private func loginAttempt(email: String, password: String, withVerificationMethod: Bool = true) async throws -> JSONDict {
        var body: JSONDict = [
            "email": email,
            "authPW": deriveAuthPw(email: email, password: password),
        ]
        if withVerificationMethod { body["verificationMethod"] = VERIFICATION_METHOD_EMAIL_2FA }
        do {
            return try await fxaDo("POST", "/account/login", jsonBody: body)
        } catch let e as FxaAuthError {
            if case .api(_, let errno, _) = e, errno == FXA_ERRNO_INVALID_PARAMETER, withVerificationMethod {
                return try await loginAttempt(email: email, password: password, withVerificationMethod: false)
            }
            throw e
        }
    }

    private func oauthToken(sessionToken: String) async throws -> JSONDict {
        let body: JSONDict = [
            "client_id": FIREFOX_CLIENT_ID,
            "grant_type": "fxa-credentials",
            "scope": OAUTH_SCOPE,
            "access_type": "offline",
        ]
        return try await fxaDo("POST", "/oauth/token", sessionToken: sessionToken, jsonBody: body)
    }

    private func fxaDo(_ method: String, _ path: String,
                       sessionToken: String? = nil,
                       jsonBody: JSONDict) async throws -> JSONDict {
        guard let url = URL(string: FXA_AUTH_SERVER + path) else {
            throw ControlPlaneError.invalidURL(FXA_AUTH_SERVER + path)
        }
        let bodyBytes = try JSONSerialization.data(withJSONObject: jsonBody, options: [.sortedKeys])
        var tokenId: String?
        var hmacKey: Data?
        if let sessionToken {
            let (id, key) = deriveHawkCredentials(sessionTokenHex: sessionToken)
            tokenId = id
            hmacKey = key
        }

        func buildRequest() -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.applyMozillaVpnHeaders()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if sessionToken != nil, let id = tokenId, let key = hmacKey {
                request.setValue(hawkHeader(method: method, url: url, tokenId: id, hmacKey: key, body: bodyBytes),
                                 forHTTPHeaderField: "Authorization")
            }
            request.httpBody = bodyBytes
            return request
        }

        var (data, response) = try await ControlPlaneHTTP.execute(buildRequest())
        var attempts = 1
        while response.statusCode == 406 && attempts < FXA_MAX_CHALLENGE_ATTEMPTS {
            try await challengeSolver.solveAndInstall()
            (data, response) = try await ControlPlaneHTTP.execute(buildRequest())
            attempts += 1
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        if response.statusCode >= 400 {
            let errorBody = (try? JSONSerialization.jsonObject(with: data)).flatMap { $0 as? JSONDict } ?? [:]
            let errno = hasKey(errorBody, "errno") ? optInt(errorBody, "errno") : nil
            let message = optString(errorBody, "message", text.isEmpty ? "HTTP \(response.statusCode)" : text)
            throw FxaAuthError.api(message: message, errno: errno, statusCode: response.statusCode)
        }
        if text.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)).flatMap { $0 as? JSONDict } ?? [:]
    }

    // MARK: - Crypto

    private func deriveQuickStretch(email: String, password: String) -> Data {
        let salt = Data("\(PROTOCOL_VERSION)quickStretch:\(email)".utf8)
        return pbkdf2HmacSha256(password: Data(password.utf8), salt: salt,
                                iterations: PBKDF2_ROUNDS, keyLengthBytes: STRETCHED_PW_LEN)
    }

    private func deriveAuthPw(email: String, password: String) -> String {
        let quickStretched = deriveQuickStretch(email: email, password: password)
        return hkdf(ikm: quickStretched, info: "\(PROTOCOL_VERSION)authPW", length: HKDF_LEN).hexEncodedString()
    }

    private func deriveHawkCredentials(sessionTokenHex: String) -> (String, Data) {
        let sessionToken = Data(hexEncoded: sessionTokenHex) ?? Data()
        let expanded = hkdf(ikm: sessionToken, info: "\(PROTOCOL_VERSION)sessionToken", length: 64)
        return (expanded.prefix(32).hexEncodedString(), expanded.dropFirst(32))
    }

    private func hawkHeader(method: String, url: URL, tokenId: String, hmacKey: Data, body: Data) -> String {
        let ts = String(Int64(Date().timeIntervalSince1970))
        var nonceBytes = Data(count: 6)
        _ = nonceBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        let nonce = nonceBytes.base64UrlEncodedString()
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let query = comps.percentEncodedQuery ?? ""
        comps.query = nil
        comps.fragment = nil
        var path = comps.percentEncodedPath
        if !query.isEmpty { path += "?\(query)" }

        var payloadHash = ""
        if !body.isEmpty {
            var digest = Data("hawk.1.payload\napplication/json\n".utf8)
            digest.append(body)
            digest.append(Data("\n".utf8))
            payloadHash = Data(SHA256.hash(data: digest)).base64EncodedString()
        }

        let normalized = "hawk.1.header\n\(ts)\n\(nonce)\n\(method.uppercased())\n\(path)\n\(url.host ?? "")\n\(url.port ?? (url.scheme == "https" ? 443 : 80))\n\(payloadHash)\n\n"

        let macB64 = Data(hmacSha256(key: hmacKey, data: Data(normalized.utf8))).base64EncodedString()

        var header = "Hawk id=\"\(tokenId)\", ts=\"\(ts)\", nonce=\"\(nonce)\", mac=\"\(macB64)\""
        if !payloadHash.isEmpty { header += ", hash=\"\(payloadHash)\"" }
        return header
    }
}

// MARK: - Crypto helpers

func hmacSha256(key: Data, data: Data) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    key.withUnsafeBytes { keyBytes in
        data.withUnsafeBytes { dataBytes in
            _ = CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count,
                       dataBytes.baseAddress, data.count, &result)
        }
    }
    return result
}

/// RFC 5869 HKDF-SHA256 with an all-zero salt, matching the Kotlin implementation.
func hkdf(ikm: Data, info: String, length: Int, salt: Data = Data(repeating: 0, count: 32)) -> Data {
    let prk = Data(hmacSha256(key: salt, data: ikm))
    let infoBytes = Data(info.utf8)
    var result = Data()
    var previousBlock = Data()
    var counter: UInt8 = 1
    while result.count < length {
        var block = previousBlock
        block.append(infoBytes)
        block.append(Data([counter]))
        let mac = Data(hmacSha256(key: prk, data: block))
        result.append(mac)
        previousBlock = mac
        counter += 1
    }
    return result.prefix(length)
}

/// PBKDF2-HMAC-SHA256 via CommonCrypto.
func pbkdf2HmacSha256(password: Data, salt: Data, iterations: Int, keyLengthBytes: Int) -> Data {
    var result = Data(repeating: 0, count: keyLengthBytes)
    result.withUnsafeMutableBytes { resultBytes in
        password.withUnsafeBytes { pwBytes in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    resultBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLengthBytes)
            }
        }
    }
    return result
}

// MARK: - Data extensions

public extension Data {
    func hexEncodedString() -> String { map { String(format: "%02x", $0) }.joined() }

    init?(hexEncoded string: String) {
        let chars = Array(string)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self.init(bytes)
    }

    func base64UrlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
