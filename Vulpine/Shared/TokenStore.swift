import Foundation

/// Secure persistent store for FxA tokens, mirroring the Kotlin TokenStore that
/// used EncryptedSharedPreferences. On iOS the keychain provides encryption at rest.
public final class TokenStore: @unchecked Sendable {
    private let service: String

    public init(service: String = "com.vauth.vulpine.tokens") {
        self.service = service
    }

    // MARK: - Keychain plumbing

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private func setString(_ key: String, _ value: String?) {
        let query = baseQuery(key)
        if let value {
            let data = Data(value.utf8)
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            }
        } else {
            SecItemDelete(query as CFDictionary)
        }
    }

    private func getString(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Keys

    private static let keyAccessToken = "access_token"
    private static let keyRefreshToken = "refresh_token"
    private static let keyExpiresAt = "expires_at"

    private static let clockSkewToleranceSeconds: Int64 = 60

    // MARK: - API

    public func saveAuth(_ auth: RuntimeAuth) {
        setString(Self.keyAccessToken, auth.accessToken)
        setString(Self.keyRefreshToken, auth.refreshToken)
        setString(Self.keyExpiresAt, String(auth.expiresAtEpochSeconds))
    }

    public func loadAuth() -> RuntimeAuth? {
        guard let access = getString(Self.keyAccessToken), !access.isEmpty else { return nil }
        let refresh = getString(Self.keyRefreshToken).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = Int64(getString(Self.keyExpiresAt) ?? "0") ?? 0
        return RuntimeAuth(accessToken: access, refreshToken: refresh, expiresAtEpochSeconds: expiresAt)
    }

    public func hasValidAccessToken() -> Bool {
        guard let auth = loadAuth() else { return false }
        guard auth.expiresAtEpochSeconds > 0 else { return false }
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        return auth.expiresAtEpochSeconds - nowSeconds > Self.clockSkewToleranceSeconds
    }

    public var hasStoredSession: Bool { loadAuth() != nil }

    public var hasRefreshToken: Bool { loadAuth()?.refreshToken != nil }

    public func clear() {
        setString(Self.keyAccessToken, nil)
        setString(Self.keyRefreshToken, nil)
        setString(Self.keyExpiresAt, nil)
    }
}
