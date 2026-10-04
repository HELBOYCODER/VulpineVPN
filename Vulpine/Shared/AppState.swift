import Foundation
import Combine

enum UIConnectionState: Equatable {
    case disconnected, connecting, connected
}

struct VpnServer: Identifiable, Hashable {
    let id: String
    let country: String
    let city: String
    let pingMs: Int?
}

struct VpnCountryUI: Identifiable, Hashable {
    let id: String
    let name: String
    let cities: [VpnServer]
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let level: String
    let message: String
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var email: String?
    @Published var connectionState: UIConnectionState = .disconnected
    @Published var selectedServer: VpnServer?
    @Published var countries: [VpnCountryUI] = []
    @Published var logs: [LogEntry] = []
    @Published var themeMode: ThemeMode

    init() {
        themeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "themeMode") ?? "") ?? .system
    }

    func setTheme(_ mode: ThemeMode) {
        themeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "themeMode")
    }

    func log(_ level: String, _ message: String) {
        logs.insert(LogEntry(timestamp: Date(), level: level, message: message), at: 0)
    }

    func exportLogs() -> String {
        let df = ISO8601DateFormatter()
        return logs.map { "\(df.string(from: $0.timestamp)) [\($0.level)] \($0.message)" }.joined(separator: "\n")
    }
}
