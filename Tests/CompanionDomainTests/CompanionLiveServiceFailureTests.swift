import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Commands through `CompanionLiveService` against a scripted desktop: how each outcome reaches the user,
/// and what happens when the desktop restarts, drops capabilities or answers with something unreadable.
@Suite @MainActor struct CompanionLiveServiceFailureTests {
    private typealias Harness = LiveServiceHarness

    private func kinds(_ harness: Harness) async -> [AnnexCommand.Kind] { await harness.transport.executed.map(\.kind) }

    // MARK: Session commands

    @Test func sessionCommandsWaitForALoadedConversation() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let target = harness.target
        let refresh = "Refresh the conversation before sending a command."
        #expect(await serviceErrorText { try await harness.service.cancel(target, clientCommandID: "c") } == refresh)
        #expect(await serviceErrorText { _ = try await harness.service.removeQueued("m", target: target, clientCommandID: "r") } == refresh)
        #expect(await serviceErrorText { try await harness.service.respond(to: "p", optionID: "allow", target: target, clientCommandID: "p") } == refresh)
        #expect(await serviceErrorText { try await harness.service.answer("q", answers: [:], target: target, clientCommandID: "q") } == refresh)
        #expect(await harness.transport.executed.isEmpty, "Nothing leaves the phone without a session to address")
    }

    @Test func sessionCommandsAddressTheLoadedSession() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let target = harness.target
        try await harness.loadSession()

        try await harness.service.cancel(target, clientCommandID: "cancel")
        await harness.transport.enqueue(.completed(.object(["removed": .array([.string("m1")])])))
        #expect(try await harness.service.removeQueued("m1", target: target, clientCommandID: "remove-1"))
        // Already sent: the desktop removes nothing, and the phone keeps showing it as sent.
        await harness.transport.enqueue(.completed(.object(["removed": .array([])])))
        #expect(try await !harness.service.removeQueued("m2", target: target, clientCommandID: "remove-2"))
        try await harness.service.respond(to: "perm-1", optionID: "allow_once", target: target, clientCommandID: "respond")
        try await harness.service.answer("question-1", answers: ["name": .text("Otter"), "colors": .choices(["red", "blue"])],
                                         target: target, clientCommandID: "answer")

        #expect(await kinds(harness) == [
            .interrupt(agentID: "agent", sessionID: "s1"),
            .removeQueued(agentID: "agent", sessionID: "s1", messageIDs: ["m1"]),
            .removeQueued(agentID: "agent", sessionID: "s1", messageIDs: ["m2"]),
            .permission(agentID: "agent", sessionID: "s1", requestID: "perm-1", optionID: "allow_once"),
            .question(agentID: "agent", sessionID: "s1", requestID: "question-1",
                      answers: ["name": .string("Otter"), "colors": .array([.string("red"), .string("blue")])]),
        ])
    }

    // MARK: Outcomes

    @Test func everyCommandOutcomeReachesTheUserAsTheRightError() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let target = harness.target
        try await harness.loadSession()
        func send(_ id: String, attachments: [String] = []) async throws {
            _ = try await harness.service.send(.init(target: target, text: "hi", clientCommandID: id, isSteering: false, attachmentIDs: attachments))
        }

        await harness.transport.enqueue(.rejected(code: "attachment_unavailable", message: "expired"))
        await #expect(throws: CompanionAttachmentError.attachmentUnavailable) { try await send("a", attachments: ["img-1"]) }
        await harness.transport.enqueue(.rejected(code: "images_not_supported", message: "no images"))
        await #expect(throws: CompanionAttachmentError.imagesNotSupported) { try await send("b", attachments: ["img-1"]) }
        await harness.transport.enqueue(.rejected(code: "not_chat", message: "not chat"))
        #expect(await serviceErrorText { try await send("c", attachments: ["img-1"]) } == CompanionLiveService.notChatMessage)
        await harness.transport.enqueue(.rejected(code: "busy", message: "Try later"))
        #expect(await serviceErrorText { try await send("d") } == "Try later")

        // `failed` may have partly run: never offered as a plain retry.
        await harness.transport.enqueue(.failed(message: "Half done"))
        #expect(await serviceErrorKind { try await send("e") } == .uncertain)
        await harness.transport.enqueue(.failed(message: nil))
        #expect(await serviceErrorText { try await send("f") } == "The command may have partially run. Refresh to check its result.")
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "g")))
        #expect(await serviceErrorText { try await send("g") } == "The desktop may have received this command, but its reply was lost.")
        // A disconnect before the command left is a plain refusal the user can retry.
        await harness.transport.enqueue(.thrown(.disconnected))
        #expect(await serviceErrorText { try await send("h") } == "The desktop is offline. Reconnect to continue.")
        #expect(await harness.transport.executed.count == 8)
    }

    @Test func aRetryAfterTheDesktopRestartedIsNotResent() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let target = harness.target
        try await harness.loadSession()
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "stop")))
        #expect(await serviceErrorKind { try await harness.service.cancel(target, clientCommandID: "stop") } == .uncertain)

        // The desktop restarts with a new epoch: the old command's fate can't be checked by resending it.
        await harness.transport.setEpoch("epoch-2")
        try await harness.refreshCatalog()
        #expect(await serviceErrorText { try await harness.service.cancel(target, clientCommandID: "stop") }
                == "The desktop restarted. Refresh the conversation to check the previous command.")
        #expect(await harness.transport.executed.count == 1)

        // A new logical command goes out under the new epoch.
        try await harness.service.cancel(target, clientCommandID: "stop-again")
        #expect(await harness.transport.executed.map(\.epoch) == ["epoch", "epoch-2"])
    }

    @Test func aDesktopWithoutMobileControlRefusesBeforeSending() async throws {
        let harness = try await Harness.start { await $0.setControlAvailable(false) }
        defer { harness.stop() }
        try await harness.loadSession()
        #expect(await serviceErrorText { try await harness.service.cancel(harness.target, clientCommandID: "c") }
                == "This desktop does not support mobile control. Update Clubhouse on desktop and reconnect.")
        #expect(await harness.transport.executed.isEmpty)
        #expect(harness.host?.canSpawn == false)
    }

    @Test func aSentMessageIsMatchedToTheDesktopsCopy() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let userMessage = Harness.chatEvent("s1", sequence: 2, type: "user_message", data: [
            "messageId": .string("u1"), "content": .array([.object(["type": .string("text"), "text": .string("Please continue")])])])
        try await harness.loadSession(Harness.chatSnapshot(events: [userMessage]))
        await harness.transport.enqueue(.completed(.object(["messageId": .string("u1")])))
        _ = try await harness.service.send(.init(target: harness.target, text: "Please continue", clientCommandID: "cmd-1", isSteering: false))
        // The match survives a reload of the conversation.
        let history = try await harness.service.history(for: harness.target)
        let message = history.items.compactMap { item -> CompanionMessage? in if case .message(let m) = item, m.id == "u1" { m } else { nil } }.first
        #expect(message?.clientCommandID == "cmd-1")
    }

    @Test func wakingAnAgentWhoseChatIsLiveIsRefused() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        try await harness.loadSession()
        #expect(await serviceErrorText { try await harness.service.wake(harness.target, resume: true, clientCommandID: "w") }
                == "Refresh the conversation before waking this agent.")
        #expect(await harness.transport.executed.isEmpty)
    }

    // MARK: Spawning quick agents

    @Test func aSpawnedQuickAgentIsListedBeforeTheDesktopCatalogHasIt() async throws {
        let harness = try await Harness.start { await $0.addCommands(["agent.spawn"]) }
        defer { harness.stop() }
        #expect(harness.host?.canSpawn == true)
        await harness.transport.enqueue(.completed(.object(["id": .string("q9"), "name": .string("brave-otter"), "state": .string("running")])))
        let receipt = try await harness.service.spawn(.init(project: harness.project, prompt: "Fix the build", provider: "claude-code",
                                                            model: "opus", clientCommandID: "spawn-1"))
        #expect(receipt.agentTarget == .init(hostID: Harness.hostID, projectID: "project", agentID: "q9"))
        #expect(await kinds(harness) == [.spawn(projectID: "project", prompt: "Fix the build", model: "opus", orchestrator: "claude-code")])
        try await harness.waitUntil { harness.host?.projects.first?.agents.contains { $0.id.agentID == "q9" } == true }
        let quick = try #require(harness.host?.projects.first?.agents.first { $0.id.agentID == "q9" })
        #expect(quick.isQuick && quick.name == "brave-otter" && quick.subtitle == "Fix the build")

        // An older desktop answers with `agentId` only; the id stands in for the name.
        await harness.transport.enqueue(.completed(.object(["agentId": .string("q10")])))
        let second = try await harness.service.spawn(.init(project: harness.project, prompt: "Lint", clientCommandID: "spawn-2"))
        #expect(second.agentTarget?.agentID == "q10")
        try await harness.waitUntil { harness.host?.projects.first?.agents.contains { $0.id.agentID == "q10" && $0.name == "q10" } == true }

        // A receipt that names no agent still succeeds, without a target to open.
        await harness.transport.enqueue(.completed(nil))
        #expect(try await harness.service.spawn(.init(project: harness.project, prompt: "Docs", clientCommandID: "spawn-3")).agentTarget == nil)

        await harness.transport.enqueue(.rejected(code: "spawn_failed", message: "No CLI"))
        #expect(await serviceErrorText { _ = try await harness.service.spawn(.init(project: harness.project, prompt: "x", clientCommandID: "spawn-4")) } == "No CLI")
    }

    // MARK: Capability downgrades

    @Test func featuresTheDesktopNoLongerOffersAreRefusedLocally() async throws {
        let harness = try await Harness.start { transport in
            await transport.addCommands(["project.setPinned", "project.setInactive", "quick.dismiss", "quick.clear",
                                         "helper.approve", "helper.decline", "agent.update", "agent.create"])
            await transport.setFeature("projectState", .object(["version": .integer(1)]))
            await transport.setFeature("finishedQuickAgents", .object(["version": .integer(1)]))
            await transport.setFeature("helperRequests", .object(["version": .integer(1)]))
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            await transport.setFeature("createOptions", .object(["version": .integer(1)]))
        }
        defer { harness.stop() }
        #expect(harness.host?.canSyncProjectState == true && harness.host?.canSyncFinishedQuick == true)
        #expect(harness.host?.canAnswerHelperRequests == true && harness.host?.canEditSettings == true && harness.host?.canCreateDurable == true)

        // The desktop is downgraded (or its features switched off) and the next catalog refresh sees it.
        await harness.transport.setCommands(["chat.send", "agent.start"])
        try await harness.refreshCatalog()
        #expect(harness.host?.canSyncProjectState == false && harness.host?.canSyncFinishedQuick == false)
        #expect(harness.host?.canAnswerHelperRequests == false && harness.host?.canEditSettings == false && harness.host?.canCreateDurable == false)

        let service = harness.service, target = harness.target, project = harness.project
        #expect(await serviceErrorText { _ = try await service.setProject(project, pinned: true, clientCommandID: "1") }
                == "Update Clubhouse on your desktop to share pins with your phone.")
        #expect(await serviceErrorText { _ = try await service.clearFinishedQuick(project, clientCommandID: "2") }
                == "Update Clubhouse on your desktop to share its finished list with your phone.")
        let request = CompanionHelperRequest(id: "h1", hostID: Harness.hostID, projectID: "project", kind: .start, requesterID: "agent",
                                             requesterName: "Agent", helperID: nil, helperName: "helper", requestedAt: nil, expiresAt: nil,
                                             summary: "Start", task: nil, dispose: nil)
        #expect(await serviceErrorText { try await service.answerHelperRequest(request, approve: true, force: false, clientCommandID: "3") }
                == "Update Clubhouse on your desktop to answer helper requests from your phone.")
        #expect(await serviceErrorKind { _ = try await service.settings(for: target) } == .unavailable)
        #expect(await serviceErrorKind { _ = try await service.createOptions(for: project) } == .unavailable)
        let image = CompanionImageAttachment(bytes: .init(Data([1, 2, 3])), mimeType: "image/png", width: 1, height: 1)
        #expect(await serviceErrorText { _ = try await service.upload(image, target: target) }
                == "This desktop can't take images. Update Clubhouse on your desktop.")
        #expect(await harness.transport.executed.isEmpty)
    }

    // MARK: Desktop-owned project state and finished list

    @Test func projectPinsFollowTheDesktopsReplyOrReportUncertainty() async throws {
        let harness = try await Harness.start { transport in
            await transport.addCommands(["project.setPinned", "project.setInactive"])
            await transport.setFeature("projectState", .object(["version": .integer(1)]))
        }
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent(["projectState": .object(["project": .object(["pinned": .bool(false)])])]))
        try await harness.waitUntil { harness.host?.sharesProjectState == true }

        await harness.transport.enqueue(.completed(.object(["pinned": .bool(true), "idle": .bool(false)])))
        let pinned = try await harness.service.setProject(harness.project, pinned: true, clientCommandID: "pin")
        #expect(pinned.pinned)
        // The reply shows until the next snapshot.
        try await harness.waitUntil { harness.host?.projectState?["project"]?.pinned == true }

        // The desktop took it but its reply has no state: the phone can't say what happened.
        await harness.transport.enqueue(.completed(nil))
        #expect(await serviceErrorKind { _ = try await harness.service.setProject(harness.project, inactive: true, clientCommandID: "inactive") } == .uncertain)
        #expect(await kinds(harness) == [.setProjectPinned(projectID: "project", pinned: true), .setProjectInactive(projectID: "project", inactive: true)])
        #expect(harness.host?.projectState?["project"]?.inactive == false)

        await harness.transport.enqueue(.rejected(code: "project_pinned", message: "pinned"))
        #expect(await serviceErrorText { _ = try await harness.service.setProject(harness.project, inactive: true, clientCommandID: "inactive-2") }
                == "Unpin this project before marking it inactive.")
    }

    @Test func clearingTheFinishedListUsesTheDesktopsReply() async throws {
        let harness = try await Harness.start { transport in
            await transport.addCommands(["quick.dismiss", "quick.clear"])
            await transport.setFeature("finishedQuickAgents", .object(["version": .integer(1)]))
        }
        defer { harness.stop() }
        // Before the desktop's snapshot carries a list, the reply is returned without being kept.
        await harness.transport.enqueue(.completed(.object(["finishedQuickAgents": .array([])])))
        #expect(try await harness.service.clearFinishedQuick(harness.project, clientCommandID: "clear").isEmpty)
        #expect(harness.host?.finishedQuickAgents == nil)

        await harness.transport.enqueue(.completed(.object(["finishedQuickAgents": .string("not a list")])))
        #expect(await serviceErrorText { _ = try await harness.service.clearFinishedQuick(harness.project, clientCommandID: "clear-2") }
                == "The desktop took the change but didn't confirm it. It will show when the desktop next updates.")
        #expect(await kinds(harness) == [.clearFinishedQuick(projectID: "project"), .clearFinishedQuick(projectID: "project")])
    }

    // MARK: Agent settings and create options

    @Test func settingsReadsAndUpdatesMapDesktopFailures() async throws {
        let harness = try await Harness.start { transport in
            await transport.addCommands(["agent.update", "agent.create"])
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            await transport.setFeature("createOptions", .object(["version": .integer(1)]))
        }
        defer { harness.stop() }
        let service = harness.service, target = harness.target, project = harness.project

        await harness.transport.failRead("agentSettings", .rejected(status: 404, code: "agent_not_found"))
        #expect(await serviceErrorText { _ = try await service.settings(for: target) } == "This agent is no longer on the desktop.")
        await harness.transport.setRead("agentSettings", .object(["settings": .object([:])]))
        #expect(await serviceErrorText { _ = try await service.settings(for: target) }
                == "The desktop sent settings this phone can't read. Updating the desktop may help.")
        await harness.transport.failRead("agentSettings", .disconnected)
        #expect(await serviceErrorText { _ = try await service.settings(for: target) } == "The desktop is offline. Reconnect to continue.")

        await harness.transport.failRead("createOptions", .rejected(status: 404, code: "project_not_found"))
        #expect(await serviceErrorText { _ = try await service.createOptions(for: project) } == "This project is no longer on the desktop.")
        await harness.transport.failRead("createOptions", .rejected(status: 404, code: nil))
        #expect(await serviceErrorText { _ = try await service.createOptions(for: project) } == "Desktop request failed (404).")
        await harness.transport.setRead("createOptions", .object([:]))
        #expect(await serviceErrorText { _ = try await service.createOptions(for: project) }
                == "The desktop sent settings this phone can't read. Updating the desktop may help.")

        // Free Agent Mode isn't offered by this desktop: refused before anything is sent.
        var change = CompanionSettingsChange(); change.freeAgentMode = true
        #expect(await serviceErrorText { _ = try await service.updateSettings(change, target: target, clientCommandID: "u1") }
                == "Free Agent Mode can only be changed on the desktop.")
        #expect(await serviceErrorText { _ = try await service.updateSettings(.init(), target: target, clientCommandID: "u0") } == "Nothing to change.")

        // A reply without the saved settings is followed by a fresh read.
        await harness.transport.setRead("agentSettings", .object(["settings": .object(["name": .object(["value": .string("Renamed")])])]))
        await harness.transport.enqueue(.completed(.object(["ok": .bool(true)])))
        var rename = CompanionSettingsChange(); rename.name = "Renamed"
        let saved = try await service.updateSettings(rename, target: target, clientCommandID: "u2")
        #expect(saved.name.value == "Renamed")
        #expect(await harness.transport.readRoutes.filter { $0.name == "agentSettings" }.count == 4)
    }

    // MARK: Changes

    @Test func changesAndDiffReadFailuresSayWhatWentWrong() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let service = harness.service, project = harness.project
        let file = CompanionChangedFile(path: "a.txt", originalPath: nil, code: "M", staged: false)

        await harness.transport.failRead("gitStatus", .rejected(status: 404, code: nil))
        #expect(await serviceErrorText { _ = try await service.changes(for: project) } == "The desktop no longer has this project.")
        await harness.transport.failRead("gitStatus", .rejected(status: 500, code: "git_failed"))
        #expect(await serviceErrorText { _ = try await service.changes(for: project) } == "The desktop couldn't read this project's changes.")
        await harness.transport.failRead("gitStatus", .unauthorized)
        #expect(await serviceErrorText { _ = try await service.changes(for: project) } == "Pair this desktop again to restore access.")
        await harness.transport.setRead("gitStatus", .object(["branch": .string("main")]))
        #expect(await serviceErrorText { _ = try await service.changes(for: project) } == "The desktop sent changes this phone can't read.")

        await harness.transport.failRead("gitDiff", .responseTooLarge)
        #expect(await serviceErrorText { _ = try await service.diff(of: file, in: project) } == "This file is too large to show on your phone.")
        await harness.transport.setRead("gitDiff", .object(["original": .string("a\n")]))
        #expect(await serviceErrorText { _ = try await service.diff(of: file, in: project) } == "The desktop sent a diff this phone can't read.")
        await harness.transport.setRead("gitDiff", .object(["original": .string("a\n"), "modified": .string("a\nb\n")]))
        let diff = try await service.diff(of: file, in: project)
        #expect(diff.added == 1 && diff.removed == 0 && !diff.isDeleted)
    }

    // MARK: Terminals

    @Test func terminalsOpenOnlyWhereTheDesktopOffersThem() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let shell = CompanionTerminalScope.project(harness.project)
        #expect(throws: CompanionServiceError.self) { _ = try harness.service.terminal(shell) }

        await harness.transport.setCapability("terminal", .object(["version": .integer(1), "projectShell": .bool(true),
                                                                     "agentShell": .bool(false), "agentAttach": .bool(false)]))
        try await harness.refreshCatalog()
        let channel = try harness.service.terminal(shell)
        #expect(channel is CompanionLiveTerminalChannel)
        do {
            _ = try harness.service.terminal(.agentPTY(harness.target))
            Issue.record("An agent terminal the desktop doesn't offer opened")
        } catch let error as CompanionServiceError {
            #expect(error.errorDescription == CompanionTerminalAvailability.updateDesktop)
        }
    }
}
