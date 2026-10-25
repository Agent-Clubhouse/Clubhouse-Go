import Foundation

/// An sRGB color with 0...1 components. Theme mapping stays free of UI frameworks so it can be unit tested.
struct CompanionRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = CompanionRGB(red: 0, green: 0, blue: 0)
    static let white = CompanionRGB(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1); self.green = min(max(green, 0), 1); self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Linear interpolation toward `other`; `amount` 0 keeps self, 1 returns other.
    func mixed(with other: CompanionRGB, amount: Double) -> CompanionRGB {
        CompanionRGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: CompanionRGB) -> Double {
        let lighter = max(luminance, other.luminance), darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Nudges the color toward black or white until it reaches `ratio` against `background`.
    func adjusted(toContrast ratio: Double, against background: CompanionRGB) -> CompanionRGB {
        let target: CompanionRGB = background.luminance > 0.4 ? .black : .white
        var color = self
        for _ in 0..<24 where color.contrast(with: background) < ratio { color = color.mixed(with: target, amount: 0.08) }
        return color
    }
}

/// A desktop theme as Clubhouse defines it. Only the colors the phone uses are kept.
struct CompanionDesktopTheme: Identifiable, Sendable, Equatable {
    enum Mode: String, Sendable { case light, dark }
    var id: String
    var name: String
    var source: String
    var mode: Mode
    var base: CompanionRGB
    var mantle: CompanionRGB
    var crust: CompanionRGB
    var text: CompanionRGB
    var subtext: CompanionRGB
    var surface0: CompanionRGB
    var surface1: CompanionRGB
    var accent: CompanionRGB
    var accent2: CompanionRGB?
    var warning: CompanionRGB
    var error: CompanionRGB
    var success: CompanionRGB
    /// Stops of the theme's accent gradient, when it has one.
    var gradient: [CompanionRGB]

    init(id: String, name: String, source: String, mode: Mode, colors: [String: String], gradient: [String]) {
        func color(_ key: String, _ fallback: CompanionRGB) -> CompanionRGB { colors[key].flatMap(CompanionRGB.init(hex:)) ?? fallback }
        let dark = mode == .dark
        self.id = id; self.name = name; self.source = source; self.mode = mode
        base = color("base", dark ? CompanionRGB(red: 0.11, green: 0.11, blue: 0.12) : .white)
        mantle = color("mantle", base); crust = color("crust", mantle)
        text = color("text", dark ? .white : .black)
        subtext = color("subtext0", text.mixed(with: base, amount: 0.4))
        surface0 = color("surface0", base.mixed(with: text, amount: 0.1))
        surface1 = color("surface1", base.mixed(with: text, amount: 0.18))
        accent = color("accent", CompanionRGB(red: 0.55, green: 0.5, blue: 1))
        accent2 = colors["accent2"].flatMap(CompanionRGB.init(hex:))
        warning = color("warning", CompanionRGB(red: 1, green: 0.62, blue: 0.04))
        self.error = color("error", CompanionRGB(red: 1, green: 0.27, blue: 0.23))
        success = color("success", CompanionRGB(red: 0.19, green: 0.82, blue: 0.35))
        self.gradient = gradient.compactMap(CompanionRGB.init(hex:))
    }
}

/// Phone colors derived from a desktop theme for one appearance.
struct CompanionPalette: Sendable, Equatable {
    var isDark: Bool
    /// True when the theme's mode matches the iPhone appearance, so its own backgrounds and text are used.
    var usesThemeGrounds: Bool
    var background: CompanionRGB
    var card: CompanionRGB
    var raisedCard: CompanionRGB
    var label: CompanionRGB
    var secondaryLabel: CompanionRGB
    var separator: CompanionRGB
    var fill: CompanionRGB
    var tint: CompanionRGB
    var tintSoft: CompanionRGB
    var onTint: CompanionRGB
    var warning: CompanionRGB
    var error: CompanionRGB
    var success: CompanionRGB
    var washStart: CompanionRGB
    var washEnd: CompanionRGB
    /// True when the theme's accent was darkened or lightened to stay readable.
    var accentWasAdjusted: Bool

