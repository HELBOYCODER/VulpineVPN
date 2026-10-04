import SwiftUI

@main
struct VulpineApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.email == nil {
                LoginScreen()
            } else {
                HomeScreen()
            }
        }
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch state.themeMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
