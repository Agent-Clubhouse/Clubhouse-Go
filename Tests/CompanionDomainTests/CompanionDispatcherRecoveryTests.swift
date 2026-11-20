import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@MainActor @Suite struct CompanionDispatcherRecoveryTests {
    private let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "durable_dispatcher")

    private func start() async throws -> LiveServiceHarness {
        guard case .object(var feature)? = try ContractFixtures.body("capabilities.json")["dispatcher"] else { throw CancellationError() }
        feature["enabled"] = .bool(true); feature["flagOn"] = .bool(true)
        let enabled = feature
        let settings = try ContractFixtures.body("dispatcher-settings.json", "on")
        let h = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", .object(enabled))
            await transport.addCommands(["agent.stop", "dispatcher.setEnabled", "dispatcher.update", "dispatcher.setModels", "dispatcher.clearChat", "dispatcher.forgetEverything"])
            await transport.setRead("dispatcherSettings", settings)
            await transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "visible-session"))
        })
        await h.transport.emit(h.snapshotEvent(["dispatcher": .object([
            "enabled": .bool(true), "flagOn": .bool(true), "projectId": .string(target.projectID),
            "agent": .object(["id": .string(target.agentID), "name": .string("Navi"), "kind": .string("durable"),
                              "status": .string("running"), "projectId": .string(target.projectID), "isDispatcher": .bool(true)])
        ])]))
        try await h.waitUntil { h.store.agent(for: target) != nil }
        await h.store.load(target)
        return h
    }

    @Test func recoveryNeverSubstitutesAControllerOtherHostOrProject() async throws {
        let h = try await start(); defer { h.stop() }
        #expect(h.store.dispatcherRecovery(for: target)?.target == target)
        for wrong in [CompanionTarget(hostID: "other-host", projectID: target.projectID, agentID: target.agentID),
                      .init(hostID: target.hostID, projectID: "project", agentID: target.agentID),
                      .init(hostID: target.hostID, projectID: target.projectID, agentID: "hidden-controller")] {
            #expect(h.store.dispatcherRecovery(for: wrong) == nil)
            await h.store.askDispatcherRecoveryNewChat(wrong)
            h.store.askDispatcherChatAction(.stop, target: wrong)
            #expect(h.store.dispatcherResetPrompt == nil && h.store.dispatcherChatPrompt == nil)
        }
        #expect(await h.transport.executed.isEmpty)
    }

    @Test func cancelledNewChatHasNoMutationAndConfirmedPromptIsConsumedOnce() async throws {
        let h = try await start(); defer { h.stop() }
        await h.store.askDispatcherRecoveryNewChat(target)
        let cancelled = try #require(h.store.dispatcherResetPrompt)
        h.store.cancelDispatcherReset()
        await h.store.confirmDispatcherRecoveryNewChat(cancelled, target: target)
        #expect(await h.transport.executed.isEmpty)
        await h.store.askDispatcherRecoveryNewChat(target)
        let prompt = try #require(h.store.dispatcherResetPrompt)
        await h.transport.enqueue(.completed(.object(["cleared": .string("now")])))
        await h.store.confirmDispatcherRecoveryNewChat(prompt, target: target)
        await h.store.confirmDispatcherRecoveryNewChat(prompt, target: target)
        let sent = await h.transport.executed
        #expect(sent.count == 1 && sent.first?.kind == .clearDispatcherChat(expectedState: prompt.expectedState))
        #expect(h.store.dispatcherResetNotices[target.hostID] == "Its conversation started over.")
    }

    @Test func lostNewChatLocksReopenEqualReadsAndEveryRecoveryMutation() async throws {
        let h = try await start(); defer { h.stop() }
        await h.store.askDispatcherRecoveryNewChat(target)
        let prompt = try #require(h.store.dispatcherResetPrompt)
        await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "synthetic-lost-new-chat")))
        await h.store.confirmDispatcherRecoveryNewChat(prompt, target: target)
        let original = await h.transport.executed
        #expect(original.count == 1 && h.store.dispatcherRecoveryUnknown.contains(target))
        await h.store.load(target, force: true)
        await h.store.askDispatcherRecoveryNewChat(target)
        await h.store.confirmDispatcherRecoveryNewChat(prompt, target: target)
        h.store.askDispatcherChatAction(.stop, target: target)
        h.store.askDispatcherChatAction(.interrupt, target: target)
        await h.store.cancel(target); await h.store.sleepAgent(target)
        let state = try #require(h.store.dispatcherRecovery(for: target))
        #expect(!state.canInterrupt && !state.canStop && !state.canStartNewChat)
        #expect(state.unavailableReason == CompanionDispatcherRecovery.unknownReset)
        #expect(!h.store.canOperate(target) && !h.store.canEditDispatcherSettings(hostID: target.hostID))
        #expect(await h.transport.executed.map(\.commandID) == original.map(\.commandID))
    }

    @Test func staleNewChatRequiresAnotherHumanConfirmation() async throws {
        let h = try await start(); defer { h.stop() }
        await h.store.askDispatcherRecoveryNewChat(target)
        let first = try #require(h.store.dispatcherResetPrompt)
        guard case .object(var settings) = try ContractFixtures.body("dispatcher-settings.json", "on") else { throw CancellationError() }
        settings["clearChat"] = .object(["expectedState": .string("fresh-token"), "applies": .string("now")])
        await h.transport.setRead("dispatcherSettings", .object(settings))
        await h.transport.enqueue(.rejected(code: "stale_state", message: "Review again"))
        await h.store.confirmDispatcherRecoveryNewChat(first, target: target)
        #expect(h.store.dispatcherResetPrompt?.expectedState == "fresh-token")
        #expect(h.store.dispatcherResetPrompt?.changed != nil)
        #expect(await h.transport.executed.count == 1)
        await h.store.confirmDispatcherRecoveryNewChat(first, target: target)
        #expect(await h.transport.executed.count == 1)
    }

    @Test func changedChatDuringConfirmationCannotReceiveAStop() async throws {
        let h = try await start(); defer { h.stop() }
        #expect(h.store.dispatcherRecovery(for: target)?.canStop == true)
        h.store.askDispatcherChatAction(.stop, target: target)
        let prompt = try #require(h.store.dispatcherChatPrompt)
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "replacement-session"))
        await h.store.load(target, force: true)
        await h.store.confirmDispatcherChatAction(prompt)
        #expect(await h.transport.executed.isEmpty)
        #expect(h.store.operationErrors[target]?.contains("changed") == true)
    }

    @Test func stopTargetsOnlyTheVisibleChatAndAcknowledgementIsNotSleepProof() async throws {
        let h = try await start(); defer { h.stop() }
        h.store.askDispatcherChatAction(.stop, target: target)
        let prompt = try #require(h.store.dispatcherChatPrompt)
        await h.transport.enqueue(.completed(.object(["stopRequested": .bool(true)])))
        await h.store.confirmDispatcherChatAction(prompt)
        let sent = await h.transport.executed
        #expect(sent.count == 1 && sent.first?.kind == .stop(agentID: target.agentID))
        #expect(h.store.sleepRequests.contains(target), "A stop request does not establish stopped state")
        #expect(h.store.agent(for: target)?.isSleepingOnDesktop != true)
        await h.store.confirmDispatcherChatAction(prompt)
        #expect(await h.transport.executed.count == 1)
    }
}
