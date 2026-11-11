import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

@MainActor
private final class QA361SettingsService: CompanionService {
    let preview = CompanionPreviewService()
    var reads = 0
    var level = CompanionPermissionLevel.ask
    func events() -> AsyncStream<CompanionEvent> { preview.events() }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { try await preview.history(for: target) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        reads += 1
        var result = try await preview.settings(for: target)
        result.access?.value = level
        result.access?.startsAt = level
        return result
    }
}

@MainActor
final class QA361AccessRegressionTests: XCTestCase {
    func testEndedSessionDoesNotOverrideSavedAccessOrClaimToBeRunning() {
        var projection = CompanionChatProjector()
        projection.session.level = "full_access"
        projection.endSession(.sleeping)
        var agent = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "a"),
                                   name: "Sleeping agent", subtitle: "", status: projection.status)
        agent.access = .plan
        agent.isSleepingOnDesktop = true
        agent.session = projection.session
        XCTAssertNil(agent.liveAccess, "Historical facts are not live: badge=\(String(describing: agent.displayedChatAccess)); details=\(CompanionAgentDetails(agent: agent).access ?? "nil")")
        XCTAssertEqual(agent.displayedChatAccess, .plan, "The sleeping badge must not prefer the old Full access session")
        XCTAssertEqual(CompanionAgentDetails(agent: agent).access, "Plan", "No session is running now")
    }

    func testOpenSettingsRefreshesWhenDesktopChangesSavedAccess() async throws {
        try await assertOpenSheetRefreshes(details: false)
    }

    func testOpenDetailsRefreshesWhenDesktopChangesSavedAccess() async throws {
        try await assertOpenSheetRefreshes(details: true)
    }

    func testRaisingAccessConfirmsFromFreshLowerSnapshotWhileSettingsAreStale() async throws {
        let service = QA361SettingsService()
        service.level = .fullAccess
        let store = CompanionStore(service: service)
        defer { store.stop() }
        let target = CompanionPreviewService.sleepingTarget
        var hosts = CompanionPreviewService.hosts(now: Date())
        let project = try XCTUnwrap(hosts[0].projects.firstIndex { $0.id == target.projectID })
        let agent = try XCTUnwrap(hosts[0].projects[project].agents.firstIndex { $0.id == target })
        hosts[0].projects[project].agents[agent].access = .fullAccess
        store.apply(.hosts(hosts))
        let settings = try await service.settings(for: target)
        let stale = try XCTUnwrap(settings.access)
        let form = CompanionAgentSettingsForm(store: store, target: target)
        XCTAssertFalse(form.accessNeedsConfirmation(.auto, saved: stale))
        hosts[0].projects[project].agents[agent].access = .plan
        store.apply(.hosts(hosts))
        XCTAssertTrue(form.accessNeedsConfirmation(.auto, saved: stale), "Auto raises the fresh Plan level, even before settings reload")
        XCTAssertTrue(form.accessNeedsConfirmation(.fullAccess, saved: stale), "The stale Full access selection must not bypass confirmation")
        XCTAssertFalse(form.accessNeedsConfirmation(.ask, saved: stale))
    }

    private func assertOpenSheetRefreshes(details: Bool) async throws {
        let service = QA361SettingsService()
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.sleepingTarget
        var hosts = CompanionPreviewService.hosts(now: Date())
        store.apply(.hosts(hosts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            if details {
                CompanionAgentDetailsSheet(store: store, target: target)
            } else {
                CompanionAgentSettingsForm(store: store, target: target)
            }
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKey()
            store.stop()
        }
        let initialDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.reads == 0, ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(service.reads, 1)
        service.level = .plan
        let project = try XCTUnwrap(hosts[0].projects.firstIndex { $0.id == target.projectID })
        let agent = try XCTUnwrap(hosts[0].projects[project].agents.firstIndex { $0.id == target })
        hosts[0].projects[project].agents[agent].access = .plan
        store.apply(.hosts(hosts))
        XCTAssertEqual(store.agent(for: target)?.access, .plan)
        let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while service.reads == 1, ContinuousClock.now < refreshDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(service.reads, 1, "The desktop broadcast changed saved Access, but the open sheet retained Ask first")
    }
}
