import XCTest
import SwiftUI
import Vision
import ClubhouseTransport
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

    func testRemovingSelectedDesktopReconcilesToAllAndKeepsRemainingAgentsVisible() async throws {
        let store = CompanionStore(service: CompanionPreviewService())
        var hosts = CompanionPreviewService.hosts(now: Date())
        let links = CompanionPreviewService.previewProjectLinks
        for index in hosts.indices {
            hosts[index].projectLinks = links
            hosts[index].canLinkProjects = true
            hosts[index].connection = .connected
        }
        hosts[0].projects[0].agents = [hosts[0].projects[0].agents[0]]
        hosts[0].projects[0].agents[0].name = "Studio agent"
        hosts[1].projects[0].agents = [hosts[1].projects[0].agents[0]]
        hosts[1].projects[0].agents[0].name = "Laptop agent"
        let remainingHost = hosts[0]
        let selectedHost = hosts[1]
        store.apply(.hosts(hosts))
        let project = CompanionProjectTarget(hostID: remainingHost.id, projectID: "clubhouse")
        XCTAssertEqual(store.projectEntry(containing: project)?.members.count, 2)
        let suite = "project-scope-removal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = CompanionPreferences(defaults: defaults, systemDeviceName: "Tests")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            CompanionProjectPage(store: store, preferences: preferences, project: project,
                                 initialDesktopSelection: .host(selectedHost.id), onNewAgent: { _ in })
        }.dynamicTypeSize(.large).companionBackground().companionTheme(.clubhouse).environment(\.colorScheme, .light))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            store.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        let before = try await renderedText(window, stage: "Selected Laptop before removal")
        XCTAssertTrue(before.contains("Laptop agent"), "The real page starts scoped to the second desktop")
        XCTAssertFalse(before.contains("Studio agent"))

        // The page remains anchored to Studio. Forgetting/unlinking Laptop shrinks the entry
        // from two hosts to one; the now-hidden chips must still reset the selected scope.
        store.apply(.hosts([remainingHost]))
        XCTAssertEqual(store.projectEntry(containing: project)?.members.map(\.host.id), [remainingHost.id])
        let after = try await renderedText(window, stage: "All scope after selected desktop removal")
        XCTAssertTrue(after.contains("Studio agent"), "Reconciliation to All must restore the remaining desktop's actual agent rows")
        XCTAssertFalse(after.contains("Laptop agent"))
        XCTAssertTrue(after.contains("New agent"), "Project actions remain on the recovered page")
    }

    private func renderedText(_ window: UIWindow, stage: String) async throws -> String {
        await Task.yield()
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "442 \(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: "\n")
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
