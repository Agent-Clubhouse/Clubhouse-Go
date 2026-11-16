import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionMachineStateVisualTests: XCTestCase {
    func testMachineStateVisualMatrix() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let mocha = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4",
            "subtext0": "#a6adc8", "surface0": "#313244", "accent": "#cba6f7"
        ]))
        let daybreak = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#fffaf3", "mantle": "#f8f0e3", "crust": "#eee4d2", "text": "#3e342e",
            "subtext0": "#77685e", "surface0": "#ede3d5", "accent": "#9a5c35"
        ]))
        let variants: [(String, CompanionDesktopTheme, ColorScheme, DynamicTypeSize)] = [
            ("Light", .clubhouse, .light, .large), ("Dark", .clubhouse, .dark, .large),
            ("Mocha desktop theme", mocha, .dark, .large), ("Daybreak desktop theme", daybreak, .light, .large),
            ("Accessibility AX3", .clubhouse, .light, .accessibility3)
        ]
        for (name, theme, scheme, type) in variants {
            let content = MachineStateScene(accessible: type.isAccessibilitySize)
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
            attachment.name = "441 Machine states - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private struct MachineStateScene: View {
    var accessible: Bool
    @Environment(\.companionPalette) private var palette
    private var states: [CompanionMachineState] {
        accessible ? [.connecting, .offline] : [.connected, .working, .asleep, .offline, .turnedOff, .connecting, .reconnecting]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Desktops").font(.title.bold())
                ForEach(states.indices, id: \.self) { index in
                    let state = states[index]
                    let now = Date(timeIntervalSince1970: 1_800_000_000)
                    let presentation = state.presentation(lastSeen: now.addingTimeInterval(-300),
                                                          linkBlocked: state == .offline, now: now)
                    HStack(alignment: .top, spacing: 10) {
                        if let symbol = presentation.symbol {
                            Image(systemName: symbol).foregroundStyle(Color(palette.tint))
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.detail).font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(20)
        }
    }
}
