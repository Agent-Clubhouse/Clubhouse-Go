import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

// Pins, inactive marks and idle projects shared by the desktop (#160, desktop Agent-Clubhouse/Clubhouse#2461).

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor private final class ProjectStateService: CompanionService {
    var sent: [String] = []
    var failure: CompanionServiceError?
    var gate: CheckedContinuation<Void, Never>?
    var holds = false
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func setProject(_ project: CompanionProjectTarget, pinned: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        try await reply("pinned:\(project.projectID):\(pinned)", .init(pinned: pinned))
    }
    func setProject(_ project: CompanionProjectTarget, inactive: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        try await reply("inactive:\(project.projectID):\(inactive)", .init(inactive: inactive, idle: inactive, lastActivity: inactive ? nil : now))
    }
    private func reply(_ command: String, _ state: CompanionProjectState) async throws -> CompanionProjectState {
        sent.append(command)
        if holds { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        return state
    }
    func release() { gate?.resume(); gate = nil }
}

private func host(sync: Bool = true, state: [String: CompanionProjectState]? = [:], connection: CompanionConnection = .connected) -> CompanionHost {
    var host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: connection,
                             projects: ["a", "b", "c"].map { .init(id: $0, name: $0, agents: []) })
    host.canSyncProjectState = sync
    host.projectState = state
    return host
}

private func target(_ project: String) -> CompanionProjectTarget { .init(hostID: "mac", projectID: project) }

struct CompanionProjectStateDecodingTests {
    @Test func snapshotEntriesDecode() throws {
        let json: AnnexJSON = .object([
            "a": .object(["lastActivityAt": .integer(1_800_000_000_000), "pinned": .bool(true), "inactive": .bool(false), "idle": .bool(false)]),
            "b": .object(["lastActivityAt": .null, "pinned": .bool(false), "inactive": .bool(true), "idle": .bool(true)]),
            "junk": .string("nope")
        ])
        let map = try #require(CompanionProjectState.map(from: json))
        #expect(map["a"] == .init(pinned: true, lastActivity: now))
        #expect(map["b"] == .init(inactive: true, idle: true))
        #expect(map["junk"] == nil)
    }

    @Test func missingProjectStateMeansTheDesktopHasNotMigrated() {
        #expect(CompanionProjectState.map(from: nil) == nil)
        #expect(CompanionProjectState.map(from: .array([])) == nil)
    }

    @MainActor @Test func idleDaysDecode() {
        #expect(CompanionLiveService.idleDays(from: .integer(14)) == 14)
        #expect(CompanionLiveService.idleDays(from: .integer(0)) == 0)
        #expect(CompanionLiveService.idleDays(from: nil) == nil)
        #expect(CompanionLiveService.idleDays(from: .string("7")) == nil)
    }

    @Test func optimisticChangesFollowTheDesktopRules() {
        let pinnedIdle = CompanionProjectState(idle: true).with(pinned: true)
        #expect(pinnedIdle.pinned && !pinnedIdle.idle, "A pinned project is never idle")
        let marked = CompanionProjectState().with(inactive: true)
        #expect(marked.inactive && marked.idle)
        #expect(!CompanionProjectState(pinned: true).with(inactive: true).idle)
        let active = CompanionProjectState(inactive: true, idle: true).with(inactive: false, now: now)
        #expect(!active.inactive && !active.idle && active.lastActivity == now, "Marking active counts as activity")
    }
}

struct CompanionSharedLayoutTests {
    private func layout(shared: [String: CompanionProjectState]?, rule: CompanionIdleRule = .init(),
                        agents: [String: [CompanionAgent]] = [:]) -> CompanionHomeLayout {
        var h = host()
        h.projects = h.projects.map { var p = $0; p.agents = agents[$0.id] ?? []; return p }
        let entries = h.projects.map { CompanionProjectEntry(host: h, project: $0) }
        return CompanionHomeLayout.build(entries, sort: .custom, customOrder: [], rule: rule, now: now,
                                         shared: { shared?[$0.project.id] ?? (shared == nil ? nil : .init()) },
                                         projectActivity: { _ in nil }, agentActivity: { _ in nil })
    }

    @Test func sharedStateReplacesLocalPinsAndIdle() {
        // The phone's own pin and mark on "a" are ignored once the desktop shares its state.
        let local = CompanionIdleRule(pinned: ["mac\u{1F}a"], inactive: ["mac\u{1F}b"])
        let result = layout(shared: ["c": .init(pinned: true), "a": .init(inactive: true, idle: true)], rule: local)
        #expect(result.projects.map(\.entry.project.id) == ["c", "b"])
        #expect(result.projects.map(\.isPinned) == [true, false])
        #expect(result.idle.map(\.entry.project.id) == ["a"])
    }

