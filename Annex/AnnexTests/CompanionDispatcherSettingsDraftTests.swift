import XCTest
import SwiftUI
@testable import ClubhouseTransport
@testable import ClubhouseGo

@MainActor final class CompanionDispatcherSettingsDraftTests: XCTestCase {
    private static let corpus = [
        "\u{1F642}", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F1FA}\u{1F1F3}",
        "\u{1F44D}\u{1F3FD}", "\u{20000}", "e\u{301}"
    ]

    func testRepeatedSettingsAndUnrelatedSaveKeepEveryPendingFieldByteExact() {
        for sample in Self.corpus {
            var settings = CompanionPreviewService.previewDispatcherSettings
            var drafts = CompanionDispatcherSettingsDrafts()
            drafts.receive(settings)
            drafts.name.text += sample
            drafts.emoji.text = sample
            drafts.personality.text += sample
            let name = Array(drafts.name.text.utf8)
            let personality = Array(drafts.personality.text.utf8)
            drafts.receive(settings)
            settings.behavior.value = "thorough"
            drafts.receive(settings)
            XCTAssertEqual(Array(drafts.name.text.utf8), name)
            XCTAssertEqual(Array(drafts.emoji.text.utf8), Array(sample.utf8))
            XCTAssertEqual(Array(drafts.personality.text.utf8), personality)
            XCTAssertFalse(drafts.name.hasConflict)

            settings.identity.name = "Desktop name"
            settings.identity.emoji = "Desktop emoji"
            settings.personality?.text = "Desktop personality"
            drafts.receive(settings)
            XCTAssertEqual(Array(drafts.name.text.utf8), name)
            XCTAssertEqual(Array(drafts.emoji.text.utf8), Array(sample.utf8))
            XCTAssertEqual(Array(drafts.personality.text.utf8), personality)
            XCTAssertTrue(drafts.name.hasConflict)
            XCTAssertTrue(drafts.emoji.hasConflict)
            XCTAssertTrue(drafts.personality.hasConflict)

            settings.identity.name = "Saved name"
            drafts.receive(settings, saved: .name)
            XCTAssertEqual(drafts.name.text, "Saved name", "A submitted field accepts the desktop's normalized result")
            XCTAssertFalse(drafts.name.hasConflict)
            XCTAssertEqual(Array(drafts.emoji.text.utf8), Array(sample.utf8), "Saving name does not discard another field")
            XCTAssertEqual(Array(drafts.personality.text.utf8), personality)
        }
    }

    func testCanonicalEquivalentEditIsStillPendingAndConflictClearsWhenResolved() {
        var field = CompanionDispatcherSettingsDrafts.TextDraft()
        field.receive("\u{e9}")
        field.text = "e\u{301}"
        field.receive("Changed on desktop")
        XCTAssertEqual(Array(field.text.utf8), Array("e\u{301}".utf8))
        XCTAssertTrue(field.hasConflict)
        field.text = "Changed on desktop"
        XCTAssertFalse(field.hasConflict)
        field.text += " new edit"
        XCTAssertFalse(field.hasConflict, "A resolved conflict must not reappear for a later edit")
        field.receive("Changed on desktop new edit")
        XCTAssertFalse(field.hasConflict, "An incoming value matching the draft acknowledges it")
        field.receive("Next desktop value")
        XCTAssertEqual(field.text, "Next desktop value", "Acknowledgement makes the field clean again")
    }

    func testOlderSaveReceiptDoesNotRevertANewerUnrelatedCleanField() {
        var saved = CompanionPreviewService.previewDispatcherSettings
        var drafts = CompanionDispatcherSettingsDrafts()
        drafts.receive(saved)
        drafts.name.text = "Submitted name"
        saved.identity.name = drafts.name.text
        var newer = saved
        newer.identity.emoji = "New remote emoji"
        drafts.receive(newer)
        XCTAssertEqual(Array(drafts.emoji.text.utf8), Array("New remote emoji".utf8))
        drafts.receive(saved, saved: .name)
        XCTAssertEqual(Array(drafts.emoji.text.utf8), Array("New remote emoji".utf8))
        XCTAssertEqual(drafts.name.text, "Submitted name")
    }

    func testDraftsResetForAReplacementDispatcherAndIgnoreThePreviousAgentsReceipt() {
        var settings = CompanionPreviewService.previewDispatcherSettings
        var drafts = CompanionDispatcherSettingsDrafts()
        drafts.receive(settings)
        drafts.name.text = "Edit intended for deleted Dispatcher"
        drafts.emoji.text = "Old emoji draft"
        drafts.personality.text = "Old personality draft"
        let old = settings
        settings.agentID = "replacement_dispatcher"
        settings.identity.name = "Replacement Dispatcher"
        settings.identity.emoji = "New emoji"
        settings.personality?.text = "New personality"
        drafts.receive(settings)
        XCTAssertEqual(Array(drafts.name.text.utf8), Array(settings.identity.name.utf8))
        XCTAssertEqual(drafts.emoji.text, settings.identity.emoji)
        XCTAssertEqual(drafts.personality.text, settings.personality?.text)
        XCTAssertFalse(drafts.name.hasConflict)
        drafts.receive(old, saved: .name)
        XCTAssertEqual(drafts.name.text, settings.identity.name, "An old receipt cannot retarget the replacement")
    }

    func testCanonicalServerAcknowledgementMakesTheNativeNameClean() async throws {
        let service = DispatcherDraftTestService()
        service.current.identity.name = "\u{e9}"
        try await withForm(service) { store, window, render in
            let name = try XCTUnwrap(self.textField("Name", in: window))
            self.edit(name, to: "e\u{301}")
            XCTAssertEqual(Array((name.text ?? "").utf8), Array("e\u{301}".utf8))
            service.current.identity.name = "e\u{301}"
            service.publish(to: store)
            await self.waitUntil { render.name == Array("e\u{301}".utf8) }
            service.current.identity.name = "Next desktop value"
            service.publish(to: store)
            await self.waitUntil { render.name == Array("Next desktop value".utf8) }
            await self.waitUntil { self.textField("Name", in: window)?.text == "Next desktop value" }
            XCTAssertEqual(Array((self.textField("Name", in: window)?.text ?? "").utf8), Array("Next desktop value".utf8))
        }
    }

    func testSubmittingANormalizedEmojiMatchAcceptsOnlyTheSavedEmoji() async throws {
        let service = DispatcherDraftTestService()
        service.current.identity.emoji = "X"
        try await withForm(service) { store, window, render in
            let name = try XCTUnwrap(self.textField("Name", in: window))
            self.edit(name, to: "Pending name")
            let emoji = try XCTUnwrap(self.textField("None", in: window))
            self.edit(emoji, to: "Y ")
            service.current.identity.emoji = "Y"
            service.publish(to: store)
            await self.waitUntil { render.emoji == Array("Y".utf8) }
            XCTAssertEqual(Array((emoji.text ?? "").utf8), Array("Y ".utf8))
            emoji.sendActions(for: .editingDidEndOnExit)
            await self.waitUntil { emoji.text == "Y" }
            XCTAssertEqual(Array((emoji.text ?? "").utf8), Array("Y".utf8))
            XCTAssertNil(service.submitted, "An already-saved normalized value needs no command")
            service.current.identity.emoji = "Z"
            service.publish(to: store)
            await self.waitUntil { emoji.text == "Z" }
            XCTAssertEqual(self.textField("Name", in: window)?.text, "Pending name")
        }
    }

    func testLateNameSaveReceiptDoesNotRevertANewerCleanRemoteEmoji() async throws {
        let service = DispatcherDraftTestService()
        try await withForm(service) { store, window, render in
            let name = try XCTUnwrap(self.textField("Name", in: window))
            self.edit(name, to: "Submitted name")
            name.sendActions(for: .editingDidEndOnExit)
            await self.waitUntil { service.pending != nil }
            let pending = try XCTUnwrap(service.pending, "The production submit callback starts the save")
            var receipt = service.current
            receipt.identity.name = "Submitted name"
            service.current = receipt
            service.current.identity.emoji = "New remote emoji"
            service.publish(to: store)
            await self.waitUntil { render.emoji == Array("New remote emoji".utf8) }
            await self.waitUntil { self.textField("None", in: window)?.text == "New remote emoji" }
            service.pending = nil
            pending.resume(returning: receipt)
            await self.waitUntil { self.textField("Name", in: window)?.isEnabled == true }
            XCTAssertEqual(store.dispatcherSettings(hostID: CompanionPreviewService.dispatcherTarget.hostID)?.identity.emoji, "New remote emoji")
            XCTAssertEqual(Array((self.textField("None", in: window)?.text ?? "").utf8), Array("New remote emoji".utf8))
        }
    }

    func testLateReceiptDoesNotReplaceNewerAuthoritativeName() async throws {
        let started = expectation(description: "The native submit reaches the live transport")
        let transport = DispatcherDraftReceiptTransport(started: started)
        defer { Task { await transport.releaseCommand() } }
        let live = CompanionLiveService()
        let liveStore = CompanionStore(service: live)
        liveStore.start()
        let hostID = String(repeating: "ab:", count: 15) + "ab"
        defer { liveStore.shutdown(); live.remove(hostID: hostID) }
        await live.register(.init(host: try TrustedAnnexHost(
            endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432), verifiedHostID: hostID,
            verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32))),
            alias: "Receipt fixture", transport: transport))
        await waitUntil { liveStore.canEditDispatcherSettings(hostID: hostID) }
        _ = try await live.dispatcherSettings(hostID: hostID)

        let service = DispatcherDraftTestService()
        service.update = { update in
            try await live.updateDispatcher(update, hostID: hostID, clientCommandID: "held")
        }
        try await withForm(service) { store, window, render in
            let name = try XCTUnwrap(self.textField("Name", in: window))
            self.edit(name, to: "Submitted name")
            name.sendActions(for: .editingDidEndOnExit)
            await self.fulfillment(of: [started], timeout: 5)
            await self.waitUntil { self.textField("Name", in: window)?.isEnabled == false }
            await transport.setName("Newer desktop name")
            let newer = try await live.dispatcherSettings(hostID: hostID)
            service.current.identity.name = newer.identity.name
            service.publish(to: store)
            await self.waitUntil { render.name == Array("Newer desktop name".utf8) }
            XCTAssertEqual(self.textField("Name", in: window)?.text, "Submitted name")
            await transport.releaseCommand()
            await self.waitUntil { self.textField("Name", in: window)?.isEnabled == true }
            XCTAssertEqual(store.dispatcherSettings(hostID: CompanionPreviewService.dispatcherTarget.hostID)?.identity.name, "Newer desktop name")
            XCTAssertEqual(Array((self.textField("Name", in: window)?.text ?? "").utf8), Array("Newer desktop name".utf8),
                           "The production native callback must acknowledge the live service's authoritative result")
        }
        await transport.releaseCommand()
    }

    private func edit(_ field: UITextField, to text: String) {
        XCTAssertTrue(field.becomeFirstResponder())
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText(text)
    }

    private func withForm(_ service: DispatcherDraftTestService,
                          _ run: (CompanionStore, UIWindow, DispatcherDraftRender) async throws -> Void) async throws {
        let store = CompanionStore(service: service)
        service.publish(to: store)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let render = DispatcherDraftRender()
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: DispatcherDraftTestHost(store: store, render: render))
        window.makeKeyAndVisible()
        defer {
            if let pending = service.pending {
                service.pending = nil
                pending.resume(throwing: CancellationError())
            }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            store.shutdown()
        }
        await waitUntil {
            window.layoutIfNeeded()
            if self.textField("Name", in: window) == nil, let scroll = self.scrollView(in: window) {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 150)), animated: false)
            }
            return self.textField("Name", in: window) != nil
        }
        let name = try XCTUnwrap(textField("Name", in: window))
        let scroll = try XCTUnwrap(scrollView(in: window))
        let rect = name.convert(name.bounds, to: scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: rect.minY - scroll.adjustedContentInset.top - 20), animated: false)
        await waitUntil {
            window.layoutIfNeeded()
            let top = scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top
            return name.convert(name.bounds, to: window).minY >= top && self.textField("None", in: window)?.window != nil
        }
        try await run(store, window, render)
    }

    func testHostedFormReceivesDesktopNameChangesOffscreenWithoutReplacingPendingEdits() async throws {
        let service = CompanionPreviewService(showsDispatcher: true)
        service.showsDispatcherSettings = true
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        store.start()
        defer { store.shutdown() }
        await waitUntil { store.dispatcherSettings(hostID: target.hostID) != nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionAgentSettingsSheet(store: store, target: target))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        var input: UITextField?
        await waitUntil {
            window.layoutIfNeeded()
            input = self.textField("Name", in: window)
            if input == nil, let scroll = self.scrollView(in: window) {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 150)), animated: false)
            }
            return input != nil
        }
        XCTAssertEqual(input?.text, "Dispatcher")
        let initialName = try XCTUnwrap(input)
        let scroll = try XCTUnwrap(scrollView(in: window))
        let nameRect = initialName.convert(initialName.bounds, to: scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: nameRect.minY - scroll.adjustedContentInset.top - 20), animated: false)
        await waitUntil {
            window.layoutIfNeeded()
            let top = scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top
            let field = initialName.convert(initialName.bounds, to: window)
            return field.minY >= top && field.maxY < top + 80
        }
        for sample in Self.corpus {
            let name = "Desktop " + sample
            _ = try await service.updateDispatcher(.init(name: name), hostID: target.hostID, clientCommandID: UUID().uuidString)
            await waitUntil {
                window.layoutIfNeeded()
                return self.textField("Name", in: window)?.text == name
            }
            XCTAssertEqual(Array((textField("Name", in: window)?.text ?? "").utf8), Array(name.utf8))
        }
        let name = try XCTUnwrap(textField("Name", in: window))
        XCTAssertTrue(name.becomeFirstResponder())
        name.selectedTextRange = name.textRange(from: name.endOfDocument, to: name.endOfDocument)
        let suffix = Self.corpus.joined()
        name.insertText(suffix)
        let draft = "Desktop " + (try XCTUnwrap(Self.corpus.last)) + suffix
        XCTAssertEqual(Array((name.text ?? "").utf8), Array(draft.utf8))
        _ = try await service.updateDispatcher(.init(name: "Renamed externally", emoji: .set("X")),
            hostID: target.hostID, clientCommandID: UUID().uuidString)
        await waitUntil {
            window.layoutIfNeeded()
            return self.textField("None", in: window)?.text == "X"
        }
        XCTAssertEqual(Array((textField("Name", in: window)?.text ?? "").utf8), Array(draft.utf8),
            "The same incoming snapshot updates a clean emoji but preserves the edited name")
    }

    private func textField(_ placeholder: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == placeholder { return field }
        return view.subviews.lazy.compactMap { self.textField(placeholder, in: $0) }.first
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap(scrollView).first
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        await fulfillment(of: [reached], timeout: 5)
        XCTAssertTrue(condition(), "The hosted settings form must reach the expected state", file: file, line: line)
    }
}

