import XCTest
import SwiftUI
import Vision
@testable import ClubhouseGo

@MainActor private final class SessionModelSettingsService: CompanionService {
    let preview = CompanionPreviewService(showsDispatcher: true)
    var reads: [CompanionAgentSettings] = []
    var savedModel = "sonnet"
    var refusesSave = false
    var refusesRead = false
    var failedReads = 0
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
        if refusesRead {
            failedReads += 1
            throw CompanionServiceError.unavailable("Settings refresh failed")
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
    func testFailedRereadHidesTheStaleModelDifferenceAndShowsErrorWithRetry() async throws {
        let service = SessionModelSettingsService()
        let target = CompanionPreviewService.target
        try await withSettingsForm(service: service, target: target) { store, window, initial in
            let before = try await self.renderedText(window, stage: "Before refresh")
            XCTAssertTrue(before.contains("Saved") && before.contains(where: { $0.contains("Sonnet") }),
                          "The rendered form must initially show the proven Session/Saved difference")
            service.savedModel = "opus"
            service.holdNextRead = true
            service.refusesRead = true
            var hosts = initial
            let project = try XCTUnwrap(hosts[0].projects.firstIndex { $0.id == target.projectID })
            let agent = try XCTUnwrap(hosts[0].projects[project].agents.firstIndex { $0.id == target })
            hosts[0].projects[project].agents[agent].savedModel = "opus"
            store.apply(.hosts(hosts))
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while service.pendingRead == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pending = try XCTUnwrap(service.pendingRead)
            let during = try await self.renderedText(window, stage: "While refresh is pending")
            XCTAssertFalse(during.contains("Saved"), "The old comparison must disappear before the read completes")
            service.pendingRead = nil
            pending.resume()
            let failureDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while service.failedReads == 0, ContinuousClock.now < failureDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(service.failedReads, 1)
            let after = try await self.renderedText(window, stage: "After failed refresh")
            XCTAssertFalse(after.contains("Saved"), "A failed refresh must not restore the stale comparison")
            XCTAssertTrue(after.contains(where: { $0.contains("Settings refresh failed") }), "Show the refresh error")
            XCTAssertTrue(after.contains("Retry"), "Offer an explicit retry without removing the form")
            XCTAssertTrue(after.contains("Model") && after.contains(where: { $0.contains("Sonnet") }),
                          "Keep the existing settings visible, without claiming a difference")
            XCTAssertEqual(service.reads.count, 1, "The failed refresh must not start a read loop")
        }
    }

    private func renderedText(_ window: UIWindow, stage: String) async throws -> [String] {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(find(window))
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        var result: [String] = []
        for offset in Array(stride(from: CGFloat(0), through: maxOffset, by: 400)) + [maxOffset] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(stage)-\(Int(offset))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            result += request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }
        return result
    }

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
