import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor private final class SessionModelSettingsService: CompanionService {
    let preview = CompanionPreviewService(showsDispatcher: true)
    var reads: [CompanionAgentSettings] = []
    var savedModel = "sonnet"
    var refusesSave = false
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
        var result = try await preview.settings(for: target)
        result.model.value = savedModel
        reads.append(result)
        return result
    }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings {
        if refusesSave { throw CompanionServiceError.rejected("Save refused by fixture") }
        if let model = change.model { savedModel = model }
        var result = try await preview.settings(for: target)
        result.model.value = savedModel
        return result
    }
}

@MainActor final class CompanionSessionModelTests: XCTestCase {
    func testSuccessfulSavedModelEditInvalidatesTheVisibleComposer() async throws {
        try await assertVisibleComposerRefreshes(desktopChange: false)
    }

    func testDesktopSavedModelChangeInvalidatesTheVisibleComposerWithoutChangingTheLiveModel() async throws {
        try await assertVisibleComposerRefreshes(desktopChange: true)
    }

    private func assertVisibleComposerRefreshes(desktopChange: Bool) async throws {
        let service = SessionModelSettingsService()
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        var hosts = CompanionPreviewService.hosts(now: Date(), dispatcher: true, contextWindow: true)
        hosts[0].dispatcher?.agent?.savedModel = "sonnet"
        store.apply(.hosts(hosts))
        await store.load(target)
        let agent = try XCTUnwrap(store.agent(for: target))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView:
            CompanionConversationComposer(store: store, agent: agent, memory: CompanionComposerMemory(),
                focusRequests: 0, confirmCancel: .constant(false), dismissals: 0))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKey(); store.stop() }
        try await waitForRead(service, after: 0)
        let previous = try XCTUnwrap(service.reads.last)
        XCTAssertEqual(agent.modelDifference(from: previous), .init(sessionLabel: "Opus", savedLabel: "Sonnet"))
        let before = service.reads.count
        let revision = store.settingsRevisions[target]

        if desktopChange {
            service.savedModel = "opus"
            hosts[0].dispatcher?.agent?.savedModel = "opus"
            store.apply(.hosts(hosts))
        } else {
            let saved = try await store.updateSettings(.init(model: "opus"), target: target)
            XCTAssertNil(agent.modelDifference(from: saved), "The successful save now equals the session")
        }
        XCTAssertNotEqual(store.settingsRevisions[target], revision)
        try await waitForRead(service, after: before)
        XCTAssertEqual(service.reads.last?.model.value, "opus")
        XCTAssertNil(agent.modelDifference(from: service.reads.last), "The composer must replace its stale Sonnet comparison")
        XCTAssertEqual(store.agent(for: target)?.chatControls?.model, "opus", "Only the saved choice changed")
    }

    func testEverySuccessfulPhoneSaveInvalidatesOnlyItsTargetButARefusalDoesNot() async throws {
        let service = SessionModelSettingsService()
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        store.apply(.hosts(CompanionPreviewService.hosts(now: Date(), dispatcher: true)))
        _ = try await store.updateSettings(.init(name: "New name"), target: target)
        let first = try XCTUnwrap(store.settingsRevisions[target])
        _ = try await store.updateSettings(.init(model: "opus"), target: target)
        let second = try XCTUnwrap(store.settingsRevisions[target])
        XCTAssertNotEqual(first, second)
        XCTAssertNil(store.settingsRevisions[CompanionPreviewService.target])
        service.refusesSave = true
        do {
            _ = try await store.updateSettings(.init(model: "sonnet"), target: target)
            XCTFail("The fixture must refuse the save")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Save refused by fixture")
        }
        XCTAssertEqual(store.settingsRevisions[target], second)
    }

    private func waitForRead(_ service: SessionModelSettingsService, after count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.reads.count <= count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(service.reads.count, count, "The visible composer must read current saved settings")
    }
}