    @Test func idleIsUsedAsSentNotRecomputed() {
        // No activity for months, but the desktop says it isn't idle, so it isn't.
        let result = layout(shared: ["a": .init(idle: false, lastActivity: now.addingTimeInterval(-90 * 86_400))])
        #expect(result.idle.isEmpty)
    }

    @Test func runningAgentKeepsAProjectInViewWhileAMarkIsOnItsWay() {
        let working = CompanionAgent(id: .init(hostID: "mac", projectID: "a", agentID: "w"), name: "w", subtitle: "", status: .working)
        #expect(layout(shared: ["a": .init(inactive: true, idle: true)], agents: ["a": [working]]).idle.isEmpty)
    }

    @Test func withoutSharedStateTheLocalRuleApplies() {
        let result = layout(shared: nil, rule: .init(pinned: ["mac\u{1F}b"], inactive: ["mac\u{1F}c"]))
        #expect(result.projects.map(\.entry.project.id) == ["b", "a"])
        #expect(result.idle.map(\.entry.project.id) == ["c"])
    }
}

@MainActor struct CompanionProjectStateStoreTests {
    private func store(_ host: CompanionHost, service: ProjectStateService = .init()) -> CompanionStore {
        let store = CompanionStore(service: service)
        store.apply(.hosts([host]))
        return store
    }

    @Test func sharedOnlyWithTheCapabilityAndAfterMigration() {
        #expect(store(host(sync: true, state: ["a": .init(pinned: true)])).sharedProjectState(target("a"))?.pinned == true)
        #expect(store(host(sync: true, state: [:])).sharedProjectState(target("b")) == .init(), "A project the desktop hasn't listed yet is plain")
        #expect(store(host(sync: false, state: ["a": .init(pinned: true)])).sharedProjectState(target("a")) == nil, "No capability: keep local pins")
        #expect(store(host(sync: true, state: nil)).sharedProjectState(target("a")) == nil, "Before migration: keep local pins")
    }

    @Test func pinShowsAtOnceThenTheDesktopConfirms() async throws {
        let service = ProjectStateService()
        service.holds = true
        let store = store(host(), service: service)
        let task = Task { await store.setProject(target("a"), pinned: true) }
        while service.gate == nil { await Task.yield() }
        #expect(store.sharedProjectState(target("a"))?.pinned == true, "Optimistic while the command is on its way")
        service.release()
        await task.value
        #expect(service.sent == ["pinned:a:true"])
        #expect(store.pendingProjectStates.isEmpty)
        #expect(store.hosts[0].projectState?["a"]?.pinned == true, "The confirmed state stays until the next snapshot")
        #expect(store.projectStateError == nil)
    }

    @Test func refusalRollsBackAndExplains() async {
        let service = ProjectStateService()
        service.failure = .rejected(CompanionAgentCommandError.message(code: "project_pinned", message: nil) ?? "")
        let store = store(host(state: ["a": .init(pinned: true)]), service: service)
        await store.setProject(target("a"), inactive: true)
        #expect(service.sent == ["inactive:a:true"])
        #expect(store.sharedProjectState(target("a")) == .init(pinned: true), "The desktop's state returns")
        #expect(store.projectStateError == "Unpin this project before marking it inactive.")
    }

    @Test func markActiveIsSentAsInactiveFalse() async {
        let service = ProjectStateService()
        let store = store(host(state: ["b": .init(inactive: true, idle: true)]), service: service)
        await store.setProject(target("b"), inactive: false)
        #expect(service.sent == ["inactive:b:false"])
        #expect(store.sharedProjectState(target("b")) == .init(lastActivity: now))
    }

    @Test func nothingIsSentWhenTheDesktopKeepsNoSharedState() async {
        let service = ProjectStateService()
        let store = store(host(sync: false), service: service)
        await store.setProject(target("a"), pinned: true)
        #expect(service.sent.isEmpty)
    }

    @Test func offlineDesktopExplainsInsteadOfSending() async {
        let service = ProjectStateService()
        let store = store(host(connection: .reconnecting), service: service)
        await store.setProject(target("a"), pinned: true)
        #expect(service.sent.isEmpty)
        #expect(store.projectStateError == "Reconnect to your desktop to change this project.")
    }

    @Test func liveServiceRefusesWithoutTheCapability() async {
        await #expect(throws: CompanionServiceError.self) {
            _ = try await CompanionLiveService().setProject(target("a"), pinned: true, clientCommandID: "x")
        }
    }

    @Test func desktopCodesReadWell() {
        #expect(CompanionAgentCommandError.message(code: "project_state_unavailable", message: nil) == "Your desktop is still setting up shared pins. Try again in a moment.")
        #expect(CompanionAgentCommandError.message(code: "project_not_found", message: nil) == "This project is no longer on the desktop.")
    }
}
