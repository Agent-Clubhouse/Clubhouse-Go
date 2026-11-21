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
        #expect(h.store.claimDispatcherRecoveryNewChat(cancelled, target: target) == nil)
        #expect(await h.transport.executed.isEmpty)
        await h.store.askDispatcherRecoveryNewChat(target)
        let prompt = try #require(h.store.dispatcherResetPrompt)
        let claim = try #require(h.store.claimDispatcherRecoveryNewChat(prompt, target: target))
        h.store.cancelDispatcherReset() // Automatic alert dismissal runs before the queued Task.
        await h.transport.enqueue(.completed(.object(["cleared": .string("now")])))
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        let sent = await h.transport.executed
        #expect(sent.count == 1 && sent.first?.kind == .clearDispatcherChat(expectedState: prompt.expectedState))
        #expect(h.store.dispatcherResetNotices[target.hostID] == "Its conversation started over.")
    }

    @Test func lostNewChatLocksReopenEqualReadsAndEveryRecoveryMutation() async throws {
        let h = try await start(); defer { h.stop() }
        await h.store.askDispatcherRecoveryNewChat(target)
        let prompt = try #require(h.store.dispatcherResetPrompt)
        let claim = try #require(h.store.claimDispatcherRecoveryNewChat(prompt, target: target))
        await h.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "synthetic-lost-new-chat")))
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        let original = await h.transport.executed
        #expect(original.count == 1 && h.store.dispatcherRecoveryUnknown.contains(target))
        await h.store.load(target, force: true)
        await h.store.askDispatcherRecoveryNewChat(target)
        #expect(h.store.claimDispatcherRecoveryNewChat(prompt, target: target) == nil)
        await h.store.confirmDispatcherRecoveryNewChat(claim)
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
        let claim = try #require(h.store.claimDispatcherRecoveryNewChat(first, target: target))
        guard case .object(var settings) = try ContractFixtures.body("dispatcher-settings.json", "on") else { throw CancellationError() }
        settings["clearChat"] = .object(["expectedState": .string("fresh-token"), "applies": .string("now")])
        await h.transport.setRead("dispatcherSettings", .object(settings))
        await h.transport.enqueue(.rejected(code: "stale_state", message: "Review again"))
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(h.store.dispatcherResetPrompt?.expectedState == "fresh-token")
        #expect(h.store.dispatcherResetPrompt?.changed != nil)
        #expect(await h.transport.executed.count == 1)
        #expect(h.store.claimDispatcherRecoveryNewChat(first, target: target) == nil)
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(await h.transport.executed.count == 1)
    }

    @Test func refusedNewChatDoesNotLockRecoveryOrRepeatTheClaim() async throws {
        let h = try await start(); defer { h.stop() }
        await h.store.askDispatcherRecoveryNewChat(target)
        let prompt = try #require(h.store.dispatcherResetPrompt)
        let claim = try #require(h.store.claimDispatcherRecoveryNewChat(prompt, target: target))
        await h.transport.enqueue(.rejected(code: "dispatcher_off", message: "The Dispatcher is turned off."))
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(h.store.dispatcherResetNotices[target.hostID] == "The Dispatcher is turned off on the desktop. Turn it on first.")
        #expect(h.store.dispatcherResetPrompt == nil)
        #expect(!h.store.dispatcherRecoveryUnknown.contains(target))
        #expect(!h.store.pendingCommands.contains(target) && !h.store.dispatcherResetting.contains(target.hostID))
        #expect(h.store.dispatcherRecovery(for: target)?.canStartNewChat == true)
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(await h.transport.executed.count == 1)
        await h.store.askDispatcherRecoveryNewChat(target)
        let fresh = try #require(h.store.dispatcherResetPrompt)
        #expect(h.store.dispatcherResetNotices[target.hostID] == nil)
        #expect(await h.transport.executed.count == 1, "A fresh confirmation read must not repeat a refused mutation")
        // The prompt identifies the desktop state; the claim identifies this human confirmation.
        let freshClaim = try #require(h.store.claimDispatcherRecoveryNewChat(fresh, target: target))
        #expect(freshClaim != claim)
        #expect(h.store.dispatcherResetPrompt == nil)
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(await h.transport.executed.count == 1, "The spent claim must not consume the new confirmation")
        #expect(h.store.pendingCommands.contains(target))
        await h.transport.enqueue(.completed(.object(["cleared": .string("now")])))
        await h.store.confirmDispatcherRecoveryNewChat(freshClaim)
        await h.store.confirmDispatcherRecoveryNewChat(freshClaim)
        let sent = await h.transport.executed
        #expect(sent.count == 2 && sent.last?.kind == .clearDispatcherChat(expectedState: fresh.expectedState))
        #expect(h.store.dispatcherResetNotices[target.hostID] == "Its conversation started over.")
        #expect(!h.store.pendingCommands.contains(target) && !h.store.dispatcherResetting.contains(target.hostID))
        #expect(!h.store.dispatcherRecoveryUnknown.contains(target))
    }

    @Test func dispatcherTurnedOffAfterClaimCannotReceiveANewChatMutation() async throws {
        let h = try await start(); defer { h.stop() }
        await h.store.askDispatcherRecoveryNewChat(target)
        let prompt = try #require(h.store.dispatcherResetPrompt)
        let claim = try #require(h.store.claimDispatcherRecoveryNewChat(prompt, target: target))
        await h.transport.emit(h.snapshotEvent(["dispatcher": .object([
            "enabled": .bool(false), "flagOn": .bool(true), "projectId": .string(target.projectID),
            "agent": .object(["id": .string(target.agentID), "name": .string("Navi"), "kind": .string("durable"),
                              "status": .string("running"), "projectId": .string(target.projectID), "isDispatcher": .bool(true)])
        ])]))
        try await h.waitUntil { h.host?.dispatcher?.enabled == false }
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(await h.transport.executed.isEmpty)
        #expect(!h.store.pendingCommands.contains(target) && !h.store.dispatcherResetting.contains(target.hostID))
        #expect(!h.store.dispatcherRecoveryUnknown.contains(target))
        #expect(h.store.dispatcherResetNotices[target.hostID] == "This Dispatcher changed. Review its current state before starting a new chat.")
        await h.store.confirmDispatcherRecoveryNewChat(claim)
        #expect(await h.transport.executed.isEmpty)
    }

    @Test func changedChatDuringConfirmationCannotReceiveAStop() async throws {
        let h = try await start(); defer { h.stop() }
        #expect(h.store.dispatcherRecovery(for: target)?.canStop == true)
        h.store.askDispatcherChatAction(.stop, target: target)
        let prompt = try #require(h.store.dispatcherChatPrompt)
        let claim = try #require(h.store.claimDispatcherChatAction(prompt))
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "replacement-session"))
        await h.store.load(target, force: true)
        await h.store.confirmDispatcherChatAction(claim)
        #expect(await h.transport.executed.isEmpty)
        #expect(h.store.operationErrors[target]?.contains("changed") == true)
    }

    @Test func stopTargetsOnlyTheVisibleChatAndAcknowledgementIsNotSleepProof() async throws {
        let h = try await start(); defer { h.stop() }
        h.store.askDispatcherChatAction(.stop, target: target)
        let prompt = try #require(h.store.dispatcherChatPrompt)
        let claim = try #require(h.store.claimDispatcherChatAction(prompt))
        h.store.dispatcherChatPrompt = nil // SwiftUI dismissal must not cancel the claimed action.
        await h.transport.enqueue(.completed(.object(["stopRequested": .bool(true)])))
        await h.store.confirmDispatcherChatAction(claim)
        let sent = await h.transport.executed
        #expect(sent.count == 1 && sent.first?.kind == .stop(agentID: target.agentID))
        #expect(h.store.sleepRequests.contains(target), "A stop request does not establish stopped state")
        #expect(h.store.agent(for: target)?.isSleepingOnDesktop != true)
        await h.store.confirmDispatcherChatAction(claim)
        #expect(await h.transport.executed.count == 1)
    }

    @Test func dismissalBeforeTaskStillInterruptsTheConfirmedVisibleSessionOnce() async throws {
        let h = try await start(); defer { h.stop() }
        try await h.waitUntil {
            h.store.agent(for: target)?.status == .idle && h.store.conversation(for: target).sessionID == "visible-session"
        }
        h.store.askDispatcherChatAction(.interrupt, target: target)
        #expect(h.store.dispatcherChatPrompt == nil)
        #expect(await h.transport.executed.isEmpty, "An idle visible chat cannot dispatch Interrupt")
        print("DISPATCHER_RECOVERY_STATE idle target=\(target) session=\(h.store.conversation(for: target).sessionID ?? "nil") interrupt=\(h.store.dispatcherRecovery(for: target)?.canInterrupt == true)")
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: "visible-session", fields: [
            "state": .string("running"), "capabilities": .object(["chat": .bool(true), "interrupt": .bool(true)])
        ]))
        await h.store.load(target, force: true)
        // history() emits the working host asynchronously; await this target's actual observed state.
        try await h.waitUntil {
            h.store.agent(for: target)?.status == .working && h.store.agent(for: target)?.capabilities.contains(.cancel) == true
                && h.store.conversation(for: target).sessionID == "visible-session"
        }
        #expect(h.store.dispatcherRecovery(for: target)?.canInterrupt == true)
        print("DISPATCHER_RECOVERY_STATE working target=\(target) session=\(h.store.conversation(for: target).sessionID ?? "nil") interrupt=\(h.store.dispatcherRecovery(for: target)?.canInterrupt == true)")
        h.store.askDispatcherChatAction(.interrupt, target: target)
        let prompt = try #require(h.store.dispatcherChatPrompt)
        let claim = try #require(h.store.claimDispatcherChatAction(prompt))
        h.store.dispatcherChatPrompt = nil
        #expect(h.store.claimDispatcherChatAction(prompt) == nil)
        await h.transport.enqueue(.completed())
        await h.store.confirmDispatcherChatAction(claim)
        await h.store.confirmDispatcherChatAction(claim)
        let sent = await h.transport.executed
        #expect(sent.count == 1 && sent.first?.kind == .interrupt(agentID: target.agentID, sessionID: "visible-session"))
    }
}
