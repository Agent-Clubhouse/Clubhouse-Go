import Foundation
import Testing
@testable import CompanionDomain

@MainActor private final class TestCompanionService: CompanionService {
    enum SendResult { case accepted, rejected, uncertain }
    var sendResult: SendResult = .accepted
    var sent: [CompanionSendRequest] = []
    var responses: [String] = []
    var cancelled: [CompanionTarget] = []
    var spawnCount = 0
    var spawnResult: SendResult = .accepted
    var spawned: [CompanionSpawnRequest] = []
    var createdTarget: CompanionTarget?
    var removedMessages: [String] = []
    var removalIsUncertain = false
    var historyValue = CompanionHistory(items: [])
    var historyGate: CheckedContinuation<CompanionHistory, Error>?
    var shouldSuspendHistory = false
    var sendGate: CheckedContinuation<CompanionCommandReceipt, Error>?
    var shouldSuspendSend = false
    var nextHistory: CompanionHistory?
    var responseGate: CheckedContinuation<Void, Error>?
    var shouldSuspendResponse = false
    var slept: [CompanionTarget] = []
    var sleepError: CompanionServiceError?
    var sleepRefreshCount = 0
    var settingsWrites = 0
    func sleepAgent(_ target: CompanionTarget, clientCommandID: String) async throws {
        slept.append(target)
        if let sleepError { throw sleepError }
    }
    func refreshSleepState(_ target: CompanionTarget) async throws { sleepRefreshCount += 1 }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings {
        settingsWrites += 1
        throw CompanionServiceError.rejected("Fixture refuses settings")
    }

    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        if shouldSuspendHistory { return try await withCheckedThrowingContinuation { historyGate = $0 } }
        return historyValue
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        sent.append(request)
        if shouldSuspendSend { return try await withCheckedThrowingContinuation { sendGate = $0 } }
        switch sendResult {
        case .accepted: return .init(clientCommandID: request.clientCommandID)
        case .rejected: throw CompanionServiceError.rejected("Desktop rejected command")
        case .uncertain: throw CompanionServiceError.uncertain("Connection ended before acknowledgement")
        }
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { cancelled.append(target) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        responses.append(approvalID)
        if shouldSuspendResponse { try await withCheckedThrowingContinuation { responseGate = $0 } }
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt {
        spawnCount += 1
        spawned.append(request)
        if spawnResult == .uncertain { throw CompanionServiceError.uncertain("Reply lost") }
        if spawnResult == .rejected { throw CompanionServiceError.rejected("Not started") }
        return .init(clientCommandID: request.clientCommandID, agentTarget: createdTarget)
    }
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt {
        guard let target = createdTarget else { throw CompanionServiceError.rejected("No fixture target") }
        return .init(target: target, isCreating: false)
    }
    func reconnect(hostID: String) async {}
    func removeQueued(_ messageID: String, target: CompanionTarget, clientCommandID: String) async throws -> Bool {
        removedMessages.append(messageID)
        if removalIsUncertain { throw CompanionServiceError.uncertain("Reply lost") }
        return true
    }
}

@Suite @MainActor struct CompanionStoreTests {
    private let target = CompanionTarget(hostID: "host-a", projectID: "project", agentID: "agent")

