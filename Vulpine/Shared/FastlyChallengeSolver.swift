import Foundation
import CryptoKit

public enum FastlyChallengeError: Error, LocalizedError {
    case solver(String)

    public var errorDescription: String? {
        if case .solver(let m) = self { return m }
        return nil
    }
}

/// Hidden internal marker thrown when a host does not serve a challenge page.
private struct NoChallengePageError: Error {}

private let SOLVE_TIMEOUT_SECONDS: TimeInterval = 60
private let MAX_POST_BACK_ROUNDS = 3

private let SOLVER_USER_AGENT =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

private let POW_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

private let HTML_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

private let CHALLENGE_PREFIX_REGEX = try! NSRegularExpression(pattern: "/_fs-ch-[A-Za-z0-9]+")
private let INIT_CALL_REGEX = try! NSRegularExpression(
    pattern: "init\\((\\[[^\\]]*\\]),\\s*\"([^\"]+)\",\\s*\"([^\"]+)\"")

/// Solves Fastly bot-challenge pages (proof-of-work, PAT, clientmetrics) and
/// installs the resulting cookies into the shared control-plane cookie jar.
public final class FastlyChallengeSolver: @unchecked Sendable {
    private let cookieJar: SimpleCookieJar

    public init(cookieJar: SimpleCookieJar) {
        self.cookieJar = cookieJar
    }