    /// The app follows the iPhone's appearance. A theme whose mode matches supplies its grounds and text;
    /// otherwise system grounds take a hint of the accent. Accent and status colors are fitted for contrast.
    init(theme: CompanionDesktopTheme, dark: Bool) {
        isDark = dark
        usesThemeGrounds = (theme.mode == .dark) == dark
        let secondary: CompanionRGB
        if usesThemeGrounds {
            background = dark ? theme.crust : theme.mantle
            card = theme.base
            raisedCard = dark ? theme.surface0 : theme.crust
            label = theme.text
            secondary = theme.subtext
            separator = theme.surface1.mixed(with: theme.base, amount: 0.3)
            fill = theme.surface0.mixed(with: theme.base, amount: 0.15)
        } else {
            let hint = theme.accent
            background = (dark ? CompanionRGB.black : CompanionRGB(red: 0.949, green: 0.949, blue: 0.969)).mixed(with: hint, amount: dark ? 0.07 : 0.06)
            card = dark ? CompanionRGB(red: 0.11, green: 0.11, blue: 0.118).mixed(with: hint, amount: 0.07) : .white
            raisedCard = (dark ? CompanionRGB(red: 0.173, green: 0.173, blue: 0.18) : CompanionRGB(red: 0.949, green: 0.949, blue: 0.969)).mixed(with: hint, amount: 0.06)
            label = dark ? .white : .black
            secondary = dark ? CompanionRGB(red: 0.62, green: 0.62, blue: 0.65) : CompanionRGB(red: 0.42, green: 0.42, blue: 0.45)
            separator = dark ? CompanionRGB(red: 0.23, green: 0.23, blue: 0.25) : CompanionRGB(red: 0.855, green: 0.855, blue: 0.875)
            fill = dark ? CompanionRGB(red: 0.19, green: 0.19, blue: 0.21) : CompanionRGB(red: 0.914, green: 0.914, blue: 0.933)
        }
        secondaryLabel = secondary.adjusted(toContrast: 4.5, against: card)
        tint = theme.accent.adjusted(toContrast: 4.5, against: card)
        accentWasAdjusted = tint != theme.accent
        tintSoft = tint.mixed(with: card, amount: 0.84)
        onTint = CompanionRGB.white.contrast(with: tint) >= CompanionRGB(red: 0.067, green: 0.067, blue: 0.067).contrast(with: tint)
            ? .white : CompanionRGB(red: 0.067, green: 0.067, blue: 0.067)
        warning = theme.warning.adjusted(toContrast: 3, against: card)
        error = theme.error.adjusted(toContrast: 3, against: card)
        success = theme.success.adjusted(toContrast: 3, against: card)
        washStart = theme.gradient.first ?? theme.accent
        washEnd = theme.gradient.dropFirst().first ?? theme.accent2 ?? theme.accent.mixed(with: dark ? .white : .black, amount: 0.35)
    }
}

enum CompanionThemeCatalog {
    /// Used when a desktop reports no theme, or one the phone doesn't know.
    static let clubhouse = CompanionDesktopTheme(
        id: "clubhouse", name: "Clubhouse", source: "Clubhouse Go", mode: .dark,
        colors: ["base": "#1c1c1e", "mantle": "#111113", "crust": "#000000", "text": "#ffffff", "subtext0": "#9d9da6",
                 "surface0": "#2c2c2e", "surface1": "#3a3a3c", "accent": "#8b7fff", "warning": "#ff9f0a", "error": "#ff453a", "success": "#30d158"],
        gradient: ["#7a6cff", "#00a3c4"])

    static var all: [CompanionDesktopTheme] { desktopThemes }

    static func theme(id: String?) -> CompanionDesktopTheme {
        guard let id else { return clubhouse }
        return desktopThemes.first { $0.id == id } ?? clubhouse
    }

    /// The theme for a desktop: a choice made on the phone wins, then what the desktop reports.
    static func theme(forHost hostID: String?, hosts: [CompanionHost], overrides: [String: String]) -> CompanionDesktopTheme {
        guard let hostID else { return clubhouse }
        return theme(id: overrides[hostID] ?? hosts.first { $0.id == hostID }?.themeID)
    }
}
