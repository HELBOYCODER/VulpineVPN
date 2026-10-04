import SwiftUI

// Port of Color.kt — Material 3 palette (Fox seed 0xFFFF7139)
enum AppTheme {
    static let foxSeed = Color(red: 1.0, green: 0.443, blue: 0.224)

    struct Palette {
        let primary, onPrimary, primaryContainer, onPrimaryContainer: Color
        let secondary, onSecondary, secondaryContainer, onSecondaryContainer: Color
        let tertiary, tertiaryContainer: Color
        let error, errorContainer, onErrorContainer: Color
        let background, onBackground, surface, onSurface: Color
        let surfaceVariant, onSurfaceVariant: Color
        let surfaceContainerLowest, surfaceContainerLow, surfaceContainer: Color
        let surfaceContainerHigh, surfaceContainerHighest: Color
        let outline, outlineVariant: Color
        let inverseSurface, inverseOnSurface: Color
    }

    static let light = Palette(
        primary: Color(hex: 0xA03A00), onPrimary: .white,
        primaryContainer: Color(hex: 0xFFDBCB), onPrimaryContainer: Color(hex: 0x351000),
        secondary: Color(hex: 0x765749), onSecondary: .white,
        secondaryContainer: Color(hex: 0xFFDBCB), onSecondaryContainer: Color(hex: 0x2B160C),
        tertiary: Color(hex: 0x64612E), tertiaryContainer: Color(hex: 0xEBE7A6),
        error: Color(hex: 0xBA1A1A), errorContainer: Color(hex: 0xFFFFDAD6), onErrorContainer: Color(hex: 0x410002),
        background: Color(hex: 0xFFFFF8F6), onBackground: Color(hex: 0x221A16),
        surface: Color(hex: 0xFFFFF8F6), onSurface: Color(hex: 0x221A16),
        surfaceVariant: Color(hex: 0xF5DED5), onSurfaceVariant: Color(hex: 0x53433D),
        surfaceContainerLowest: .white, surfaceContainerLow: Color(hex: 0xFFFFF1EC),
        surfaceContainer: Color(hex: 0xFCEAE4), surfaceContainerHigh: Color(hex: 0xF7E4DE),
        surfaceContainerHighest: Color(hex: 0xF1DED8),
        outline: Color(hex: 0x85736C), outlineVariant: Color(hex: 0xD8C2BA),
        inverseSurface: Color(hex: 0x382E2A), inverseOnSurface: Color(hex: 0xFFFFEDE7))

    static let dark = Palette(
        primary: Color(hex: 0xFFB59B), onPrimary: Color(hex: 0x561D00),
        primaryContainer: Color(hex: 0x7A2C00), onPrimaryContainer: Color(hex: 0xFFDBCB),
        secondary: Color(hex: 0xE6BEAF), onSecondary: Color(hex: 0x442A20),
        secondaryContainer: Color(hex: 0x5C4035), onSecondaryContainer: Color(hex: 0xFFDBCB),
        tertiary: Color(hex: 0xCFCB8D), tertiaryContainer: Color(hex: 0x4B4919),
        error: Color(hex: 0xFFB4AB), errorContainer: Color(hex: 0x93000A), onErrorContainer: Color(hex: 0xFFFFDAD6),
        background: Color(hex: 0x1A1210), onBackground: Color(hex: 0xF1DED8),
        surface: Color(hex: 0x1A1210), onSurface: Color(hex: 0xF1DED8),
        surfaceVariant: Color(hex: 0x53433D), onSurfaceVariant: Color(hex: 0xD8C2BA),
        surfaceContainerLowest: Color(hex: 0x140C0A), surfaceContainerLow: Color(hex: 0x221A16),
        surfaceContainer: Color(hex: 0x271E1A), surfaceContainerHigh: Color(hex: 0x322824),
        surfaceContainerHighest: Color(hex: 0x3D332E),
        outline: Color(hex: 0xA08D85), outlineVariant: Color(hex: 0x53433D),
        inverseSurface: Color(hex: 0xF1DED8), inverseOnSurface: Color(hex: 0x382E2A))

    struct StatusColors {
        let connected, connecting, disconnected: Color
    }

    static func statusColors(_ p: Palette) -> StatusColors {
        StatusColors(connected: Color(hex: 0x1B6E2F),
                     connecting: Color(hex: 0x8A5A00),
                     disconnected: p.onSurfaceVariant)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// Port of ThemeMode.kt
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = AppTheme.light
}
extension EnvironmentValues {
    var appPalette: AppTheme.Palette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

struct VulpineTheme: ViewModifier {
    let mode: ThemeMode
    func body(content: Content) -> some View {
        let scheme: ColorScheme?
        switch mode {
        case .system: scheme = nil
        case .dark: scheme = .dark
        case .light: scheme = .light
        }
        return content
            .environment(\.colorScheme, scheme)
    }
}
