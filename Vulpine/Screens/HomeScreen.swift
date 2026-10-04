import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject var state: AppState
    @State private var pressPulse = false

    var body: some View {
        VStack(spacing: 32) {
            Text("Vulpine VPN")
                .font(.title2).bold()
                .padding(.top, 16)

            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(palette.primary.opacity(0.15))
                        .frame(width: 200, height: 200)
                    Image(systemName: "power")
                        .font(.system(size: 72, weight: .medium))
                        .foregroundStyle(statusColor)
                        .scaleEffect(pressPulse ? 1.06 : 1.0)
                        .animation(.spring(response: 0.3), value: pressPulse)
                }
            }
            .modifier(ImpactFeedbackModifier(trigger: state.connectionState))

            Text(statusLabel)
                .font(.title3)
                .foregroundStyle(statusColor)

            HStack(spacing: 24) {
                statCard(value: state.selectedServer?.country ?? "Auto", label: "Location")
                statCard(value: pingLabel, label: "Ping")
                statCard(value: state.connectionState == .connected ? "On" : "Off", label: "Status")
            }
            .padding(.horizontal)

            NavigationLink { ServerListScreen() } label: {
                Label("Choose location", systemImage: "globe")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var palette: AppTheme.Palette { AppTheme.light }

    private var statusColor: Color {
        let s = AppTheme.statusColors(palette)
        switch state.connectionState {
        case .connected: return s.connected
        case .connecting: return s.connecting
        case .disconnected: return s.disconnected
        }
    }

    private var statusLabel: String {
        switch state.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        }
    }

    private var pingLabel: String {
        guard let ping = state.selectedServer?.pingMs else { return "—" }
        return "\(ping) ms"
    }

    private func toggle() {
        pressPulse.toggle()
        switch state.connectionState {
        case .disconnected: state.connectionState = .connecting
        case .connecting: state.connectionState = .disconnected
        case .connected: state.connectionState = .disconnected
        }
        state.log("INFO", "Power button tapped → \(state.connectionState)")
    }
}

private extension View {
    func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}


/// iOS 16-safe haptic feedback (sensoryFeedback requires iOS 17).
struct ImpactFeedbackModifier<T: Equatable>: ViewModifier {
    let trigger: T
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.sensoryFeedback(.impact, trigger: trigger)
        } else {
            content
        }
    }
}
