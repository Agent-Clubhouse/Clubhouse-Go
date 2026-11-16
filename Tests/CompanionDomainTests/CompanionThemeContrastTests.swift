import Foundation
import Testing
@testable import CompanionDomain

struct CompanionThemeContrastTests {
    private struct Fixture: Decodable {
        struct Theme: Decodable {
            var id: String
            var colors: [String: String]
            var gradient: [String]
        }
        var themes: [Theme]
    }

    private func builtins() throws -> [Fixture.Theme] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/DesktopThemes/builtin-palettes.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path)).themes
    }

    @Test func everyBuiltinThemeMeetsContrastAndStatusHueFloorsInBothAppearances() throws {
        let records = try builtins()
        let ids = Set(records.map(\.id))
        #expect(records.count == 48)
        #expect(Set(["catppuccin-latte", "catppuccin-mocha", "dracula", "nord", "cyberpunk", "solarized-dark",
                     "tokyo-night", "gruvbox-dark", "terminal", "aurora", "canyon", "daybreak", "mist"]).isSubset(of: ids))
        for record in records {
            let theme = try #require(CompanionDesktopTheme.transported(record.colors, gradient: record.gradient))
            check(theme, name: record.id)
        }
        check(.clubhouse, name: "Clubhouse Go default")
    }

    private func check(_ theme: CompanionDesktopTheme, name: String) {
        for dark in [false, true] {
            let palette = CompanionPalette(theme: theme, dark: dark)
            #expect(palette.label.contrast(with: palette.card) >= 7, "\(name), dark: \(dark), label")
            #expect(palette.secondaryLabel.contrast(with: palette.card) >= 4.5, "\(name), dark: \(dark), secondary")
            #expect(palette.tint.contrast(with: palette.card) >= 4.5, "\(name), dark: \(dark), tint")
            for (role, color) in [("warning", palette.warning), ("error", palette.error), ("success", palette.success), ("info", palette.info)] {
                #expect(color.contrast(with: palette.card) >= 3, "\(name), dark: \(dark), \(role)")
                #expect(color.saturation >= CompanionPalette.minimumStatusSaturation, "\(name), dark: \(dark), \(role)")
            }
        }
    }

    @Test func customLowContrastTextAndMutedStatusesAreFittedWithoutThemeRecognition() throws {
        let theme = CompanionDesktopTheme(id: UUID().uuidString, name: "Custom", source: "Plugin", mode: .light,
            colors: ["base": "#ffffff", "text": "#999999", "subtext0": "#aaaaaa", "accent": "#b0b0c0",
                     "warning": "#b8b6b0", "error": "#b8b0b0", "success": "#b0b8b0", "info": "#b0b0b8"], gradient: [])
        check(theme, name: "Unknown plugin")
        let light = CompanionPalette(theme: theme, dark: false)
        #expect(light.warning.red > light.warning.green && light.warning.green > light.warning.blue)
        #expect(light.error.red > light.error.green && light.error.red > light.error.blue)
        #expect(light.success.green > light.success.red && light.success.green > light.success.blue)
        #expect(light.info.blue > light.info.red && light.info.blue > light.info.green)
    }

    @Test func readableSaturatedDesktopStatusesKeepTheirOwnHues() {
        let theme = CompanionDesktopTheme(id: "custom-hues", name: "Custom", source: "Plugin", mode: .dark,
            colors: ["base": "#000000", "accent": "#ff00ff", "warning": "#ffee00", "error": "#ff3366",
                     "success": "#39ff14", "info": "#00e5ff"], gradient: [])
        let palette = CompanionPalette(theme: theme, dark: true)
        #expect(palette.warning == theme.warning)
        #expect(palette.error == theme.error)
        #expect(palette.success == theme.success)
        #expect(palette.info == theme.info)
    }

    @Test func readablePastelsKeepTheirHueOnDarkGrounds() throws {
        let records = try builtins()
        let record = try #require(records.first { $0.id == "catppuccin-mocha" })
        let theme = try #require(CompanionDesktopTheme.transported(record.colors))
        let palette = CompanionPalette(theme: theme, dark: true)
        #expect(palette.warning == theme.warning)
        #expect(palette.error == theme.error)
        #expect(palette.success == theme.success)
        #expect(palette.info == theme.info)
    }

    @Test func defaultLightTokensPassWithoutColorFitting() throws {
        let palette = CompanionPalette(theme: .clubhouse, dark: false)
        #expect(palette.usesThemeGrounds)
        #expect(!palette.accentWasAdjusted)
        for (actual, hex) in [(palette.label, "#17171b"), (palette.secondaryLabel, "#63636d"), (palette.tint, "#6654cc"),
                              (palette.warning, "#ad6500"), (palette.error, "#c42b25"), (palette.success, "#287d42"), (palette.info, "#176ac6")] {
            #expect(actual == (try #require(CompanionRGB(hex: hex))))
        }
    }

    @Test func appearanceOverridesAreColorDataAndNotThemeNames() {
        let theme = CompanionDesktopTheme(id: UUID().uuidString, name: "Custom", source: "Plugin", mode: .dark,
            colors: ["base": "#000000", "accent": "#ff00ff"], gradient: [],
            appearanceColors: [.light: ["base": "#fffef0", "accent": "#664400", "text": "#111111"]])
        #expect(CompanionPalette(theme: theme, dark: false).card == CompanionRGB(hex: "#fffef0"))
        #expect(CompanionPalette(theme: theme, dark: true).card == .black)
    }

    @Test func fitterUsesTheBetterEndpointAndReachesFeasibleRatiosNearItsLimit() throws {
        let midtone = try #require(CompanionRGB(hex: "#888888"))
        #expect(CompanionRGB.white.adjusted(toContrast: 4.5, against: midtone).contrast(with: midtone) >= 4.5)
        let nearLimit = try #require(CompanionRGB(hex: "#585858"))
        #expect(CompanionRGB.black.adjusted(toContrast: 7, against: nearLimit).contrast(with: nearLimit) >= 7)
        let impossible = try #require(CompanionRGB(hex: "#777777"))
        #expect(CompanionRGB.white.adjusted(toContrast: 7, against: impossible) == .black)
        #expect(CompanionRGB.black.adjusted(toContrast: 7, against: .white) == .black)
    }
}
