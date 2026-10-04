import Foundation
import os

/// User-Agent presented to the Mozilla VPN control plane.
public let MOZILLA_VPN_USER_AGENT = "MozillaVPN/2.35.0 (sys:ios; iap:true)"

public extension URLRequest {
    /// Applies the standard Mozilla VPN control-plane headers.
    mutating func applyMozillaVpnHeaders() {
        setValue(MOZILLA_VPN_USER_AGENT, forHTTPHeaderField: "User-Agent")
        setValue("application/json", forHTTPHeaderField: "Accept")
    }
}

/// One stored HTTP cookie.
public struct StoredCookie: Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expiresAt: Date

    public init(name: String, value: String, domain: String, path: String = "/", expiresAt: Date = .distantFuture) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
    }
}

/// Simple thread-safe cookie jar keyed by domain, mirroring the Kotlin SimpleCookieJar.
public final class SimpleCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var byDomain: [String: [StoredCookie]] = [:]

    public init() {}

    public func saveFromResponse(url: URL, headers: [AnyHashable: Any]) {
        guard let httpURL = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        lock.lock()
        for cookie in cookies {
            var bucket = byDomain[cookie.domain] ?? []
            bucket.removeAll { $0.name == cookie.name }
            bucket.append(StoredCookie(name: cookie.name, value: cookie.value ?? "",
                                       domain: cookie.domain, path: cookie.path,
                                       expiresAt: cookie.expiresDate ?? .distantFuture))
            byDomain[cookie.domain] = bucket
        }
        lock.unlock()
        _ = httpURL
    }

    public func loadForRequest(url: URL) -> [StoredCookie] {
        guard let host = url.host else { return [] }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        var result: [StoredCookie] = []
        for (domain, cookies) in byDomain {
            if host == domain || host.hasSuffix(".\(domain)") {
                result.append(contentsOf: cookies.filter { $0.expiresAt > now })
            }
        }
        return result
    }

    /// Header dictionary suitable for URLRequest.allHTTPHeaderFields merge.
    public func cookieHeader(for url: URL) -> String {
        loadForRequest(url: url)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    public func set(name: String, value: String, domain: String) {
        lock.lock()
        var bucket = byDomain[domain] ?? []
        bucket.removeAll { $0.name == name }
        bucket.append(StoredCookie(name: name, value: value, domain: domain))
        byDomain[domain] = bucket
        lock.unlock()
    }

    public func snapshotAll() -> [StoredCookie] {
        lock.lock()
        defer { lock.unlock() }
        return byDomain.values.flatMap { $0 }
    }
}

/// Shared HTTP plumbing for the VPN control plane: cookie jar, URLSession,
/// and a hook for VPN-route protection. On iOS, NEPacketTunnelProvider sessions
/// should be created via `makeSession()` while the tunnel provider installs a
/// protecting URLProtocol / stream delegate through `socketProtector`.
public enum ControlPlaneHttp {
    public static let cookieJar = SimpleCookieJar()

    /// Optional hook invoked before control-plane connections are opened so the
    /// active tunnel provider can exclude them from the VPN route.
    public static var socketProtector: ((inout URLSessionConfiguration) -> Void)?

    public static let timeout: TimeInterval = 30

    /// Builds a URLSession wired with the shared cookie jar.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        socketProtector?(&config)
        let delegate = CookieJarURLSessionDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Shared control-plane session.
    public static let client: URLSession = makeSession()
}

/// URLSession delegate that applies a SimpleCookieJar to every task. If no jar
/// is supplied it falls back to the shared control-plane jar.
final class CookieJarURLSessionDelegate: NSObject, URLSessionDataDelegate {
    let jar: SimpleCookieJar

    init(jar: SimpleCookieJar = ControlPlaneHttp.cookieJar) {
        self.jar = jar
    }
    override func urlSession(_ session: URLSession,
                             task: URLSessionTask,
                             willPerformHTTPRedirection response: HTTPURLResponse,
                             newRequest request: URLRequest,
                             completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request)
    }

    override func urlSession(_ session: URLSession,
                             dataTask: URLSessionDataTask,
                             didReceive response: URLResponse,
                             completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, let url = dataTask.currentRequest?.url {
            let headers = (http.allHeaderFields as NSDictionary) as! [AnyHashable: Any]
            jar.saveFromResponse(url: url, headers: headers)
        }
        completionHandler(.allow)
    }
}

public enum ControlPlaneError: Error, LocalizedError {
    case invalidURL(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "invalid control-plane URL: \(u)"
        case .transport(let m): return m
        }
    }
}

public enum ControlPlaneHTTP {
    /// Executes a request against the shared control-plane session, returning the response.
    public static func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        let jarCookies = ControlPlaneHttp.cookieJar.cookieHeader(for: req.url!)
        if !jarCookies.isEmpty {
            let existing = req.value(forHTTPHeaderField: "Cookie")
            req.setValue(existing.map { "\($0); \(jarCookies)" } ?? jarCookies, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await ControlPlaneHttp.client.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ControlPlaneError.transport("non-HTTP response")
        }
        return (data, http)
    }
}
