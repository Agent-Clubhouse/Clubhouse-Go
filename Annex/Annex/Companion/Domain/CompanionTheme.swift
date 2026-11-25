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

    /// Distance between the strongest and weakest channel: how far the color is from grey.
    var chroma: Double { max(red, max(green, blue)) - min(red, min(green, blue)) }

    /// HSL saturation distinguishes a colored pastel from a fitted grey or olive tone.
    var saturation: Double {
        let maximum = max(red, max(green, blue)), minimum = min(red, min(green, blue))
        guard maximum != minimum else { return 0 }
        return (maximum - minimum) / (1 - abs(maximum + minimum - 1))
    }

    /// Fits toward the better-contrast endpoint, using the smallest mix in that direction.
    /// Midtone backgrounds cannot support every ratio; in that case return the best attainable color.
    func adjusted(toContrast ratio: Double, against background: CompanionRGB) -> CompanionRGB {
        guard contrast(with: background) < ratio else { return self }
        let target: CompanionRGB = Self.white.contrast(with: background) >= Self.black.contrast(with: background) ? .white : .black
        guard target.contrast(with: background) >= ratio else { return target }
        var lower = 0.0, upper = 1.0
        for _ in 0..<24 {
            let amount = (lower + upper) / 2
            if mixed(with: target, amount: amount).contrast(with: background) >= ratio { upper = amount }
            else { lower = amount }
        }
        return mixed(with: target, amount: upper)
    }
}

/// A desktop theme as Clubhouse defines it. Only the colors the phone uses are kept.
struct CompanionDesktopTheme: Identifiable, Sendable, Equatable {
    enum Mode: String, Sendable, Hashable { case light, dark }
    var id: String
    var name: String
    var source: String
    var mode: Mode
    /// Optional token palettes for another appearance. Transported themes need no overrides or theme IDs.
    var appearanceColors: [Mode: [String: String]]
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
    /// The desktop's `info` color, which it uses for Done and Starting.
    var info: CompanionRGB
    /// Stops of the theme's accent gradient, when it has one.
    var gradient: [CompanionRGB]
    /// The desktop's `terminalColors`, sent beside the theme. Nil on older desktops.
    var terminalSource: [String: String]?
    /// Terminal colors: the desktop's, completed from this theme.
    var terminal: CompanionTerminalColors { CompanionTerminalColors(colors: terminalSource ?? [:], theme: self) }

    init(id: String, name: String, source: String, mode: Mode, colors: [String: String], gradient: [String], appearanceColors: [Mode: [String: String]] = [:]) {
        func color(_ key: String, _ fallback: CompanionRGB) -> CompanionRGB { colors[key].flatMap { CompanionRGB(hex: $0) } ?? fallback }
        let dark = mode == .dark
        self.id = id; self.name = name; self.source = source; self.mode = mode
        self.appearanceColors = appearanceColors
        base = color("base", dark ? CompanionRGB(red: 0.11, green: 0.11, blue: 0.12) : .white)
        mantle = color("mantle", base); crust = color("crust", mantle)
        text = color("text", dark ? .white : .black)
        subtext = color("subtext0", text.mixed(with: base, amount: 0.4))
        surface0 = color("surface0", base.mixed(with: text, amount: 0.1))
        surface1 = color("surface1", base.mixed(with: text, amount: 0.18))
        accent = color("accent", CompanionRGB(red: 0.55, green: 0.5, blue: 1))
        accent2 = colors["accent2"].flatMap { CompanionRGB(hex: $0) }
        warning = color("warning", CompanionRGB(red: 1, green: 0.62, blue: 0.04))
        self.error = color("error", CompanionRGB(red: 1, green: 0.27, blue: 0.23))
        success = color("success", CompanionRGB(red: 0.19, green: 0.82, blue: 0.35))
        // Older desktops don't send `info`; a system blue stands in, fitted for contrast like the others.
        info = color("info", CompanionRGB(red: 0.04, green: 0.52, blue: 1))
        self.gradient = gradient.compactMap { CompanionRGB(hex: $0) }
    }

