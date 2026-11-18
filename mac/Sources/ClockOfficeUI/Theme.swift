import SwiftUI
import AppKit
import ClockOfficeCore

/// The palette: a warm panel and one accent that means "this session needs you". The accent is orange; a private
/// look (see `Edition`) may set its own.
public struct Theme: Sendable {
    public var panel: Color, ink: Color, sub: Color, hair: Color, accent: Color, field: Color, hover: Color
    public var rule: Color
    /// The row that is open in the window's sidebar.
    public var select: Color
    /// The fill behind the user's own messages in a conversation: clearly a shade apart from the panel, no outline.
    public var bubble: Color { self.ink.opacity(0.09) }
    /// The fill of the message box: a shade apart from the panel, like the box in chat apps. A see-through tint, so
    /// it stays a shade apart on a selected card too (made solid, it all but vanished there: T-45 verifier 2); grey
    /// text inside it uses `subHover`, which reads on that stacked ground.
    public var composer: Color { self.ink.opacity(0.07) }

    // The grey (`sub`) has to read as text on a selected or hovered row too, not only on the bare panel: 6E6E73
    // was 4.23:1 on a selected card in light mode and A1A1A6 measured 4.54:1 on screen in dark, against the 4.5:1
    // floor (T-45). Now 4.74:1 and 5.29:1 on the selection (5.37:1 and 6.51:1 on the panel), by WCAG's formula.
    public static let dark = Theme(
        panel: Color(hex: 0x262426), ink: Color(hex: 0xF5F5F7), sub: Color(hex: 0xA8A8AD),
        hair: Color.white.opacity(0.10), accent: Color(hex: Edition.current.accentDark ?? 0xFFA35C), field: Color(hex: 0x1C1C1E),
        hover: Color.gray.opacity(0.10), rule: Color.gray.opacity(0.55), select: Color.white.opacity(0.07))
    public static let light = Theme(
        panel: Color(hex: 0xFBF7F8), ink: Color(hex: 0x1D1D1F), sub: Color(hex: 0x66666B),
        hair: Color.black.opacity(0.08), accent: Color(hex: Edition.current.accentLight ?? 0xA8480A), field: Color.white,
        hover: Color.gray.opacity(0.10), rule: Color.gray.opacity(0.55), select: Color.black.opacity(0.055))

    public static func of(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .dark : .light }

    /// Red for words ("out of limit", "100%"): a shade per panel that reads as text. The shine's own red
    /// (`limitCore`) measured 3.7:1 on the light panel and 3.9:1 on the dark one, under the 4.5:1 floor for text of
    /// this size; these measure 5.4:1 and 5.5:1.
    public var limitText: Color { ink == Theme.dark.ink ? Color(hex: 0xFF6B61) : Color(hex: 0xC4281C) }

    /// The quiet text colour under the pointer: a shade up, still clearly below the ink of a title, so a hover never
    /// flattens the order of importance.
    public var subHover: Color {
        Color(nsColor: NSColor(sub).usingColorSpace(.sRGB)?.blended(withFraction: 0.28, of: NSColor(ink).usingColorSpace(.sRGB) ?? .labelColor) ?? NSColor(sub))
    }

    /// The two text sizes of the whole app (13 is the floor), set in the system font.
    public static let body = Font.system(size: 15)
    public static let small = Font.system(size: 13)
    /// Halo pinks, shared by every surface.
    public static let haloCore = Color(red: 244 / 255, green: 140 / 255, blue: 184 / 255)
    public static let haloEdge = Color(red: 248 / 255, green: 176 / 255, blue: 200 / 255)
    /// Red, for one thing only: the plan's limit is used up.
    public static let limitCore = Color(red: 235 / 255, green: 64 / 255, blue: 58 / 255)
    public static let limitEdge = Color(red: 244 / 255, green: 120 / 255, blue: 110 / 255)
}

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.light }
public extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Reads the system appearance once and hands the matching palette to everything inside.
public struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    public var body: some View { content.environment(\.theme, Theme.of(scheme)) }
}
