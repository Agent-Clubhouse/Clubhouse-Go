import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Settings > Dispatcher (#338) away from the wire: what a stale confirmation tells the person, what a reset reports,
/// and the preview desktop the UI tests drive.
@MainActor @Suite struct CompanionDispatcherSettingsTests {
    private let hostID = CompanionPreviewService.dispatcherTarget.hostID

    @Test(arguments: [
        ("next_start", "now", "Its chat woke up, so it would start over at once."),
        ("now", "next_start", "Its chat went to sleep, so it would start over when it next wakes."),
        ("now", "now", "Its conversation changed since you were asked."),
    ])
    func aStaleClearChatSaysWhatChanged(before: String, after: String, expected: String) {
        var old = CompanionPreviewService.previewDispatcherSettings
        old.clearChat.applies = before
        var new = old
        new.clearChat.applies = after
        let text = CompanionDispatcherResetPrompt.changes(.clearChat, from: old, to: new)
        #expect(text == "This changed since you were asked. \(expected) Check again and confirm.")
    }

    @Test func aStaleResetNamesARenameAndAMemoryChange() {
        let old = CompanionPreviewService.previewDispatcherSettings
        var new = old
        new.identity.name = "Robin"
        let text = CompanionDispatcherResetPrompt.changes(.forgetEverything, from: old, to: new)
        #expect(text.contains("It's now called Robin.") && text.contains("Its memory changed since you were asked"))
        #expect(CompanionDispatcherResetPrompt.changes(.clearChat, from: nil, to: new).contains("Its conversation changed"))
        let prompt = CompanionDispatcherResetPrompt(.forgetEverything, settings: new, hostID: hostID, changed: text)
        #expect(prompt?.message.hasPrefix(text) == true && prompt?.message.contains("Robin forgets its notes") == true)
    }

    @Test func outcomesAndErrorsReadAsSentences() {
        #expect(CompanionDispatcherResetOutcome.chatCleared(now: true).message == "Its conversation started over.")
        #expect(CompanionDispatcherResetOutcome.chatCleared(now: false).message == "Its conversation starts over the next time it wakes.")
        #expect(CompanionDispatcherResetOutcome.forgot(removed: 2, heldNews: 0).message == "Its memory was cleared.")
        #expect(CompanionDispatcherResetOutcome.forgot(removed: 2, heldNews: 3).message == "Its memory was cleared (2 removed, 3 held news dropped).")
        #expect(CompanionDispatcherSettingsError.stale(CompanionPreviewService.previewDispatcherSettings).errorDescription
                == "This changed since you were asked. Check again and confirm.")
        #expect(CompanionDispatcherReset.clearChat.id == "clearChat" && CompanionDispatcherReset.forgetEverything.action == "Forget everything")
        let split = CompanionDispatcherSettings.UsageSplit(turns: 1, input: 10, output: 5, reasoning: 2)
        #expect(split.tokens == 17)
        let settings = CompanionPreviewService.previewDispatcherSettings
        #expect(settings.behavior.selected?.label == "Standard" && settings.personality?.selected?.label == "Concise")
    }

    @Test func olderDesktopsAndOtherServicesOfferNoDispatcherSettings() async {
        let service = CompanionPreviewService()
        await #expect(throws: CompanionServiceError.self) { _ = try await service.dispatcherSettings(hostID: hostID) }
        await #expect(throws: CompanionServiceError.self) { _ = try await service.updateDispatcher(.init(behavior: "light"), hostID: hostID, clientCommandID: "c") }
        await #expect(throws: CompanionServiceError.self) { _ = try await service.setDispatcherModels(.byHand(true), hostID: hostID, clientCommandID: "c") }
        let prompt = CompanionDispatcherResetPrompt(.clearChat, settings: CompanionPreviewService.previewDispatcherSettings, hostID: hostID)!
        await #expect(throws: CompanionServiceError.self) { _ = try await service.resetDispatcher(prompt, clientCommandID: "c") }
        let store = CompanionStore(service: service)
        #expect(!store.canEditDispatcherSettings(hostID: hostID) && store.dispatcherSettings(hostID: hostID) == nil)
        await #expect(throws: CompanionServiceError.self) { _ = try await store.loadDispatcherSettings(hostID: hostID) }
        await #expect(throws: CompanionServiceError.self) { _ = try await store.updateDispatcher(.init(behavior: "light"), hostID: hostID) }
        await store.askDispatcherReset(.clearChat, hostID: hostID)
        #expect(store.dispatcherResetPrompt == nil && store.dispatcherResetNotices[hostID] == CompanionDispatcherSettings.updateDesktop)
    }

    /// The preview desktop behind `--companion-preview-dispatcher-settings`: every change is kept and shown again.
    @Test func thePreviewDesktopKeepsEveryChange() async throws {
        let service = CompanionPreviewService(showsDispatcher: true)
        service.showsDispatcherSettings = true
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop() }
        try await wait { store.canEditDispatcherSettings(hostID: hostID) }
        #expect(try await store.loadDispatcherSettings(hostID: hostID).behavior.value == "standard")

        var settings = try await store.updateDispatcher(.init(behavior: "thorough", name: "Robin", color: "rose", emoji: .set("🦉")), hostID: hostID)
        #expect(settings.behavior.value == "thorough" && settings.identity.name == "Robin" && settings.identity.color == "rose" && settings.identity.emoji == "🦉")
        try await wait { store.dispatcherSettings(hostID: hostID)?.identity.name == "Robin" }
        settings = try await store.updateDispatcher(.init(emoji: .clear, personality: .init(preset: "friendly")), hostID: hostID)
        #expect(settings.identity.emoji == nil && settings.personality?.preset == "friendly" && settings.personality?.text.hasPrefix("Be warm") == true)
        settings = try await store.updateDispatcher(.init(personality: .init(text: "Talk like a ship's captain.")), hostID: hostID)
        #expect(settings.personality?.preset == "custom")
        settings = try await store.updateDispatcher(.init(personality: .init(text: CompanionPreviewService.previewPersonalities[2].text)), hostID: hostID)
        #expect(settings.personality?.preset == "detailed", "Exactly a preset's text is that preset")

        settings = try await store.setDispatcherModels(.byHand(true), hostID: hostID)
        #expect(settings.models.byHand && !settings.behavior.setsModels && settings.models.roles.allSatisfy { $0.pick?.model == "opus" })
        settings = try await store.setDispatcherModels(.pick(role: "work", provider: "claude-code"), hostID: hostID)
        #expect(settings.models.roles.last?.pick?.model == "default")
        settings = try await store.setDispatcherModels(.pick(role: "work", model: "sonnet", effort: .set("high")), hostID: hostID)
        #expect(settings.models.roles.last?.pick == .init(provider: "claude-code", model: "sonnet", effort: "high"))
        settings = try await store.setDispatcherModels(.pick(role: "work", effort: .cliDefault), hostID: hostID)
        #expect(settings.models.roles.last?.pick?.effort == nil)
        await #expect(throws: CompanionServiceError.self) { _ = try await store.setDispatcherModels(.pick(role: "boss", model: "opus"), hostID: hostID) }

        // Each reset spends its own confirmation; reusing it is refused, never sent again.
        await store.askDispatcherReset(.clearChat, hostID: hostID)
        let clear = try #require(store.dispatcherResetPrompt)
        await store.confirmDispatcherReset(clear)
        #expect(store.dispatcherResetNotices[hostID] == "Its conversation started over.")
        await store.confirmDispatcherReset(clear)
        #expect(store.dispatcherResetNotices[hostID] == "This changed since you were asked. Check again and confirm.")
        await store.askDispatcherReset(.forgetEverything, hostID: hostID)
        let forget = try #require(store.dispatcherResetPrompt)
        #expect(forget.expectedState == "preview-forget-1")
        await store.confirmDispatcherReset(forget)
        #expect(store.dispatcherResetNotices[hostID] == "Its memory was cleared.")
        try await wait { store.dispatcherSettings(hostID: hostID)?.forgetEverything.expectedState == "preview-forget-1+" }
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out", sourceLocation: sourceLocation)
        throw CancellationError()
    }
}
