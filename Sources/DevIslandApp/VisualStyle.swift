import SwiftUI
import AppKit
import DevIslandCore

extension Preferences {
    var colorScheme: ColorScheme? { theme == .system ? nil : (theme == .light ? .light : .dark) }
    func themeColors(systemScheme: ColorScheme) -> ThemeColors {
        ThemeColors(dark: (colorScheme ?? systemScheme) == .dark, black: theme.isBlack, accentHex: accentHex)
    }
    var accent: Color { Color(hex: accentHex) }
    var showsIsland: Bool { companionVisibility != .mascot }
    var showsMascot: Bool { companionVisibility != .island && !mascotHidden }
}

extension Color {
    static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(Color(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light))
        })
    }
    init(hex: String) { self.init(SRGBColor(hex: hex)) }
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "D97757" }
        return SRGBColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent).hex
    }
}

extension Color {
    init(_ rgb: SRGBColor) { self.init(red: rgb.r, green: rgb.g, blue: rgb.b) }
}
private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors(dark: false, accentHex: "D97757")
}
extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}
struct AppTheme: ViewModifier {
    let preferences: Preferences
    @Environment(\.colorScheme) private var systemScheme
    func body(content: Content) -> some View {
        let scheme = preferences.colorScheme ?? systemScheme
        let colors = preferences.themeColors(systemScheme: systemScheme)
        content.environment(\.colorScheme, scheme).environment(\.themeColors, colors)
            .foregroundStyle(Color(colors.primary)).tint(Color(colors.accent))
    }
}
extension View {
    func appTheme(_ preferences: Preferences) -> some View { modifier(AppTheme(preferences: preferences)) }
}

/// Shared custom vector mark. The d bowl, ascender and detached i share one 5-unit stroke rhythm.
struct DIMonogram: Shape {
    func path(in rect: CGRect) -> Path {
        Path(BrandGeometry.monogram(in: rect))
    }
}
struct DevIslandMark: View {
    var size: CGFloat = 30
    var monochrome = false
    var body: some View {
        DIMonogram().fill(monochrome ? Color.primary : Color(hex: "D97757"), style: FillStyle(eoFill: true))
            .frame(width: size, height: size).accessibilityLabel("Dev Island")
    }
}

struct IslandSurface: ViewModifier {
    let preferences: Preferences
    var radius: CGFloat = 24
    var attachedToTop = false
    private var shape: UnevenRoundedRectangle { UnevenRoundedRectangle(topLeadingRadius: attachedToTop ? 0 : radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: attachedToTop ? 0 : radius) }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.snapshotPreview) private var snapshot
    private var black: Bool { preferences.theme.isBlack }
    private var fill: Color { black ? .black : (scheme == .dark ? Color(hex: "202020") : Color(hex: "F5F5F5")) }
    /// No hairline in black mode, so the island reads as one piece with the notch.
    private var borderOpacity: Double { black ? 0 : (scheme == .dark ? 0.12 : 0.07) }
    func body(content: Content) -> some View {
        content.background { surface.allowsHitTesting(false) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(borderOpacity), lineWidth: 0.5).allowsHitTesting(false))
    }
    @ViewBuilder private var surface: some View {
        // Black is always a solid surface; glass would tint it with the desktop behind.
        if black || reduceTransparency || preferences.surface == .opaque {
            shape.fill(fill)
        } else if snapshot {
            // Static illustrations cannot sample the desktop behind an NSPanel.
            shape.fill(fill.opacity(preferences.surface == .liquid ? 0.97 : 0.99))
                .overlay(shape.fill(preferences.accent.opacity(0.012)))
        } else if #available(macOS 26, *), preferences.surface == .liquid {
            shape.fill(.clear)
                .glassEffect(preferences.glassStyle == .clear ? .clear : .regular, in: shape)
                .overlay(shape.fill(fill.opacity(0.72 + preferences.surfaceDensity * 0.25)))
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(fill.opacity(0.72 + preferences.surfaceDensity * 0.25)))
        }
    }
}

extension View {
    func islandSurface(_ preferences: Preferences, radius: CGFloat = 24, attachedToTop: Bool = false) -> some View {
        modifier(IslandSurface(preferences: preferences, radius: radius, attachedToTop: attachedToTop))
    }
}

@MainActor func applyAppearance(_ preferences: Preferences, to window: NSWindow) {
    switch preferences.theme {
    case .system: window.appearance = nil
    case .light: window.appearance = NSAppearance(named: .aqua)
    case .dark, .black: window.appearance = NSAppearance(named: .darkAqua)
    }
}

/// AppKit controls, attached sheets and color/open panels inherit the same appearance as SwiftUI.
@MainActor final class ThemeCoordinator {
    static let shared = ThemeCoordinator()
    func update(_ preferences: Preferences) {
        switch preferences.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .black: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        for window in NSApp.windows { applyAppearance(preferences, to: window) }
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.themeColors) private var colors
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(colors.onAccent))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(colors.accentFill).opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.45)
    }
}
