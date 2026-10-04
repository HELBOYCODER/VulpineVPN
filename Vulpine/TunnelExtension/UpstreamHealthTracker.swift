// UpstreamHealthTracker.swift
// Port of FoxyVPN's UpstreamHealthTracker to Swift.

import Foundation

/// Classifies connect failures to decide whether the target, the session's
/// health, or the session's authentication is at fault.
final class UpstreamHealthTracker: @unchecked Sendable {
    enum Verdict: Equatable {
        /// The destination itself failed; nothing to do about the session.
        case targetFailure
        /// Several unrelated destinations timed out without a success:
        /// the tunnel is the likelier cause; ask for a redial.
        case sessionUnhealthy
        /// The edge rejected the session's proxy pass (401/403/407).
        case sessionUnauthenticated
    }

    static let maxDistinctTimeoutTargets = 10

    /// Statuses meaning the proxy pass was rejected outright.
    static let sessionFatalStatusCodes: Set<Int> = [401, 403, 407]
    /// Statuses meaning the edge cannot reach the destination (but the tunnel works).
    static let targetUnreachableStatusCodes: Set<Int> = [502, 503, 504]

    private let lock = NSLock()
    private var timeoutTargets = LinkedHashSet<String>()

    func observeSuccess() {
        lock.lock(); defer { lock.unlock() }
        timeoutTargets.removeAll()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        timeoutTargets.removeAll()
    }

    func observeFailure(target: String, cause: Error?) -> Verdict {
        lock.lock(); defer { lock.unlock() }

        if invalidatesSession(cause) {
            timeoutTargets.removeAll()
            return .sessionUnauthenticated
        }

        guard isSilence(cause) else { return .targetFailure }

        timeoutTargets.insert(target)
        if timeoutTargets.count < Self.maxDistinctTimeoutTargets {
            return .targetFailure
        }
        timeoutTargets.removeAll()
        return .sessionUnhealthy
    }

    private func isSilence(_ cause: Error?) -> Bool {
        guard let cause else { return true }
        if cause is UpstreamConnectTimeout { return true }
        let ns = cause as NSError
        return ns.domain == NSURLErrorDomain &&
            (ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorNetworkConnectionLost)
    }

    private func invalidatesSession(_ cause: Error?) -> Bool {
        guard let rejected = cause as? UpstreamConnectRejected, let code = rejected.statusCode else {
            return false
        }
        return Self.sessionFatalStatusCodes.contains(code)
    }
}

/// Tiny insertion-ordered set (Kotlin LinkedHashSet equivalent).
struct LinkedHashSet<Element: Hashable> {
    private(set) var elements: [Element] = []
    private var index: Set<Element> = []

    var count: Int { elements.count }
    var isEmpty: Bool { elements.isEmpty }

    mutating func insert(_ element: Element) {
        guard !index.contains(element) else { return }
        elements.append(element)
        index.insert(element)
    }

    mutating func removeAll() {
        elements.removeAll()
        index.removeAll()
    }
}
