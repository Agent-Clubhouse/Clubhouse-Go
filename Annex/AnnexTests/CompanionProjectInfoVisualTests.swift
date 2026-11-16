import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor final class CompanionProjectInfoVisualTests: XCTestCase {
    func testProjectInfoVisualMatrix() async throws {
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
        let variants: [(String, CompanionDesktopTheme, ColorScheme, DynamicTypeSize)] = [
            ("Default light", .clubhouse, .light, .large), ("Default dark", .clubhouse, .dark, .large),
            ("Solarized Dark", solarized, .dark, .large), ("Mocha on light", mocha, .light, .large),
            ("Accessibility AX3", .clubhouse, .light, .accessibility3)
        ]
        for (name, theme, scheme, type) in variants {
            let service = ProjectInfoVisualService()
            let store = CompanionStore(service: service)
            var hosts = CompanionPreviewService.hosts(now: Date())
            hosts[0].projects = [.init(id: "clubhouse", name: "Clubhouse", agents: [], path: "/Users/preview/Projects/Clubhouse/linked-project-with-a-long-name")]
            hosts[0].canLinkProjects = true
            hosts[0].projectLinks = .init(projectLinks: [.init(id: "linked", projects: [.init(machine: hosts[0].id, projectId: "clubhouse"), .init(machine: hosts[1].id, projectId: "copy")])])
            hosts[1].projects = [.init(id: "copy", name: "Clubhouse", agents: [], path: "/Users/preview/Work/clubhouse")]
            hosts[1].connection = .offline
            store.apply(.hosts(hosts))
            let content = CompanionProjectInfoSheet(store: store, project: .init(hostID: hosts[0].id, projectID: "clubhouse"))
                .dynamicTypeSize(type)
                .companionBackground()
                .companionTheme(theme)
                .environment(\.colorScheme, scheme)
            let hosting = UIHostingController(rootView: content)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            await fulfillment(of: [service.requested], timeout: 10)
            await Task.yield()
            await Task.yield()
            window.layoutIfNeeded()
            hosting.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "443 Project info - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(service.readCount, 1, "The visible connected member uses one existing read; offline members do not read")
            store.shutdown()
        }
    }
}

@MainActor private final class ProjectInfoVisualService: CompanionService {
    let preview = CompanionPreviewService()
    let requested = XCTestExpectation(description: "Project defaults read")
    var readCount = 0
    func events() -> AsyncStream<CompanionEvent> { preview.events() }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { try await preview.history(for: target) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        let result = try await preview.createOptions(for: project)
        readCount += 1
        requested.fulfill()
        return result
    }
}
