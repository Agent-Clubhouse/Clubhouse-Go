import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@MainActor private final class HelperService: CompanionService {
    var answers: [(id: String, approve: Bool, force: Bool)] = []
    var failure: Error?
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func answerHelperRequest(_ request: CompanionHelperRequest, approve: Bool, force: Bool, clientCommandID: String) async throws {
        if let failure { throw failure }
        answers.append((request.id, approve, force))
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func agent(_ id: String, _ status: CompanionAgentStatus = .idle) -> CompanionAgent {
    .init(id: .init(hostID: "mac", projectID: "p1", agentID: id), name: id.capitalized, subtitle: "", status: status)
}

private func start(_ id: String = "hstart_1", at seconds: TimeInterval = 300, expires: TimeInterval = 3600) -> CompanionHelperRequest {
    .init(id: id, hostID: "mac", projectID: "p1", kind: .start, requesterID: "planner", requesterName: "Planner", helperName: "impl-ipc",
          requestedAt: now.addingTimeInterval(-seconds), expiresAt: now.addingTimeInterval(expires),
          summary: "Wants to start the helper impl-ipc", task: "Wire the IPC")
}

private func dispose(_ id: String = "hdispose_1", at seconds: TimeInterval = 60, _ facts: CompanionHelperRequest.Dispose = .init()) -> CompanionHelperRequest {
    .init(id: id, hostID: "mac", projectID: "p1", kind: .dispose, requesterID: "planner", requesterName: "Planner", helperID: "docs", helperName: "Docs",
          requestedAt: now.addingTimeInterval(-seconds), summary: "Planner asked to dispose this helper. Nothing would be lost.", dispose: facts)
}

@MainActor private func makeStore(_ requests: [CompanionHelperRequest], capable: Bool = true, connection: CompanionConnection = .connected,
                              agents: [CompanionAgent] = [agent("planner"), agent("docs")]) -> (CompanionStore, HelperService) {
    let service = HelperService()
    let store = CompanionStore(service: service)
    var host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: connection, projects: [.init(id: "p1", name: "P1", agents: agents)])
    host.canAnswerHelperRequests = capable
    host.helperRequests = requests
    store.apply(.hosts([host]))
    return (store, service)
}

@MainActor struct CompanionHelperRequestTests {
    @Test func decodesTheDesktopSnapshot() {
        let raw: AnnexJSON = .array([
            .object(["requestId": .string("hstart_1"), "kind": .string("start"), "projectId": .string("p1"),
                     "requester": .object(["agentId": .string("planner"), "name": .string("Planner")]),
                     "helper": .object(["agentId": .null, "name": .string("impl-ipc")]),
                     "requestedAt": .string("2026-10-26T09:00:00.000Z"), "expiresAt": .string("2026-10-27T09:00:00.000Z"),
                     "summary": .string("Wants to start the helper impl-ipc"),
                     "start": .object(["task": .string("Wire the IPC"), "persona": .null, "model": .string("opus")])]),
            .object(["requestId": .string("hdispose_1"), "kind": .string("dispose"), "projectId": .string("p1"),
                     "requester": .object(["agentId": .string("planner"), "name": .string("Planner")]),
                     "helper": .object(["agentId": .string("docs"), "name": .string("Docs")]),
                     "requestedAt": .string("2026-10-26T10:00:00.000Z"), "expiresAt": .null,
                     "summary": .string("Planner asked to dispose this helper (forced). 2 uncommitted files."),
                     "dispose": .object(["uncommittedFiles": .integer(2), "unpushedCommits": .integer(0), "unmergedCommits": .null,
                                         "checkError": .null, "forceRequested": .bool(true), "workAtRisk": .bool(true), "canDispose": .bool(true)])]),
            // A dispose without facts can only be declined; malformed entries are skipped.
            .object(["requestId": .string("hdispose_2"), "kind": .string("dispose"), "projectId": .string("p1"),
                     "requester": .object(["agentId": .string("planner")]), "helper": .object(["agentId": .string("old")])]),
            .object(["requestId": .string("x"), "kind": .string("rename"), "projectId": .string("p1"), "requester": .object(["agentId": .string("planner")])]),
            .object(["requestId": .string("y"), "kind": .string("dispose"), "projectId": .string("p1"), "requester": .object(["agentId": .string("planner")])]),
        ])
        let requests = CompanionLiveService.helperRequests(from: raw, hostID: "mac")
        #expect(requests.map(\.id) == ["hstart_1", "hdispose_1", "hdispose_2"])
        let start = requests[0]
        #expect(start.kind == .start && start.helperID == nil && start.task == "Wire the IPC" && start.agentTarget.agentID == "planner")
        #expect(start.expiresAt == (try? Date("2026-10-27T09:00:00.000Z", strategy: .iso8601)))
        let dispose = requests[1]
        #expect(dispose.agentTarget.agentID == "docs")
        #expect(dispose.dispose == .init(uncommittedFiles: 2, unpushedCommits: 0, unmergedCommits: nil, checkError: nil, forceRequested: true, workAtRisk: true, canDispose: true))
        #expect(dispose.approveLabel == "Dispose anyway")
        #expect(requests[2].canApprove == false)
        #expect(requests[2].requesterName == "An orchestrator")
    }

    @Test func showsInNeedsYouOnTheDesktopsRowsOldestFirst() {
        var working = agent("planner", .approval)
        working.detail = .init(state: "needs_permission", since: now.addingTimeInterval(-120))
        let (store, _) = makeStore([dispose(at: 60), start(at: 300)], agents: [working, agent("docs")])
        let items = store.attentionItems(now: now)
        #expect(items.map(\.detail) == ["Wants to start the helper impl-ipc", "Needs permission", "Planner asked to dispose this helper. Nothing would be lost."])
        // A start is on the orchestrator's row, a dispose on the helper's.
        #expect(items.map(\.agent.name) == ["Planner", "Planner", "Docs"])
        #expect(items[0].prompt == "Wire the IPC")
        #expect(Set(items.map(\.id)).count == 3, "An agent's own wait and its helper request are separate entries")
        #expect(store.needsYouCount == 3)
    }

    @Test func hiddenWithoutTheCapabilityOfflineExpiredOrUnlisted() {
        #expect(makeStore([start()], capable: false).0.attentionItems(now: now).isEmpty)
        #expect(makeStore([start()], capable: false).0.needsYouCount == 0)
        #expect(makeStore([start()], connection: .offline).0.attentionItems(now: now).isEmpty)
        #expect(makeStore([start(expires: -1)]).0.attentionItems(now: now).isEmpty)
        #expect(makeStore([dispose()], agents: [agent("planner")]).0.attentionItems(now: now).isEmpty)
    }

    @Test func approvingFollowsTheDesktopRules() async {
        let atRisk = dispose("hdispose_1", .init(uncommittedFiles: 2, workAtRisk: true))
        let unchecked = dispose("hdispose_2", .init(checkError: "git failed", canDispose: false))
        let (store, service) = makeStore([start(), atRisk])
        await store.answer(start(), approve: true)
        await store.answer(atRisk, approve: true)
        #expect(service.answers.map { "\($0.id):\($0.approve):\($0.force)" } == ["hstart_1:true:false", "hdispose_1:true:true"])
        #expect(store.hosts[0].helperRequests.isEmpty, "Answered requests can't be answered again")
        // A clean dispose isn't forced; one that couldn't be checked can only be declined.
        let (other, otherService) = makeStore([dispose(), unchecked])
        await other.answer(unchecked, approve: true)
        await other.answer(dispose(), approve: true)
        await other.answer(unchecked, approve: false)
        #expect(otherService.answers.map { "\($0.id):\($0.approve):\($0.force)" } == ["hdispose_1:true:false", "hdispose_2:false:false"])
    }

    @Test func refusalKeepsTheRequestAndSaysWhy() async {
        let (store, service) = makeStore([start()])
        service.failure = CompanionServiceError.rejected("Wake Planner to approve this start. It isn't running, so the request is still waiting.")
        await store.answer(start(), approve: true)
        #expect(store.helperRequestErrors[start().slot] == "Wake Planner to approve this start. It isn't running, so the request is still waiting.")
        #expect(store.hosts[0].helperRequests.count == 1)
        #expect(store.helperRequestsInFlight.isEmpty)
        // A dispose reissued with new checks keeps its slot, so the reason stays with it.
        #expect(dispose("hdispose_1").slot == dispose("hdispose_9").slot)
    }

    @Test func notAnswerableWhenDisconnectedOrUnsupported() async {
        let (offline, offlineService) = makeStore([start()], connection: .offline)
        await offline.answer(start(), approve: true)
        let (old, oldService) = makeStore([start()], capable: false)
        await old.answer(start(), approve: false)
        #expect(offlineService.answers.isEmpty && oldService.answers.isEmpty)
        #expect(!offline.canAnswer(start()))
    }

    @Test func encodesTheCommands() throws {
        func fields(_ kind: AnnexCommand.Kind) throws -> AnnexJSON {
            try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "c", epoch: "e", kind: kind).encoded())
        }
        let approve = try fields(.helperApprove(requestID: "hdispose_1", force: true))
        #expect(approve["type"]?.string == "helper.approve" && approve["requestId"]?.string == "hdispose_1" && approve["force"] == .bool(true))
        #expect(try fields(.helperApprove(requestID: "hstart_1"))["force"] == nil)
        let decline = try fields(.helperDecline(requestID: "hstart_1"))
        #expect(decline["type"]?.string == "helper.decline" && decline["force"] == nil)
        #expect(CompanionAgentCommandError.message(code: "helper_request_not_found", message: nil)?.contains("Check Needs you again") == true)
    }
}
