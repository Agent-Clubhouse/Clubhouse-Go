import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor final class CompanionLargeCatalogTests: XCTestCase {
    func testMountedHomeMenusUseFreshCatalogIdentityAndAuthorityAtScale() async throws {
        let service = LargeCatalogService()
        let store = CompanionStore(service: service)
        var hosts = CompanionLargeCatalogFixture.hosts()
        store.apply(.hosts(hosts))
        let suite = "large-catalog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = CompanionPreferences(defaults: defaults, systemDeviceName: "Synthetic test")
        preferences.projectSort = .alphabetical
        var captured: CompanionLinkedProjectStateMenuItems?
        var home = CompanionHomeView(store: store, preferences: preferences, onPair: {}, onSettings: {}, onNewAgent: { _, _ in })
        home.hostedProjectMenu = { menu in
            if menu.entry.linkID == "synthetic-link-0", captured == nil { captured = menu }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: NavigationStack { home }.companionTheme(.clubhouse))
        window.makeKeyAndVisible()
        defer {
            captured = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
        for _ in 0..<20 where captured == nil {
            await Task.yield(); window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let menu = try XCTUnwrap(captured, "The real Home context-menu builder must mount at scale")
        XCTAssertEqual(store.projectEntries.count, 376)
        let revision = store.projectCatalogRevision
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Generated large catalog Home — 8 desktops, 384 projects, 7680 agents"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(store.projectCatalogRevision, revision, "Rendering and eager menus only read the cache")

        hosts[0].connection = .offline
        hosts[1].projects[0].agents[0].name = "Updated synthetic agent"
        store.apply(.hosts(hosts))
        XCTAssertGreaterThan(store.projectCatalogRevision, revision)
        XCTAssertEqual(store.projectEntries.first?.members.last?.project.agents.first?.name, "Updated synthetic agent")
        await menu.setPinned(true)
        XCTAssertEqual(service.targets, [.init(hostID: "synthetic-host-1", projectID: "project-0")], "The captured menu resolves the current connected receiver")

        hosts[1].canSyncLinkedProjectState = false
        store.apply(.hosts(hosts))
        await menu.setInactive(true)
        XCTAssertEqual(service.targets.count, 1, "A captured enabled menu cannot bypass revoked capability")
        hosts[1].canSyncLinkedProjectState = true
        hosts[1].projectState?["project-0"]?.linked = false
        store.apply(.hosts(hosts))
        await menu.setPinned(false)
        XCTAssertEqual(service.targets.count, 1, "A current host without linked-state authority cannot receive the command")
        for i in hosts.indices { hosts[i].projectLinks = .init(projectLinks: []) }
        let beforeUnlink = store.projectCatalogRevision
        store.apply(.hosts(hosts))
        XCTAssertGreaterThan(store.projectCatalogRevision, beforeUnlink)
        XCTAssertEqual(store.projectEntries.count, 384)
        await menu.setPinned(false)
        XCTAssertEqual(service.targets.count, 1, "The old menu cannot act on a replacement unlinked identity")
        let beforeState = store.projectCatalogRevision
        store.hosts[1].projectState?["project-0"] = .init(pinned: true)
        XCTAssertGreaterThan(store.projectCatalogRevision, beforeState)
        XCTAssertTrue(store.projectEntry(containing: .init(hostID: "synthetic-host-1", projectID: "project-0"))?.host.projectState?["project-0"]?.pinned == true)
    }
}

@MainActor private final class LargeCatalogService: CompanionService {
    var targets: [CompanionProjectTarget] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func setProject(_ project: CompanionProjectTarget, pinned: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        targets.append(project); return .init(pinned: pinned, linked: true)
    }
    func setProject(_ project: CompanionProjectTarget, inactive: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        targets.append(project); return .init(inactive: inactive, linked: true)
    }
}
