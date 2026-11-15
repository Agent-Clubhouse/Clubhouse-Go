import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionThemeContrastVisualTests: XCTestCase {
    func testThemeVisualMatrix() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let solarized = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#002b36", "mantle": "#00212b", "crust": "#001b24", "text": "#839496",
            "subtext0": "#657b83", "surface0": "#073642", "surface1": "#0a4050", "accent": "#268bd2",
            "accent2": "#2aa198", "warning": "#b58900", "error": "#ec6b63", "success": "#859900",
            "info": "#4ea0db"
        ]))
        let mocha = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4",
            "subtext0": "#a6adc8", "surface0": "#313244", "surface1": "#45475a", "accent": "#89b4fa",
            "accent2": "#74c7ec", "warning": "#f9e2af", "error": "#f38ba8", "success": "#a6e3a1",
            "info": "#89b4fa"
        ]))
        let cyberpunk = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#0d0221", "mantle": "#080118", "crust": "#050010", "text": "#e0f0ff",
            "subtext0": "#8a9bb5", "surface0": "#1a0a3e", "surface1": "#241452", "accent": "#ff2d95",
            "accent2": "#00ffff", "warning": "#ffe600", "error": "#ff3366", "success": "#39ff14",
            "info": "#00e5ff"
        ]))
        let variants: [(String, CompanionDesktopTheme, ColorScheme, DynamicTypeSize)] = [
            ("Default light", .clubhouse, .light, .large), ("Default dark", .clubhouse, .dark, .large),
            ("Solarized Dark", solarized, .dark, .large), ("Mocha on light", mocha, .light, .large),
            ("Cyberpunk", cyberpunk, .dark, .large), ("Accessibility AX3", .clubhouse, .light, .accessibility3)
        ]
        for (name, theme, scheme, type) in variants {
            let content = ThemeScene()
                .dynamicTypeSize(type)
                .companionBackground()
                .companionTheme(theme)
                .environment(\.colorScheme, scheme)
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "432 Theme contrast - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private struct ThemeScene: View {
    @Environment(\.companionPalette) private var palette
    private var river: CompanionAgent {
        .init(id: .init(hostID: "studio", projectID: "clubhouse", agentID: "river"),
              name: "River", subtitle: "Run xcodebuild", status: .approval)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Clubhouse").font(.largeTitle.bold())
                Text("Needs you").font(.title2.bold())
                VStack(alignment: .leading, spacing: 16) {
                    CompanionAgentListRow(agent: river)
                    Text("Review the requested action").font(.headline)
                    Text("Studio Mac · Bash").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    HStack {
                        Button("Deny") {}
                            .frame(maxWidth: .infinity).padding(12)
                            .background(Color(palette.fill), in: Capsule())
                        Button("Allow once") {}
                            .frame(maxWidth: .infinity).padding(12)
                            .foregroundStyle(Color(palette.onTint))
                            .background(Color(palette.tint), in: Capsule())
                    }
                }
                .padding(16)
                .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 16) {
                    Text("Agents").font(.headline)
                    status("Needs permission", color: palette.warning)
                    status("Working", color: palette.success)
                    status("Done", color: palette.info)
                    status("Stopped with an error", color: palette.error)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
        }
    }

    private func status(_ text: String, color: CompanionRGB) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(color)).frame(width: 8, height: 8)
            Text(text).foregroundStyle(Color(color))
        }
    }
}
