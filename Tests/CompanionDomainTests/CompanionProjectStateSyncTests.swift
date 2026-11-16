import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

// Pins, inactive marks and idle projects shared by the desktop (#160, desktop Agent-Clubhouse/Clubhouse#2461).

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor private final class ProjectStateService: CompanionService {
    var sent: [String] = []
    var failure: CompanionServiceError?
    var targets: [CompanionProjectTarget] = []
    var confirmation: CompanionProjectState?
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
        targets.append(project)
        return try await reply("pinned:\(project.projectID):\(pinned)", .init(pinned: pinned))
    }
    func setProject(_ project: CompanionProjectTarget, inactive: Bool, clientCommandID: String) async throws -> CompanionProjectState {
        targets.append(project)
        return try await reply("inactive:\(project.projectID):\(inactive)", .init(inactive: inactive, idle: inactive, lastActivity: inactive ? nil : now))
    }
    private func reply(_ command: String, _ state: CompanionProjectState) async throws -> CompanionProjectState {
        sent.append(command)
        if holds { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        return confirmation ?? state
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

@MainActor struct CompanionLinkedProjectStateTests {
    private func hosts(firstConnection: CompanionConnection = .connected, secondConnection: CompanionConnection = .connected,
                       shared: Bool = true, state: CompanionProjectState = .init(linked: true)) -> [CompanionHost] {
        let references: [AnnexProjectLinks.Reference] = ["first", "second"].map { .init(machine: $0, projectId: "copy") }
        return [firstConnection, secondConnection].enumerated().map { index, connection in
            var h = CompanionHost(id: index == 0 ? "first" : "second", name: index == 0 ? "Studio" : "Laptop",
                                  endpoint: "", connection: connection, projects: [.init(id: "copy", name: "Project", agents: [])])
            h.canLinkProjects = true
            h.projectLinks = .init(projectLinks: [.init(id: "linked-identity", projects: references)])
            h.canSyncProjectState = true
            h.canSyncLinkedProjectState = shared
            h.projectState = ["copy": state]
            return h
        }
    }
    private func store(_ hosts: [CompanionHost], service: ProjectStateService = .init()) -> CompanionStore {
        let store = CompanionStore(service: service); store.apply(.hosts(hosts)); return store
    }
    private func layout(_ store: CompanionStore, rule: CompanionIdleRule = .init()) -> CompanionHomeLayout {
        .build(store.projectEntries, sort: .custom, customOrder: [], rule: rule,
               shared: { store.sharedProjectState($0.id) }, projectActivity: { _ in nil }, agentActivity: { _ in nil })
    }

    @Test func capableGroupUsesOneReplicaInsteadOfUnioningStalePinsAndNeverUsesLocalPrefs() throws {
        var h = hosts()
        h[1].projectState?["copy"] = .init(pinned: true, linked: true)
        let store = store(h)
        let keys = Set(h.map { CompanionProjectOrdering.key(.init(hostID: $0.id, projectID: "copy")) })
        let result = layout(store, rule: .init(pinned: keys, inactive: keys))
        #expect(result.projects.count == 1 && !result.projects[0].isPinned && !result.projects[0].isIdle)
        #expect(store.sharedProjectState(.init(hostID: "second", projectID: "copy"))?.pinned == false)
        // Desktop resolves explicit clocks and legacy ANY-pinned/ALL-inactive. The phone must not
        // undo that decision by unioning another replica or applying remembered renderer preferences.
    }

    @Test func oldHostsKeepPerCopyValuesAndLocalFallback() {
        var h = hosts(shared: false)
        h[1].projectState?["copy"] = .init(pinned: true)
        #expect(layout(store(h)).projects.first?.isPinned == true)
        for i in h.indices { h[i].projectState = nil }
        let local = CompanionIdleRule(pinned: [CompanionProjectOrdering.key(.init(hostID: "second", projectID: "copy"))])
        #expect(layout(store(h), rule: local).projects.first?.isPinned == true)
    }

    @Test func pinSendsOnceToConnectedCapableCopyAndShowsOptimisticGroupState() async throws {
        let service = ProjectStateService(); service.holds = true
        service.confirmation = .init(pinned: true, lastActivity: now, linked: true)
        let store = store(hosts(firstConnection: .offline), service: service)
        let entry = try #require(store.projectEntries.first)
        let task = Task { await store.setLinkedProject(entry, pinned: true) }
        while service.gate == nil { await Task.yield() }
        #expect(layout(store).projects.first?.isPinned == true)
        #expect(store.canChangeLinkedProjectState(entry) == false, "One local command may be in flight")
        #expect(service.targets == [.init(hostID: "second", projectID: "copy")])
        service.release(); await task.value
        #expect(service.sent == ["pinned:copy:true"] && layout(store).projects.first?.isPinned == true)
        #expect(store.hosts[0].projectState?["copy"]?.pinned == false, "No acknowledgement is invented for the offline copy")
        #expect(store.hosts[0].projectState?["copy"]?.lastActivity == nil, "Raw activity stays per machine")
    }

    @Test func refusalRollsBackTheWholeGroupAndExplains() async throws {
        let service = ProjectStateService(); service.holds = true; service.failure = .rejected("Unpin this project before marking it inactive.")
        let store = store(hosts(), service: service); let entry = try #require(store.projectEntries.first)
        let task = Task { await store.setLinkedProject(entry, inactive: true) }
        while service.gate == nil { await Task.yield() }
        #expect(layout(store).idle.count == 1)
        service.release(); await task.value
        #expect(layout(store).idle.isEmpty && store.linkedProjectState(entry)?.inactive == false)
        #expect(store.projectStateError == "Unpin this project before marking it inactive.")
    }

    @Test func inactiveToActiveIsOneCommandThenEachCopyReportsItsOwnActivity() async throws {
        let service = ProjectStateService(); service.holds = true
        service.confirmation = .init(lastActivity: now, linked: true)
        let store = store(hosts(state: .init(inactive: true, idle: true, linked: true)), service: service)
        let entry = try #require(store.projectEntries.first)
        let task = Task { await store.setLinkedProject(entry, inactive: false) }
        while service.gate == nil { await Task.yield() }
        #expect(layout(store).idle.isEmpty)
        service.release(); await task.value
        #expect(service.sent == ["inactive:copy:false"] && layout(store).idle.isEmpty)
        var reports = store.hosts
        for i in reports.indices { reports[i].projectState?["copy"] = .init(lastActivity: now, linked: true) }
        store.apply(.hosts(reports))
        #expect(store.hosts.allSatisfy { $0.projectState?["copy"]?.lastActivity == now })
    }

    @Test func mixedVersionGroupNeverSendsToTheOnlyConnectedOldHost() async throws {
        let service = ProjectStateService(); var h = hosts(firstConnection: .offline)
        h[1].canSyncLinkedProjectState = false; h[1].projectState?["copy"] = .init()
        let store = store(h, service: service); let entry = try #require(store.projectEntries.first)
        #expect(store.linkedProjectState(entry) != nil && !store.canChangeLinkedProjectState(entry))
        #expect(store.linkedProjectStateConnectionHint(entry) == "Connect Studio for shared changes.")
        await store.setLinkedProject(entry, pinned: true)
        #expect(service.sent.isEmpty && service.targets.isEmpty)
    }

    @Test func fullyOfflineGroupRetainsItsIdentityWithDisabledSharedControls() async throws {
        let service = ProjectStateService(); let store = store(hosts(firstConnection: .offline, secondConnection: .offline), service: service)
        let entry = try #require(store.projectEntries.first)
        #expect(entry.isLinked && !store.canChangeLinkedProjectState(entry))
        await store.setLinkedProject(entry, inactive: true)
        #expect(service.sent.isEmpty)
    }

    @Test func splitKeepsDesktopValuesWithoutRestoringOldLocalPreferences() {
        var h = hosts(state: .init(pinned: true, linked: true)); let store = store(h)
        for i in h.indices { h[i].projectLinks = .init(projectLinks: []); h[i].projectState?["copy"]?.linked = false }
        store.apply(.hosts(h))
        let result = layout(store, rule: .init(inactive: Set(h.map { CompanionProjectOrdering.key(.init(hostID: $0.id, projectID: "copy")) })))
        #expect(result.projects.count == 2 && result.projects.allSatisfy(\.isPinned) && result.idle.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func lateGroupReceiptCannotApplyAcrossLinkIdentityOrEpochChange(changesLink: Bool, fails: Bool) async throws {
        let service = ProjectStateService(); service.holds = true; service.confirmation = .init(pinned: true, linked: true)
        if fails { service.failure = .rejected("Old refusal") }
        let store = store(hosts(), service: service); let entry = try #require(store.projectEntries.first)
        let task = Task { await store.setLinkedProject(entry, pinned: true) }
        while service.gate == nil { await Task.yield() }
        var changed = hosts()
        for i in changed.indices {
            if changesLink { changed[i].projectLinks = .init(projectLinks: []) }
            else { changed[i].controlEpoch = "replacement" }
        }
        store.apply(.hosts(changed)); service.release(); await task.value
        #expect(store.projectEntries.count == (changesLink ? 2 : 1))
        #expect(store.hosts.allSatisfy { $0.projectState?["copy"]?.pinned == false })
        #expect(store.projectStateError == nil, "A stale refusal cannot attach to the replacement group or desktop")
    }

    @Test func linkedPinClearsInactiveWhileOrdinaryIdleAndActivityStayPerCopy() {
        let pinned = CompanionProjectState(inactive: true, idle: true, linked: true).with(pinned: true)
        #expect(pinned.pinned && !pinned.inactive && !pinned.idle)
        let refusedMark = pinned.with(inactive: true)
        #expect(refusedMark.pinned && !refusedMark.inactive && !refusedMark.idle,
                "An optimistic linked mark cannot make a pinned group inactive before the desktop refuses it")
        var h = hosts(); h[0].projectState?["copy"]?.idle = true
        h[0].projectState?["copy"]?.lastActivity = now.addingTimeInterval(-100)
        h[1].projectState?["copy"]?.lastActivity = now
        let store = store(h)
        #expect(layout(store).idle.isEmpty, "A non-idle copy keeps the unmarked group active")
        #expect(store.sharedProjectState(.init(hostID: "first", projectID: "copy"))?.lastActivity == now.addingTimeInterval(-100))
    }
    @Test func singleTargetEntryPointAlsoRoutesThroughTheConnectedGroupMember() async {
        let service = ProjectStateService(); service.confirmation = .init(pinned: true, linked: true)
        let store = store(hosts(firstConnection: .offline), service: service)
        await store.setProject(.init(hostID: "first", projectID: "copy"), pinned: true)
        #expect(service.targets == [.init(hostID: "second", projectID: "copy")])
    }

    @Test(arguments: [false, true])
    func shutdownFencesLateSuccessAndRefusal(fails: Bool) async throws {
        let service = ProjectStateService(); service.holds = true; service.confirmation = .init(pinned: true, linked: true)
        if fails { service.failure = .rejected("Late refusal") }
        let store = store(hosts(), service: service); let entry = try #require(store.projectEntries.first)
        let task = Task { await store.setLinkedProject(entry, pinned: true) }
        while service.gate == nil { await Task.yield() }
        store.shutdown(); service.release(); await task.value
        #expect(!store.canChangeLinkedProjectState(entry) && store.projectStateError == nil)
        #expect(store.hosts.allSatisfy { $0.projectState?["copy"]?.pinned == false })
        let count = service.sent.count
        await store.setLinkedProject(entry, inactive: true)
        #expect(service.sent.count == count)
    }

}


@MainActor struct CompanionLargeCatalogRegressionTests {
    @Test func repeatedMenuReadsShareOnePrebuiltCatalogAndDoNotAllocateNewEntryBuffers() throws {
        let hosts = CompanionLargeCatalogFixture.hosts(hostCount: 16, projectsPerHost: 64, agentsPerProject: 24)
        let store = CompanionStore(service: ProjectStateService())
        store.apply(.hosts(hosts))
        let revision = store.projectCatalogRevision
        let first = store.projectEntries
        #expect(first.count == 16 * 64 - 8)
        let agentCount: Int = first.reduce(0) { count, entry in count + entry.project.agents.count }
        #expect(agentCount == 24_576)
        let target = CompanionProjectTarget(hostID: "synthetic-host-0", projectID: "project-0")
        for _ in 0..<200 {
            let next = store.projectEntries
            first.withUnsafeBufferPointer { a in
                next.withUnsafeBufferPointer { b in #expect(a.baseAddress == b.baseAddress) }
            }
            #expect(store.projectEntry(containing: target)?.linkID == "synthetic-link-0")
        }
        #expect(store.projectCatalogRevision == revision, "Reads never build the catalog inside a menu")
        store.shutdown()
    }

    @Test func hostLinkAndProjectStateMutationsRebuildBeforeTheNextRead() throws {
        let store = CompanionStore(service: ProjectStateService())
        var hosts = CompanionLargeCatalogFixture.hosts()
        store.apply(.hosts(hosts))
        let target = CompanionProjectTarget(hostID: "synthetic-host-0", projectID: "project-0")
        let firstRevision = store.projectCatalogRevision
        hosts[0].projects[0].agents[0].name = "Updated synthetic agent"
        store.apply(.hosts(hosts))
        #expect(store.projectCatalogRevision > firstRevision)
        #expect(store.projectEntry(containing: target)?.members.first?.project.agents.first?.name == "Updated synthetic agent")
        let hostRevision = store.projectCatalogRevision
        for i in hosts.indices { hosts[i].projectLinks = .init(projectLinks: []) }
        store.apply(.hosts(hosts))
        #expect(store.projectCatalogRevision > hostRevision)
        #expect(store.projectEntries.count == 8 * 48)
        #expect(store.projectEntry(containing: target)?.linkID == nil)
        let linkRevision = store.projectCatalogRevision
        store.hosts[0].projectState?["project-0"] = .init(pinned: true)
        #expect(store.projectCatalogRevision > linkRevision)
        #expect(store.projectEntry(containing: target)?.host.projectState?["project-0"]?.pinned == true)
        store.shutdown()
    }

    @Test func capturedGroupUsesCurrentReceiverAndRefusesChangedIdentityOrCapability() async throws {
        let service = ProjectStateService()
        service.confirmation = .init(pinned: true, linked: true)
        let store = CompanionStore(service: service)
        var hosts = CompanionLargeCatalogFixture.hosts()
        store.apply(.hosts(hosts))
        let captured = try #require(store.projectEntries.first)
        hosts[0].connection = .offline
        store.apply(.hosts(hosts))
        let current = try #require(store.resolveProjectActionEntry(containing: captured.id, expectedLinkID: captured.linkID))
        #expect(current.members.first?.host.connection == .offline)
        await store.setLinkedProject(captured, pinned: true)
        #expect(service.targets == [.init(hostID: "synthetic-host-1", projectID: "project-0")])
        hosts[1].canSyncLinkedProjectState = false
        store.apply(.hosts(hosts))
        await store.setLinkedProject(captured, inactive: true)
        #expect(service.targets.count == 1, "A stale enabled menu cannot bypass revoked capability")
        for i in hosts.indices { hosts[i].projectLinks = .init(projectLinks: []) }
        store.apply(.hosts(hosts))
        #expect(store.resolveProjectActionEntry(containing: captured.id, expectedLinkID: captured.linkID) == nil)
        await store.setLinkedProject(captured, pinned: false)
        #expect(service.targets.count == 1, "An old group identity cannot mutate a newly unlinked copy")
        store.shutdown()
    }
}