    fileprivate func paletteTheme(for mode: Mode) -> Self {
        guard let colors = appearanceColors[mode] else { return self }
        var result = Self(id: id, name: name, source: source, mode: mode,
                          colors: colors, gradient: gradient.map(\.hex))
        result.terminalSource = terminalSource
        return result
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
    var info: CompanionRGB
    var washStart: CompanionRGB
    var washEnd: CompanionRGB
    /// Opacity of the radial wash behind transparent bars.
    var washOpacity: Double
    /// True when the theme's accent was darkened or lightened to stay readable.
    var accentWasAdjusted: Bool

    /// The app follows the iPhone's appearance. A theme whose mode matches supplies its grounds and text;
    /// otherwise system grounds take a hint of the accent. Accent and status colors are fitted for contrast.
    init(theme sourceTheme: CompanionDesktopTheme, dark: Bool) {
        let theme = sourceTheme.paletteTheme(for: dark ? .dark : .light)
        isDark = dark
        usesThemeGrounds = (theme.mode == .dark) == dark
        let primary: CompanionRGB, secondary: CompanionRGB
        let roleCollision: Bool
        if usesThemeGrounds {
            background = dark ? theme.crust : theme.mantle
            card = theme.base
            raisedCard = dark ? theme.surface0 : theme.crust
            // A theme whose text is its accent (Terminal's #00ff00) would make body text, controls and the
            // wash one color. Reading text becomes a soft tint of it; the accent stays on controls.
            roleCollision = theme.text == theme.accent
            primary = roleCollision ? theme.text.mixed(with: dark ? .white : .black, amount: Self.collidingTextNeutralMix) : theme.text
            secondary = theme.subtext
            separator = theme.surface1.mixed(with: theme.base, amount: 0.3)
            fill = theme.surface0.mixed(with: theme.base, amount: 0.15)
        } else {
            roleCollision = false
            let hint = theme.accent
            background = (dark ? CompanionRGB.black : CompanionRGB(red: 0.949, green: 0.949, blue: 0.969)).mixed(with: hint, amount: dark ? 0.07 : 0.06)
            card = dark ? CompanionRGB(red: 0.11, green: 0.11, blue: 0.118).mixed(with: hint, amount: 0.07) : .white
            raisedCard = (dark ? CompanionRGB(red: 0.173, green: 0.173, blue: 0.18) : CompanionRGB(red: 0.949, green: 0.949, blue: 0.969)).mixed(with: hint, amount: 0.06)
            primary = dark ? .white : .black
            secondary = dark ? CompanionRGB(red: 0.62, green: 0.62, blue: 0.65) : CompanionRGB(red: 0.42, green: 0.42, blue: 0.45)
            separator = dark ? CompanionRGB(red: 0.23, green: 0.23, blue: 0.25) : CompanionRGB(red: 0.855, green: 0.855, blue: 0.875)
            fill = dark ? CompanionRGB(red: 0.19, green: 0.19, blue: 0.21) : CompanionRGB(red: 0.914, green: 0.914, blue: 0.933)
        }
        label = primary.adjusted(toContrast: 7, against: card)
        secondaryLabel = secondary.adjusted(toContrast: 4.5, against: card)
        tint = theme.accent.adjusted(toContrast: 4.5, against: card)
        accentWasAdjusted = tint != theme.accent
        tintSoft = tint.mixed(with: card, amount: 0.84)
        onTint = CompanionPalette.glyph(on: tint)
        // Semantic system hues are the fallback when a fitted desktop color becomes too muted.
        warning = Self.status(theme.warning, against: card,
                              fallback: CompanionRGB(red: 1, green: dark ? 0.624 : 0.584, blue: dark ? 0.039 : 0))
        error = Self.status(theme.error, against: card,
                            fallback: CompanionRGB(red: 1, green: dark ? 0.271 : 0.231, blue: dark ? 0.227 : 0.188))
        success = Self.status(theme.success, against: card,
                              fallback: CompanionRGB(red: dark ? 0.188 : 0.204, green: dark ? 0.820 : 0.780, blue: dark ? 0.345 : 0.349))
        info = Self.status(theme.info, against: card,
                           fallback: CompanionRGB(red: dark ? 0.039 : 0, green: dark ? 0.518 : 0.478, blue: 1))
        washStart = theme.gradient.first ?? theme.accent
        washEnd = theme.gradient.dropFirst().first ?? theme.accent2 ?? theme.accent.mixed(with: dark ? .white : .black, amount: 0.35)
        let washCeiling = dark ? 0.42 : 0.3
        washOpacity = roleCollision
            ? Self.calmWashOpacity(ceiling: min(washCeiling, Self.collidingWashOpacity), label: label, background: background,
                                   colors: [washStart, washEnd])
            : washCeiling
    }
}

extension CompanionPalette {
    /// How far theme text that equals its accent moves toward white (dark) or black (light) for reading.
    static let collidingTextNeutralMix = 0.7
    /// The wash's strongest opacity when it shares its hue with text and controls.
    static let collidingWashOpacity = 0.22

