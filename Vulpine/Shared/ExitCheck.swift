// ExitCheck.swift
// Port of the Kotlin vpn/ExitCheck: after the tunnel is up, fetch the
// public IP through the tunnel and surface it on the Home screen.

import Foundation

enum ExitChecker {
    /// Fetches the public exit IP via ipify (plain HTTP JSON through the tunnel).
    static func fetchExitIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await ControlPlaneHTTP.execute(request)
            guard (200..<300).contains(response.statusCode) else { return nil }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ip = obj["ip"] as? String, !ip.isEmpty else { return nil }
            return ip
        } catch {
            return nil
        }
    }
}