@MainActor private final class DispatcherDraftTestService: CompanionService {
    let preview = CompanionPreviewService(showsDispatcher: true)
    var current = CompanionPreviewService.previewDispatcherSettings
    var pending: CheckedContinuation<CompanionDispatcherSettings, Error>?
    var submitted: AnnexDispatcherUpdate?
    var update: ((AnnexDispatcherUpdate) async throws -> CompanionDispatcherSettings)?
    func events() -> AsyncStream<CompanionEvent> { preview.events() }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { try await preview.history(for: target) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings { try await preview.settings(for: target) }
    func dispatcherSettings(hostID: String) async throws -> CompanionDispatcherSettings { current }
    func updateDispatcher(_ update: AnnexDispatcherUpdate, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        submitted = update
        if let change = self.update { return try await change(update) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func publish(to store: CompanionStore) {
        var hosts = CompanionPreviewService.hosts(now: Date(), dispatcher: true)
        hosts[0].canEditDispatcherSettings = true
        hosts[0].dispatcherSettings = current
        store.apply(.hosts(hosts))
    }
}

private actor DispatcherDraftReceiptTransport: AnnexTransporting {
    private let started: XCTestExpectation
    private var name = "Dispatcher"
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private var pending: CheckedContinuation<AnnexCommandReceipt, Never>?
    private var receipt: AnnexCommandReceipt?
    init(started: XCTestExpectation) { self.started = started }
    func setName(_ value: String) { name = value }
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() { continuation?.yield(.connection(.connected)) }
    func disconnect() { continuation?.yield(.connection(.disconnected)) }
    private func settings(name: String) -> AnnexJSON {
        .object([
            "agentId": .string("durable_dispatcher"),
            "behavior": .object(["value": .string("standard")]),
            "identity": .object(["name": .object(["value": .string(name), "editable": .string("always")])])
        ])
    }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities:
            return .object([
                "version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"),
                "controlAvailable": .bool(true),
                "commands": .array(["dispatcher.update", "dispatcher.setModels", "dispatcher.clearChat", "dispatcher.forgetEverything"].map(AnnexJSON.string)),
                "idempotency": .object(["scope": .string("client"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]),
                "dispatcher": .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true),
                                       "settings": .object(["version": .integer(1)])])
            ])
        case .dispatcherSettings: return settings(name: name)
        case .projects: return .array([])
        case .agents: return .array([])
        default: throw AnnexTransportError.unsupportedCapability("Dispatcher receipt fixture")
        }
    }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt {
        receipt = try AnnexJSON.object([
            "version": .integer(1), "epoch": .string("epoch"), "commandId": .string(command.commandID),
            "status": .string("completed"), "result": settings(name: "Submitted name")
        ]).decode(AnnexCommandReceipt.self)
        return await withCheckedContinuation {
            pending = $0
            started.fulfill()
        }
    }
    func releaseCommand() {
        if let receipt { pending?.resume(returning: receipt) }
        pending = nil
        receipt = nil
    }
}

@MainActor private final class DispatcherDraftRender {
    var name: [UInt8] = []
    var emoji: [UInt8] = []
}

@MainActor private struct DispatcherDraftTestHost: View {
    @Bindable var store: CompanionStore
    let render: DispatcherDraftRender
    var body: some View {
        CompanionAgentSettingsSheet(store: store, target: CompanionPreviewService.dispatcherTarget)
            .onChange(of: Array((store.dispatcherSettings(hostID: CompanionPreviewService.dispatcherTarget.hostID)?.identity.name ?? "").utf8), initial: true) {
                render.name = $1
            }
            .onChange(of: Array((store.dispatcherSettings(hostID: CompanionPreviewService.dispatcherTarget.hostID)?.identity.emoji ?? "").utf8), initial: true) {
                render.emoji = $1
            }
    }
}
