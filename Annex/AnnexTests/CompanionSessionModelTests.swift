import XCTest
import SwiftUI
@testable import ClubhouseGo

@MainActor private final class SessionModelSettingsService: CompanionService {
    let preview = CompanionPreviewService(showsDispatcher: true)
    var reads: [CompanionAgentSettings] = []
    var savedModel = "sonnet"
    var refusesSave = false
    var savedName: String?
    var savedEmoji: String?
    var holdNextRead = false
    var pendingRead: CheckedContinuation<Void, Never>?
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
        if let savedName { result.name.value = savedName }
        if let savedEmoji { result.emoji.value = savedEmoji }
        if holdNextRead {
            holdNextRead = false
            await withCheckedContinuation { pendingRead = $0 }
        }
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
    func testOpenSettingsFormRefreshesWhenTheDesktopSavedModelChanges() async throws {
        let service = SessionModelSettingsService()
        try await withSettingsForm(service: service, target: CompanionPreviewService.target) { store, window, initial in
            let target = CompanionPreviewService.target
            let agent = try XCTUnwrap(store.agent(for: target))
            XCTAssertNotNil(agent.modelDifference(from: service.reads.last))
            var hosts = initial
            let project = try XCTUnwrap(hosts[0].projects.firstIndex { $0.id == target.projectID })
            let index = try XCTUnwrap(hosts[0].projects[project].agents.firstIndex { $0.id == target })
            for model in ["opus", "sonnet"] {
                let before = service.reads.count
                let revision = store.settingsRevisions[target]
                service.savedModel = model
                hosts[0].projects[project].agents[index].savedModel = model
                store.apply(.hosts(hosts))
                XCTAssertNotEqual(store.settingsRevisions[target], revision)
                try await self.waitForRead(service, after: before)
                XCTAssertEqual(service.reads.last?.model.value, model)
                XCTAssertEqual(agent.modelDifference(from: service.reads.last) == nil, model == "opus")
                window.layoutIfNeeded()
            }
        }
    }

    func testOpenSettingsFormPreservesEditsMadeBeforeAndDuringTheReread() async throws {
        let service = SessionModelSettingsService()
        let target = CompanionPreviewService.sleepingTarget
        try await withSettingsForm(service: service, target: target) { store, window, _ in
            let name = try await self.textField("Name", in: window)
            let emoji = try await self.textField("None", in: window)
            XCTAssertTrue(name.becomeFirstResponder())
            name.insertText(" draft")
            let draft = try XCTUnwrap(name.text)
            let before = service.reads.count
            service.savedName = "Desktop name"
            service.savedEmoji = "X"
            service.savedModel = "opus"
            service.holdNextRead = true
            _ = try await store.updateSettings(.init(model: "opus"), target: target)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while service.pendingRead == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pending = try XCTUnwrap(service.pendingRead)
            name.insertText(" mid-read")
            pending.resume()
            service.pendingRead = nil
            try await self.waitForRead(service, after: before)
            let appliedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while emoji.text != "X", ContinuousClock.now < appliedDeadline {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(emoji.text, "X", "Unedited fields adopt the new saved baseline")
            XCTAssertEqual(name.text, draft + " mid-read", "The reread must not replace the user's unsaved text")
            XCTAssertTrue(name.isFirstResponder)
        }
    }

    private func withSettingsForm(service: SessionModelSettingsService, target: CompanionTarget,
                                  probe: (CompanionStore, UIWindow, [CompanionHost]) async throws -> Void) async throws {
        let store = CompanionStore(service: service)
        var hosts = CompanionPreviewService.hosts(now: Date(), contextWindow: true)
        for project in hosts[0].projects.indices {
            for agent in hosts[0].projects[project].agents.indices {
                hosts[0].projects[project].agents[agent].savedModel = "sonnet"
            }
        }
        store.apply(.hosts(hosts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionAgentSettingsSheet(store: store, target: target))
        window.makeKeyAndVisible()
        defer { service.pendingRead?.resume(); service.pendingRead = nil; window.isHidden = true; window.rootViewController = nil; original?.makeKey(); store.stop() }
        try await waitForRead(service, after: 0)
        try await probe(store, window, hosts)
    }

    private func textField(_ placeholder: String, in window: UIWindow) async throws -> UITextField {
        func find(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField, field.placeholder == placeholder { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            if let field = find(window) { return field }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(find(window), "The settings form must render the \(placeholder) editor")
    }

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