    /// The strongest wash, up to `ceiling`, that leaves `label` at 7:1 over each wash color at its peak,
    /// blended in sRGB like the gradient is drawn.
    static func calmWashOpacity(ceiling: Double, label: CompanionRGB, background: CompanionRGB, colors: [CompanionRGB]) -> Double {
        func readable(_ opacity: Double) -> Bool {
            colors.allSatisfy { label.contrast(with: background.mixed(with: $0, amount: opacity)) >= 7 }
        }
        if readable(ceiling) { return ceiling }
        var lower = 0.0, upper = ceiling
        for _ in 0..<24 {
            let amount = (lower + upper) / 2
            if readable(amount) { lower = amount } else { upper = amount }
        }
        return lower
    }

    /// Below 35% HSL saturation, fitted status colors can read as grey or olive on the opposite appearance.
    static let minimumStatusSaturation = 0.35

    private static func status(_ color: CompanionRGB, against background: CompanionRGB, fallback: CompanionRGB) -> CompanionRGB {
        let fitted = color.adjusted(toContrast: 3, against: background)
        return fitted.saturation < minimumStatusSaturation
            ? fallback.adjusted(toContrast: 3, against: background) : fitted
    }

    /// White or near-black, whichever reads better on `fill`. The better of white and black always reaches 4.58:1,
    /// but near-black can fall short on mid-luminance fills, so pure black is used there.
    static func glyph(on fill: CompanionRGB) -> CompanionRGB {
        if CompanionRGB.white.contrast(with: fill) >= CompanionRGB.black.contrast(with: fill) { return .white }
        let nearBlack = CompanionRGB(red: 0.067, green: 0.067, blue: 0.067)
        return nearBlack.contrast(with: fill) >= 4.5 ? nearBlack : .black
    }
}

extension CompanionDesktopTheme {
    /// The colors a desktop sends in its snapshot `theme` and in `theme:changed`. Custom and plugin
    /// themes arrive the same way, so the phone never needs to know a theme by name.
    /// The payload has no light/dark flag; the mode follows the base color, as the desktop's own UI does.
    static func transported(_ colors: [String: String], gradient: [String] = [], terminal: [String: String]? = nil) -> CompanionDesktopTheme? {
        guard let base = colors["base"].flatMap({ CompanionRGB(hex: $0) }), colors["accent"].flatMap({ CompanionRGB(hex: $0) }) != nil else { return nil }
        var theme = CompanionDesktopTheme(id: "desktop", name: "Desktop theme", source: "Desktop", mode: base.luminance < 0.5 ? .dark : .light,
                                          colors: colors, gradient: gradient)
        theme.terminalSource = terminal
        return theme
    }

    /// Used until a desktop has sent its colors.
    static let clubhouse = CompanionDesktopTheme(
        id: "clubhouse", name: "Clubhouse", source: "Clubhouse Go", mode: .dark,
        colors: ["base": "#1c1c1e", "mantle": "#111113", "crust": "#000000", "text": "#ffffff", "subtext0": "#9d9da6",
                 "surface0": "#2c2c2e", "surface1": "#3a3a3c", "accent": "#8b7fff", "warning": "#ff9f0a", "error": "#ff453a", "success": "#30d158", "info": "#0a84ff"],
        gradient: ["#7a6cff", "#00a3c4"],
        appearanceColors: [.light: [
            "base": "#ffffff", "mantle": "#f1eff9", "crust": "#e4e1ee", "text": "#17171b", "subtext0": "#63636d",
            "surface0": "#eceaf4", "surface1": "#d8d4e5", "accent": "#6654cc", "warning": "#ad6500",
            "error": "#c42b25", "success": "#287d42", "info": "#176ac6"
        ]])
}
