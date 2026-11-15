import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor final class CompanionProjectPageVisualTests: XCTestCase {
    func testProjectPageVisualMatrix() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let solarized = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#002b36", "mantle": "#00212b", "crust": "#001b24", "text": "#839496",
            "subtext0": "#657b83", "surface0": "#073642", "surface1": "#0a4050", "accent": "#268bd2",
            "accent2": "#2aa198", "warning": "#b58900", "error": "#ec6b63", "success": "#859900", "info": "#4ea0db"
        ]))
        let mocha = try XCTUnwrap(CompanionDesktopTheme.transported([
            "base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4",
            "subtext0": "#a6adc8", "surface0": "#313244", "surface1": "#45475a", "accent": "#89b4fa",
            "accent2": "#74c7ec", "warning": "#f9e2af", "error": "#f38ba8", "success": "#a6e3a1", "info": "#89b4fa"
        ]))
        let variants: [(String, CompanionDesktopTheme, ColorScheme, DynamicTypeSize)] = [
            ("Default light", .clubhouse, .light, .large), ("Default dark", .clubhouse, .dark, .large),
            ("Solarized Dark", solarized, .dark, .large), ("Mocha on light", mocha, .light, .large),
            ("Accessibility AX3", .clubhouse, .light, .accessibility3)
        ]
        for (name, theme, scheme, type) in variants {
            let store = CompanionStore(service: CompanionPreviewService())
            var hosts = CompanionPreviewService.hosts(now: Date())
            let links = CompanionPreviewService.previewProjectLinks
            for index in hosts.indices { hosts[index].projectLinks = links; hosts[index].canLinkProjects = true }
            hosts[1].connection = .connected
            store.apply(.hosts(hosts))
            let suite = "project-page-visual-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let preferences = CompanionPreferences(defaults: defaults, systemDeviceName: "Tests")
            preferences.toggleFold("quiet:preview-studio-clubhouse")
            let project = CompanionProjectTarget(hostID: hosts[0].id, projectID: "clubhouse")
            let content = NavigationStack {
                CompanionProjectPage(store: store, preferences: preferences, project: project, onNewAgent: { _ in })
            }
            .environment(\.companionTerminal, CompanionTerminalAction(availability: { _ in .available }, open: { _ in }))
            .dynamicTypeSize(type).companionBackground().companionTheme(theme).environment(\.colorScheme, scheme)
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            await Task.yield()
            await Task.yield()
            window.layoutIfNeeded()
            hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "442 Project page - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(store.projectEntry(containing: project)?.members.count, 2)
            store.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testMachineActionAvailabilityNeverTreatsASelectedOfflineDesktopAsOperable() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        var hosts = CompanionPreviewService.hosts(now: Date())
        store.apply(.hosts(hosts))
        let project = CompanionProjectTarget(hostID: hosts[0].id, projectID: "clubhouse")
        let member = try XCTUnwrap(store.projectEntry(containing: project)?.members.first)
        let terminal = CompanionTerminalAction(availability: { _ in .available }, open: { _ in XCTFail("Availability never opens a terminal") })
        XCTAssertTrue(CompanionProjectMachineAction.wake.isAvailable(member, store: store, terminal: terminal))
        XCTAssertTrue(CompanionProjectMachineAction.terminal.isAvailable(member, store: store, terminal: terminal))
        hosts[0].connection = .offline
        store.apply(.hosts(hosts))
        let offline = try XCTUnwrap(store.projectEntry(containing: project)?.members.first)
        XCTAssertFalse(CompanionProjectMachineAction.wake.isAvailable(offline, store: store, terminal: terminal))
        XCTAssertFalse(CompanionProjectMachineAction.terminal.isAvailable(offline, store: store, terminal: terminal))
        store.shutdown()
    }
}