    @Test func sleepAcknowledgmentAndChatEndDoNotUnlockUntilDesktopConfirmsSleep() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var desktop = host(id: target.hostID)
        desktop.canStopAgents = true; desktop.canEditSettings = true
        desktop.projects[0].agents[0].isSleepingOnDesktop = false
        store.apply(.hosts([desktop]))
        store.drafts[target] = "Keep this draft"
        #expect(store.canSleep(target))
        await store.sleepAgent(target)
        #expect(service.slept == [target] && service.sleepRefreshCount == 1)
        #expect(store.sleepRequests.contains(target) && !store.canOperate(target))
        await store.sleepAgent(target)
        #expect(service.slept.count == 1)
        do { _ = try await store.updateSettings(.init(orchestrator: "codex-cli"), target: target); Issue.record("Provider save must wait") }
        catch {}
        #expect(service.settingsWrites == 0)
        desktop.projects[0].agents[0].status = .stopped
        desktop.projects[0].agents[0].capabilities = [.chat, .wake]
        store.apply(.hosts([desktop]))
        #expect(store.sleepRequests.contains(target), "A stopped chat is not a stopped agent")
        #expect(!store.canWake(target) && !store.mayWake(target) && !store.canSend(target))
        desktop.projects[0].agents[0].isSleepingOnDesktop = true
        desktop.connection = .reconnecting
        store.apply(.hosts([desktop]))
        #expect(store.sleepRequests.contains(target), "Disconnected cached state cannot confirm sleep")
        desktop.connection = .connected
        store.apply(.hosts([desktop]))
        #expect(!store.sleepRequests.contains(target) && store.canWake(target))
        #expect(store.drafts[target] == "Keep this draft" && service.sent.isEmpty)
    }

    @Test(arguments: [false, true]) func sleepRefusalUnlocksButUnknownDeliveryStaysPending(uncertain: Bool) async {
        let service = TestCompanionService()
        service.sleepError = uncertain ? .uncertain("Reply lost") : .rejected("Sleep refused")
        let store = makeStore(service: service)
        var desktop = host(id: target.hostID)
        desktop.canStopAgents = true
        desktop.projects[0].agents[0].isSleepingOnDesktop = false
        store.apply(.hosts([desktop]))
        await store.sleepAgent(target)
        #expect(store.sleepRequests.contains(target) == uncertain)
        #expect(store.operationErrors[target] == (uncertain ? "Reply lost" : "Sleep refused"))
        #expect(!store.pendingCommands.contains(target))
    }