    public func solveAndInstall() async throws {
        var lastError: Error?
        for base in ["https://api.accounts.firefox.com", "https://accounts.firefox.com"] {
            do {
                try await solveOnHost(base: base)
                return
            } catch is NoChallengePageError {
                continue
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FastlyChallengeError.solver("host did not serve a Fastly challenge page")
    }

    // MARK: - Internals

    private func baseOrigin(_ prefixUrl: String) -> String {
        if let idx = prefixUrl.range(of: "/_fs-ch-") {
            return String(prefixUrl[prefixUrl.startIndex..<idx.lowerBound])
        }
        return prefixUrl
    }

    private func solvePow(base: String, targetHex: String) -> String? {
        guard let target = Data(hexEncoded: targetHex), target.count == 32 else { return nil }
        let baseBytes = Array(base.utf8)
        for a in POW_ALPHABET {
            for b in POW_ALPHABET {
                let suffix = Array(String(a).utf8) + Array(String(b).utf8)
                var hashInput = baseBytes
                hashInput.append(contentsOf: suffix)
                let digest = Data(SHA256.hash(data: Data(hashInput)))
                if digest == target { return String(a) + String(b) }
            }
        }
        return nil
    }

    private func attachCookies(_ request: inout URLRequest, session: URLSession) {
        guard let url = request.url else { return }
        if let delegate = session.delegate as? CookieJarURLSessionDelegate {
            let header = delegate.jar.cookieHeader(for: url)
            if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        }
    }

    private func fetchText(_ session: URLSession, url: String, accept: String = HTML_ACCEPT) async throws -> String {
        guard let u = URL(string: url) else { throw FastlyChallengeError.solver("invalid URL \(url)") }
        var request = URLRequest(url: u)
        request.setValue(SOLVER_USER_AGENT, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        attachCookies(&request, session: session)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FastlyChallengeError.solver("GET \(url) returned HTTP \(code)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fetchChallengePage(_ session: URLSession, pageUrl: String) async throws -> (String, Bool) {
        let body = try await fetchText(session, url: pageUrl)
        let isChallenge = body.contains("/_fs-ch-") && body.contains("Client Challenge")
        return (body, isChallenge)
    }

    /// Returns (challengeListJSON, token) from the last init(...) call in the script.
    private func parseChallengeInit(script: String) throws -> (JSONDict, String) {
        let full = NSRange(script.startIndex..., in: script)
        let matches = INIT_CALL_REGEX.matches(in: script, range: full)
        guard let last = matches.last else {
            throw FastlyChallengeError.solver("challenge init() call not found in script")
        }
        guard let listRange = Range(last.range(at: 1), in: script),
              let tokenRange = Range(last.range(at: 2), in: script) else {
            throw FastlyChallengeError.solver("could not read challenge init() arguments")
        }
        let listText = String(script[listRange])
        let token = String(script[tokenRange])
        guard let listData = listText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: listData),
              let challenges = parsed as? [JSONDict], !challenges.isEmpty else {
            throw FastlyChallengeError.solver("could not parse challenge list")
        }
        // Pack the parsed challenges back into an untyped dict list keyed "challenges".
        return (["challenges": challenges], token)
    }

    private func fetchPat(_ session: URLSession, prefixUrl: String, token: String) async throws -> String {
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        guard let url = URL(string: "\(prefixUrl)/pat?token=\(encodedToken)") else {
            throw FastlyChallengeError.solver("invalid PAT URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SOLVER_USER_AGENT, forHTTPHeaderField: "User-Agent")
        request.setValue(baseOrigin(prefixUrl), forHTTPHeaderField: "Origin")
        request.httpBody = Data()
        attachCookies(&request, session: session)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FastlyChallengeError.solver("PAT request returned non-HTTP response")
        }
        if http.statusCode == 400 || http.statusCode == 401 { return "" }
        guard (200..<300).contains(http.statusCode) else {
            throw FastlyChallengeError.solver("PAT request returned HTTP \(http.statusCode)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict else {
            throw FastlyChallengeError.solver("could not parse PAT response")
        }
        let auth = optString(json, "auth", "")
        if auth.isEmpty { throw FastlyChallengeError.solver("empty PAT auth token") }
        return auth
    }

    private func clientMetricsAnswer() -> JSONDict {
        [
            "ty": "clientmetrics",
            "webdriver": false,
            "bot_detection_result": [
                "bot_detected": false,
                "bot_kind": NSNull(),
            ] as JSONDict,
            "browser_metrics": [
                "client_data": "{}",
                "error_trace": NSNull(),
            ] as JSONDict,
            "detector_results": JSONDict(),
            "v": 2,
        ]
    }

    private func answerChallenge(_ session: URLSession, prefixUrl: String, token: String,
                                 challenge: JSONDict) async throws -> JSONDict {
        let data = optDict(challenge, "data")
        let type = optString(challenge, "ty")
        switch type {
        case "pow":
            let base = optString(data, "base", "")
            guard let answer = solvePow(base: base, targetHex: optString(data, "hash", "")) else {
                throw FastlyChallengeError.solver("no proof-of-work solution found for base \(base)")
            }
            return [
                "ty": "pow",
                "base": base,
                "answer": answer,
                "hmac": optString(data, "hmac", ""),
                "expires": optString(data, "expires", ""),
            ]
        case "pat":
            let auth = try await fetchPat(session, prefixUrl: prefixUrl, token: token)
            return ["ty": "pat", "auth": auth]
        case "clientmetrics":
            return clientMetricsAnswer()
        default:
            throw FastlyChallengeError.solver(
                "unsupported Fastly challenge type '\(type)' (captcha cannot be solved automatically)")
        }
    }

    private func installChallengeCookies(solverJar: SimpleCookieJar) throws {
        let cookies = solverJar.snapshotAll()
        if cookies.isEmpty {
            throw FastlyChallengeError.solver("challenge completed but no cookies were issued")
        }
        for cookie in cookies {
            cookieJar.set(name: cookie.name, value: cookie.value, domain: "firefox.com")
        }
    }

    private func makeSolverSession(jar: SimpleCookieJar) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = SOLVE_TIMEOUT_SECONDS
        config.timeoutIntervalForResource = SOLVE_TIMEOUT_SECONDS
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: CookieJarURLSessionDelegate(jar: jar), delegateQueue: nil)
    }

    private func solveOnHost(base: String) async throws {
        let solverJar = SimpleCookieJar()
        let solver = makeSolverSession(jar: solverJar)

        let pageUrl = "\(base)/"
        let (page, isChallenge) = try await fetchChallengePage(solver, pageUrl: pageUrl)
        if !isChallenge { throw NoChallengePageError() }

        guard let prefixMatch = CHALLENGE_PREFIX_REGEX.firstMatch(
            in: page, range: NSRange(page.startIndex..., in: page)),
            let prefixRange = Range(prefixMatch.range, in: page) else {
            throw FastlyChallengeError.solver("challenge asset prefix not found on \(base)")
        }
        let prefixUrl = base + String(page[prefixRange])

        let script = try await fetchText(solver, url: "\(prefixUrl)/script.js?reload=true")
        var parsed = try parseChallengeInit(script: script)
        var challenges = parsed.0["challenges"] as? [JSONDict] ?? []
        var token = parsed.1

        for _ in 0..<MAX_POST_BACK_ROUNDS {
            var answers: [JSONDict] = []
            for challenge in challenges {
                answers.append(try await answerChallenge(solver, prefixUrl: prefixUrl, token: token, challenge: challenge))
            }
            let postBody = try JSONSerialization.data(withJSONObject: ["token": token, "data": answers], options: [.sortedKeys])
            guard let url = URL(string: "\(prefixUrl)/fst-post-back") else {
                throw FastlyChallengeError.solver("invalid post-back URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(SOLVER_USER_AGENT, forHTTPHeaderField: "User-Agent")
            request.setValue(baseOrigin(prefixUrl), forHTTPHeaderField: "Origin")
            request.httpBody = postBody
            attachCookies(&request, session: solver)

            let (data, response) = try await solver.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw FastlyChallengeError.solver("challenge post-back returned HTTP \(code)")
            }
            guard let body = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict else {
                throw FastlyChallengeError.solver("could not parse post-back response")
            }
            if optString(body, "status", "") == "success" {
                let (_, stillChallenged) = try await fetchChallengePage(solver, pageUrl: pageUrl)
                if stillChallenged {
                    throw FastlyChallengeError.solver("challenge cookie not accepted on this exit IP")
                }
                try installChallengeCookies(solverJar: solverJar)
                return
            }
            guard let nextChallenges = body["ch"] as? [JSONDict], !nextChallenges.isEmpty,
                  !optString(body, "tok", "").isEmpty else {
                throw FastlyChallengeError.solver("unexpected post-back response: \(body)")
            }
            challenges = nextChallenges
            token = optString(body, "tok", "")
        }
        throw FastlyChallengeError.solver("Fastly challenge did not complete within \(MAX_POST_BACK_ROUNDS) rounds")
    }
}