    @Test func sleepRequiresAdvertisedCommandAndKnownDurableLifecycle() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        #expect(!store.canSleep(target))
        var desktop = host(id: target.hostID)
        desktop.canStopAgents = true
        store.apply(.hosts([desktop]))
        #expect(!store.canSleep(target), "Unknown lifecycle is not permission to stop")
        desktop.projects[0].agents[0].isSleepingOnDesktop = false
        desktop.projects[0].agents[0].isQuick = true
        store.apply(.hosts([desktop]))
        #expect(!store.canSleep(target))
        await store.sleepAgent(target)
        #expect(service.slept.isEmpty)
    }

    private func makeStore(service: TestCompanionService) -> CompanionStore {
        let store = CompanionStore(service: service)
        store.apply(.hosts([host(id: "host-a"), host(id: "host-b")]))
        return store
    }
    private func host(id: String) -> CompanionHost {
        .init(id: id, name: id, endpoint: "desktop.local", connection: .connected,
              projects: [.init(id: "project", name: "Project", agents: [
                .init(id: .init(hostID: id, projectID: "project", agentID: "agent"), name: "Agent", subtitle: "Task", status: .working, capabilities: [.chat, .steer, .cancel, .approve])
              ])])
    }

    @Test(arguments: [false, true]) func historyReplacementFreezesGeometryWithoutReplacingTheBookmark(followsLatest: Bool) async {
        let service = TestCompanionService()
        let loading = CompanionStore(service: service)
        loading.apply(.hosts([host(id: "host-a")]))
        for id in 0..<5 {
            loading.apply(.upsert(target, .message(.init(id: "live-\(id)", role: .assistant, text: "Live update")), sequence: nil))
        }
        let partial = loading.conversation(for: target)
        #expect(partial.items.count == 5)
        let bookmark = loading.readingBookmark(for: target), viewport = bookmark.viewport
        let saved = CompanionReadingPosition(followsLatest: followsLatest, entryID: "message:history-100", distanceFromEntry: 8, offset: 400, shownEntries: 300)
        bookmark.position = saved
        viewport.hasInitialized = true
        viewport.historyRevision = partial.historyRevision
        #expect(!viewport.acceptsGeometry(historyRevision: partial.historyRevision, isLoaded: partial.isLoaded))
        service.historyValue = .init(items: (0..<182).map { .message(.init(id: "history-\($0)", role: .assistant, text: "History")) })
        await loading.load(target)
        let full = loading.conversation(for: target)
        #expect(full.items.count == 182 && full.isLoaded)
        #expect(full.historyRevision != partial.historyRevision)
        // Exact CI sample: unchanged estimated height/insets, offset 1009.333 -> 0.
        let old = CompanionScrollMetrics(offset: 1009.333, contentHeight: 1678.333, containerHeight: 669)
        var reset = old; reset.offset = 0
        #expect(reset.didScrollUp(from: old), "Geometry alone mistakes history's reset for a native tap")
        #expect(!viewport.acceptsGeometry(historyRevision: full.historyRevision, isLoaded: full.isLoaded))
        #expect(bookmark.position == saved, "Following and actual reading positions survive the replacement boundary")
        viewport.historyRevision = full.historyRevision
        #expect(viewport.acceptsGeometry(historyRevision: full.historyRevision, isLoaded: true))
        loading.apply(.upsert(target, .message(.init(id: "chunk", role: .assistant, text: "Chunk")), sequence: nil))
        #expect(loading.conversation(for: target).historyRevision == full.historyRevision, "Streaming must not remount history")
        await loading.load(target, force: true)
        let refreshed = loading.conversation(for: target)
        #expect(refreshed.historyRevision != full.historyRevision)
        #expect(!viewport.acceptsGeometry(historyRevision: refreshed.historyRevision, isLoaded: true))
        #expect(bookmark.position == saved)
        loading.apply(.timeline(target, items: refreshed.items, sequence: 200, reset: true))
        #expect(loading.conversation(for: target).historyRevision != refreshed.historyRevision, "Full replay snapshots have the same boundary")
    }

    @Test(arguments: [false, true]) func staleCatalogDoesNotClearNewlyOpenedUnlistedChat(isQuick: Bool) async {
        let service = TestCompanionService()
        let store = CompanionStore(service: service)
        var stale = host(id: "host-a")
        stale.hasLoadedCatalog = true; stale.canSpawn = true; stale.canCreateDurable = true
        store.apply(.hosts([stale]))
        let new = CompanionTarget(hostID: "host-a", projectID: "project", agentID: "new-agent")
        service.createdTarget = new
        service.historyValue = .init(items: [.message(.init(id: "history", role: .assistant, text: "Keep this chat"))])
        if isQuick {
            #expect(await store.spawn(project: .init(hostID: new.hostID, projectID: new.projectID), prompt: "Task", provider: nil, model: nil))
        } else {
            #expect(await store.create(.init(project: .init(hostID: new.hostID, projectID: new.projectID), name: "New", color: "teal", orchestrator: nil, model: nil, persona: nil, useWorktree: nil, mcpIDs: nil, clientCommandID: "create")))
        }
        #expect(store.selection == new)
        await store.load(new)
        store.apply(.hosts([stale])) // The read started before the create/spawn receipt.
        #expect(store.conversation(for: new).isLoaded)
        #expect(store.conversation(for: new).items.count == 1)
        store.apply(.hosts([]))
        #expect(!store.conversation(for: new).isLoaded, "Forgetting a host clears even a never-listed chat")
    }

    @Test(arguments: [false, true]) func staleCatalogKeepsNewAgentChatAndInFlightCommand(isQuick: Bool) async {
        let service = TestCompanionService()
        let store = CompanionStore(service: service)
        var stale = host(id: "host-a"); stale.hasLoadedCatalog = true; stale.canSpawn = true; stale.canCreateDurable = true
        store.apply(.hosts([stale]))
        let new = CompanionTarget(hostID: "host-a", projectID: "project", agentID: "new-agent")
        service.createdTarget = new
        if isQuick {
            #expect(await store.spawn(project: .init(hostID: new.hostID, projectID: new.projectID), prompt: "Task", provider: nil, model: nil))
        } else {
            #expect(await store.create(.init(project: .init(hostID: new.hostID, projectID: new.projectID), name: "New", color: "teal", orchestrator: nil, model: nil, persona: nil, useWorktree: nil, mcpIDs: nil, clientCommandID: "create")))
        }
        var fresh = stale
        fresh.projects[0].agents.append(.init(id: new, name: "New", subtitle: "Task", status: .idle, capabilities: [.chat], isQuick: isQuick))
        store.apply(.hosts([fresh])) // Creation is listed before an older catalog read finishes.
        await store.load(new)
        service.shouldSuspendSend = true
        store.drafts[new] = "Follow up"
        let send = Task { await store.sendDraft(to: new) }
        while service.sendGate == nil { await Task.yield() }
        #expect(store.pendingCommands.contains(new))
        store.apply(.hosts([stale]))
        #expect(store.conversation(for: new).isLoaded)
        #expect(store.pendingCommands.contains(new))
        #expect(!store.conversation(for: new).items.isEmpty)
        service.sendGate?.resume(returning: .init(clientCommandID: service.sent[0].clientCommandID))
        await send.value
        #expect(store.conversation(for: new).isLoaded)
    }

    @Test func confirmedListedDurableRemovalStillClearsChat() async {
        let service = TestCompanionService()
        let store = CompanionStore(service: service)
        var listed = host(id: "host-a"); listed.hasLoadedCatalog = true
        store.apply(.hosts([listed]))
        await store.load(target)
        listed.projects[0].agents = []
        store.apply(.hosts([listed]))
        #expect(!store.conversation(for: target).isLoaded)
    }

    @Test func quickAgentCatalogExpiryKeepsItsLoadedChat() async {
        let service = TestCompanionService()
        let store = CompanionStore(service: service)
        var listed = host(id: "host-a"); listed.hasLoadedCatalog = true
        listed.projects[0].agents[0].isQuick = true
        listed.projects[0].agents[0].hasExited = true
        listed.projects[0].agents[0].status = .completed
        store.apply(.hosts([listed]))
        service.historyValue = .init(items: [.message(.init(id: "result", role: .assistant, text: "Finished result"))])
        await store.load(target)
        var expired = listed; expired.projects[0].agents = []
        store.apply(.hosts([expired])) // Desktop's quick-agent catalog retention has elapsed.
        #expect(store.agent(for: target) == nil)
        #expect(store.conversation(for: target).isLoaded)
        #expect(store.conversation(for: target).items.count == 1)
        store.apply(.hosts([]))
        #expect(!store.conversation(for: target).isLoaded, "Forgetting the host still clears even expired quick chat")
    }

    @Test func hostIdentityAndDraftsStayIsolated() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let other = CompanionTarget(hostID: "host-b", projectID: "project", agentID: "agent")
        store.drafts[target] = "Send to A"
        store.drafts[other] = "Keep B"
        await store.sendDraft(to: target)
        #expect(service.sent.count == 1)
        #expect(service.sent[0].target == target)
        #expect(service.sent[0].isSteering)
        #expect(store.drafts[other] == "Keep B")
        #expect(store.conversation(for: other).items.isEmpty)
    }

    @Test func replayDoesNotAppendTextTwice() {
        let store = makeStore(service: TestCompanionService())
        store.apply(.textDelta(target, messageID: "reply", text: "Hello", sequence: 20))
        store.apply(.textDelta(target, messageID: "reply", text: "Hello", sequence: 20))
        store.apply(.textDelta(target, messageID: "reply", text: " world", sequence: 22))
        store.apply(.streamFinished(target, messageID: "reply", sequence: 23))
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        #expect(message.text == "Hello world")
        #expect(!message.isStreaming)
    }

    @Test func disconnectAndResyncDisableCommandsWithoutLosingDraft() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        store.drafts[target] = "Do this later"
        store.apply(.textDelta(target, messageID: "reply", text: "Partial", sequence: 2))
        store.apply(.resyncRequired(hostID: target.hostID))
        #expect(!store.canSend(target))
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
        #expect(store.drafts[target] == "Do this later")
        service.historyValue = .init(items: [.message(.init(id: "reply", role: .assistant, text: "Complete"))], lastSequence: 4)
        await store.load(target, force: true)
        #expect(store.canSend(target))
        var disconnected = host(id: "host-a")
        disconnected.connection = .offline
        store.apply(.hosts([disconnected]))
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
    }

    @Test func uncertainDeliveryCannotBeRetriedAsDefiniteFailure() async {
        let service = TestCompanionService()
        service.sendResult = .uncertain
        let store = makeStore(service: service)
        store.drafts[target] = "Potentially expensive action"
        await store.sendDraft(to: target)
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        guard case .uncertain = message.delivery else { Issue.record("Expected uncertain delivery"); return }
        await store.retry(messageID: message.id, target: target)
        #expect(service.sent.count == 1)
    }

    @Test func definitiveRejectionRetryUsesNewCommandAndEchoReconcilesLocalMessage() async {
        let service = TestCompanionService()
        service.sendResult = .rejected
        let store = makeStore(service: service)
        store.drafts[target] = "Hello"
        await store.sendDraft(to: target)
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        service.sendResult = .accepted
        await store.retry(messageID: message.id, target: target)
        #expect(service.sent.count == 2)
        #expect(service.sent[0].clientCommandID != service.sent[1].clientCommandID)
        store.apply(.upsert(target, .message(.init(id: "server-id", role: .user, text: "Hello", clientCommandID: service.sent[1].clientCommandID)), sequence: 8))
        #expect(store.conversation(for: target).items.count == 1)
        #expect(store.conversation(for: target).items[0].id == "message:server-id")
    }

    @Test func expiredPermissionCannotBeApproved() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let approval = CompanionApproval(id: "permission", toolName: "Shell", summary: "run command", deadline: Date(timeIntervalSince1970: 1), options: [.init(id: "allow", label: "Allow once", kind: .allowOnce)])
        await store.respond(approval, option: .init(id: "allow", label: "Allow once", kind: .allowOnce), target: target)
        #expect(service.responses.isEmpty)
    }

    @Test func liveEventsAreNotOverwrittenByStaleHistory() async {
        let service = TestCompanionService()
        service.shouldSuspendHistory = true
        let store = makeStore(service: service)
        let task = Task { await store.load(target) }
        while service.historyGate == nil { await Task.yield() }
        store.apply(.textDelta(target, messageID: "live", text: "Newest", sequence: 11))
        service.historyGate?.resume(returning: .init(items: [.message(.init(id: "old", role: .user, text: "Earlier message"))], lastSequence: 10))
        await task.value
        #expect(store.conversation(for: target).items.count == 2)
        #expect(store.conversation(for: target).items.first?.id == "message:old")
        #expect(store.conversation(for: target).lastSequence == 11)
    }

    @Test func lateReceiptDoesNotDowngradeConfirmedMessage() async {
        let service = TestCompanionService()
        service.shouldSuspendSend = true
        let store = makeStore(service: service)
        store.drafts[target] = "Hi"
        let task = Task { await store.sendDraft(to: target) }
        while service.sendGate == nil { await Task.yield() }
        let commandID = service.sent[0].clientCommandID
        store.apply(.upsert(target, .message(.init(id: "confirmed", role: .user, text: "Hi", clientCommandID: commandID)), sequence: 1))
        service.sendGate?.resume(returning: .init(clientCommandID: commandID))
        await task.value
        guard case .message(let message) = store.conversation(for: target).items.first else { Issue.record("Expected message"); return }
        #expect(message.delivery == .confirmed)
    }
    @Test func authoritativeApprovalResolutionWinsLateReceipt() async {
        let service = TestCompanionService()
        service.shouldSuspendResponse = true
        let store = makeStore(service: service)
        let option = CompanionApprovalOption(id: "allow", label: "Allow once", kind: .allowOnce)
        let approval = CompanionApproval(id: "p", toolName: "Command", summary: "Task", options: [option])
        store.apply(.upsert(target, .approval(approval), sequence: 1))
        let task = Task { await store.respond(approval, option: option, target: target) }
        while service.responseGate == nil { await Task.yield() }
        var resolved = approval
        resolved.resolution = .denied
        store.apply(.upsert(target, .approval(resolved), sequence: 2))
        service.responseGate?.resume()
        await task.value
        guard case .approval(let final) = store.conversation(for: target).items[0] else { Issue.record("Expected approval"); return }
        #expect(final.resolution == .denied)
    }

    @Test func unrelatedTimelineDoesNotReopenAcknowledgedApproval() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let option = CompanionApprovalOption(id: "allow", label: "Allow once", kind: .allowOnce)
        let approval = CompanionApproval(id: "p", toolName: "Command", summary: "Task", options: [option])
        store.apply(.upsert(target, .approval(approval), sequence: 1))
        await store.respond(approval, option: option, target: target)
        store.apply(.timeline(target, items: [.approval(approval), .notice(id: "other", text: "Working")], sequence: 2, reset: false))
        guard case .approval(let final) = store.conversation(for: target).items[0] else { Issue.record("Expected approval"); return }
        #expect(final.resolution == .allowed)
    }

    @Test func draftPersistenceRestoresAndClearsSentDraft() async {
        let persistence = TestDraftPersistence()
        persistence.values[target] = "Saved across launch"
        let service = TestCompanionService()
        let store = CompanionStore(service: service, draftPersistence: persistence)
        store.apply(.hosts([host(id: "host-a")]))
        #expect(store.drafts[target] == "Saved across launch")
        store.drafts[target] = "Updated draft"
        #expect(persistence.values[target] == "Updated draft")
        await store.sendDraft(to: target)
        #expect(persistence.values[target] == "")
    }

    @Test func queuedFollowUpWorksWithoutSteeringCapability() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var value = host(id: "host-a")
        value.projects[0].agents[0].capabilities = [.chat, .queue]
        store.apply(.hosts([value]))
        store.drafts[target] = "Next, review the tests"
        #expect(store.canSend(target))
        await store.sendDraft(to: target)
        #expect(service.sent.first?.isSteering == false)
        #expect(service.sent.first?.queueIfBusy == true)
    }

    @Test func spawningRequiresAdvertisedHostCapability() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        let project = CompanionProjectTarget(hostID: "host-a", projectID: "project")
        let unsupported = await store.spawn(project: project, prompt: "Task", provider: nil, model: nil)
        #expect(!unsupported)
        #expect(service.spawnCount == 0)
        var value = host(id: "host-a")
        value.canSpawn = true
        store.apply(.hosts([value]))
        let supported = await store.spawn(project: project, prompt: "Task", provider: nil, model: nil)
        #expect(supported)
        #expect(service.spawnCount == 1)
    }

    @Test func failedRefreshKeepsCommandsBlockedUntilReconciled() async {
        let service = TestCompanionService()
        service.shouldSuspendHistory = true
        let store = makeStore(service: service)
        store.drafts[target] = "Keep this direction"
        let task = Task { await store.load(target, force: true) }
        while service.historyGate == nil { await Task.yield() }
        #expect(!store.canSend(target))
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
        service.historyGate?.resume(throwing: CompanionServiceError.unavailable("Offline"))
        await task.value
        #expect(!store.canSend(target))
        #expect(store.drafts[target] == "Keep this direction")
        service.shouldSuspendHistory = false
        await store.load(target, force: true)
        #expect(store.canSend(target))
    }

    @Test func uncertainSpawnCannotCreateAnotherTaskOnRetry() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var value = host(id: "host-a"); value.canSpawn = true
        store.apply(.hosts([value]))
        let project = CompanionProjectTarget(hostID: "host-a", projectID: "project")
        service.spawnResult = .uncertain
        #expect(await !store.spawn(project: project, prompt: "Original task", provider: "provider", model: "model"))
        #expect(store.uncertainSpawnRequest != nil)
        #expect(await !store.spawn(project: project, prompt: "Duplicate", provider: nil, model: nil))
        #expect(service.spawnCount == 1)
        service.spawnResult = .accepted
        #expect(await store.checkSpawnOutcome())
        #expect(service.spawnCount == 2)
        #expect(service.spawned[0].clientCommandID == service.spawned[1].clientCommandID)
        #expect(service.spawned[1].prompt == "Original task")
        #expect(service.spawned[1].model == "model")
        #expect(store.uncertainSpawnRequest == nil)
    }

    @Test func acknowledgedQueueRemovalCannotBeReopenedByUnrelatedTimeline() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        var value = host(id: "host-a"); value.projects[0].agents[0].capabilities.insert(.removeQueued)
        store.apply(.hosts([value]))
        let queued = CompanionTimelineItem.message(.init(id: "m", role: .user, text: "Next task", queueState: .queued))
        store.apply(.timeline(target, items: [queued], sequence: 1, reset: true))
        await store.removeQueuedMessage("m", target: target)
        store.apply(.timeline(target, items: [queued, .notice(id: "other", text: "Activity")], sequence: 2, reset: false))
        await store.removeQueuedMessage("m", target: target)
        #expect(service.removedMessages == ["m"])
        guard case .message(let message) = store.conversation(for: target).items[0] else { Issue.record("Expected message"); return }
        #expect(message.queueState == .removed)
    }

    @Test func uncertainQueueRemovalRequiresReconciliation() async {
        let service = TestCompanionService(); service.removalIsUncertain = true
        let store = makeStore(service: service)
        var value = host(id: "host-a"); value.projects[0].agents[0].capabilities.insert(.removeQueued)
        store.apply(.hosts([value]))
        store.apply(.timeline(target, items: [.message(.init(id: "m", role: .user, text: "Task", queueState: .queued))], sequence: 1, reset: true))
        await store.removeQueuedMessage("m", target: target)
        await store.removeQueuedMessage("m", target: target)
        #expect(service.removedMessages == ["m"])
        #expect(store.conversation(for: target).requiresResync)
    }

    @Test func restartedSessionHistoryReplacesOlderHighSequence() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        store.apply(.timeline(target, items: [.notice(id: "old", text: "Previous session")], sequence: 100,
                              reset: true, sessionID: "old-session"))
        store.apply(.resyncRequired(hostID: target.hostID))
        service.historyValue = .init(items: [.notice(id: "new", text: "Restarted session")],
                                     lastSequence: 2, sessionID: "new-session")
        await store.load(target, force: true)
        #expect(store.conversation(for: target).items.map(\.id) == ["notice:new"])
        #expect(store.conversation(for: target).sessionID == "new-session")
        #expect(!store.conversation(for: target).requiresResync)
    }

    @Test func successfulHistoryWithNewerLiveEventsClearsResync() async {
        let service = TestCompanionService()
        let store = makeStore(service: service)
        store.apply(.timeline(target, items: [.notice(id: "live", text: "Live update")], sequence: 12,
                              reset: true, sessionID: "session"))
        store.apply(.resyncRequired(hostID: target.hostID))
        service.historyValue = .init(items: [.notice(id: "past", text: "Earlier update")],
                                     lastSequence: 10, sessionID: "session")
        await store.load(target, force: true)
        #expect(store.conversation(for: target).items.count == 2)
        #expect(!store.conversation(for: target).requiresResync)
        #expect(store.canOperate(target))
    }

}

@MainActor private final class TestDraftPersistence: CompanionDraftPersistence {
    var values: [CompanionTarget: String] = [:]
    func load() -> [CompanionTarget: String] { values }
    func save(_ drafts: [CompanionTarget: String]) { values = drafts }
}
