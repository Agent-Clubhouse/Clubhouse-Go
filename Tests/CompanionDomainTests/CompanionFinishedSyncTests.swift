import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

// "Finished, waiting on you" shared by the desktop (#167, desktop Agent-Clubhouse/Clubhouse#2468).

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let project = CompanionProjectTarget(hostID: "mac", projectID: "p")

/// `from` is the fixed clock for pure rules; store tests pass the real one, since the store reads the time itself.
private func run(_ id: String, minutesAgo: Double, exitCode: Int = 0, summary: String? = nil, status: CompanionAgentStatus = .completed,
                 from clock: Date = now) -> CompanionFinishedRun {
    .init(target: .init(hostID: "mac", projectID: "p", agentID: id), name: id, mission: "Mission \(id)", exitCode: exitCode, status: status,
          completedAt: clock.addingTimeInterval(-minutesAgo * 60), summary: summary)
}
private func exited(_ id: String, minutesAgo: Double, from clock: Date = now) -> CompanionAgent {
    .init(id: .init(hostID: "mac", projectID: "p", agentID: id), name: id, subtitle: "Local \(id)", status: .completed,
          lastActivity: clock.addingTimeInterval(-minutesAgo * 60), isQuick: true, hasExited: true, exitCode: 0)
}
private func host(sync: Bool = true, list: [CompanionFinishedRun]? = [], agents: [CompanionAgent] = [],
                  connection: CompanionConnection = .connected) -> CompanionHost {
    var host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: connection,
                             projects: [.init(id: "p", name: "P", agents: agents)])
    host.canSyncFinishedQuick = sync
    host.finishedQuickAgents = list.map { ["p": $0] }
    return host
}

// MARK: - Decoding

struct CompanionFinishedDecodingTests {
    @Test func snapshotEntriesDecodeInTheDesktopsOrder() throws {
        let json: AnnexJSON = .object([
            "p": .array([
                .object(["agentId": .string("q2"), "name": .string("swift-fox"), "prompt": .string("Fix the flaky test"),
                         "summary": .string("Fixed the **race** in `Clock`."), "exitCode": .integer(0), "finishedAt": .integer(1_800_000_000_000),
                         "parentAgentId": .string("durable_1")]),
                .object(["agentId": .string("q1"), "name": .string("calm-owl"), "prompt": .string("Run the checklist"),
                         "summary": .null, "exitCode": .integer(2), "finishedAt": .integer(1_799_999_000_000)]),
                .object(["agentId": .string("q0"), "name": .string("stopped"), "prompt": .string(""), "summary": .null,
                         "exitCode": .integer(143), "finishedAt": .integer(1_799_998_000_000), "cancelled": .bool(true)]),
                .object(["name": .string("no id")])
            ]),
            "empty": .array([])
        ])
        let lists = try #require(CompanionFinishedRun.desktopLists(json, hostID: "mac"))
        #expect(lists["empty"] == [])
        let runs = try #require(lists["p"])
        #expect(runs.map(\.target.agentID) == ["q2", "q1", "q0"], "Newest first as sent; an entry without an id is skipped")
        #expect(runs.allSatisfy { $0.target.hostID == "mac" && $0.target.projectID == "p" })
        #expect(runs[0].completedAt == now && runs[0].title == "Fix the flaky test")
        #expect(runs[0].detail == "Fixed the race in Clock.", "The summary as plain text")
        #expect(!runs[0].failed)
        #expect(runs[1].detail == "Exited with code 2" && runs[1].failed)
        #expect(runs[2].status == .stopped && runs[2].detail == "Cancelled" && !runs[2].failed, "A cancelled run isn't a failure")
        #expect(runs[2].title == "stopped", "No prompt shows the name")
    }

    @Test func aMissingFieldMeansTheDesktopHasNotMigrated() {
        #expect(CompanionFinishedRun.desktopLists(nil, hostID: "mac") == nil)
        #expect(CompanionFinishedRun.desktopLists(.array([]), hostID: "mac") == nil)
    }

    @Test(arguments: [
        ("Plain words", "Plain words"),
        ("# Done\n\nFixed **two** bugs\nin `a.swift`.", "Done Fixed two bugs in a.swift."),
        ("- one\n- [link](https://x.y)", "one link"),
        ("```\ncode\n```", "code")
    ])
    func summariesReadAsOneLine(markdown: String, text: String) {
        #expect(CompanionFinishedRun.plainText(markdown) == text)
    }

    @Test func runsSavedBeforeSummariesStillLoad() throws {
        // A list saved by #165 has no `summary` key.
        let old = #"{"runs":[{"target":{"hostID":"mac","projectID":"p","agentID":"a"},"name":"a","mission":"m","exitCode":0,"status":"completed","completedAt":0}],"dismissed":[]}"#
        let runs = try JSONDecoder().decode(CompanionFinishedRuns.self, from: Data(old.utf8))
        #expect(runs.runs.first?.summary == nil && runs.runs.first?.detail == "Finished")
    }
}

// MARK: - Merging

struct CompanionFinishedMergeTests {
    @Test func theDesktopsEntryWinsAndAgentsItHasntListedYetJoinInTimeOrder() {
        let desktop = [run("b", minutesAgo: 5, summary: "From the desktop"), run("d", minutesAgo: 30)]
        let merged = CompanionFinishedRuns.merged(desktop: desktop, exited: [exited("b", minutesAgo: 5), exited("c", minutesAgo: 10), exited("a", minutesAgo: 1)],
                                                  dismissed: [], now: now)
        #expect(merged.map(\.target.agentID) == ["a", "b", "c", "d"])
        #expect(merged[1].detail == "From the desktop", "No duplicate, and the desktop's entry is kept")
    }

    @Test func agentsDismissedOnThePhoneStayOut() {
        let merged = CompanionFinishedRuns.merged(desktop: [], exited: [exited("a", minutesAgo: 1)],
                                                  dismissed: [.init(hostID: "mac", projectID: "p", agentID: "a")], now: now)
        #expect(merged.isEmpty)
    }

    @Test func runningAgentsArentAdded() {
        var running = exited("a", minutesAgo: 1)
        running.hasExited = false; running.status = .working
        #expect(CompanionFinishedRuns.merged(desktop: [], exited: [running], dismissed: [], now: now).isEmpty)
    }
}

// MARK: - Store

@MainActor private final class FinishedService: CompanionService {
    var sent: [String] = []
    var failure: CompanionServiceError?
    var gate: CheckedContinuation<Void, Never>?
    var holds = false
    var reply: [CompanionFinishedRun] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func dismissFinishedQuick(_ target: CompanionTarget, clientCommandID: String) async throws -> [CompanionFinishedRun] {
        try await answer("dismiss:\(target.projectID):\(target.agentID)")
    }
    func clearFinishedQuick(_ project: CompanionProjectTarget, clientCommandID: String) async throws -> [CompanionFinishedRun] {
        try await answer("clear:\(project.projectID)")
    }
    private func answer(_ command: String) async throws -> [CompanionFinishedRun] {
        sent.append(command)
        if holds { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        return reply
    }
    func release() { gate?.resume(); gate = nil }
}

@Suite @MainActor struct CompanionFinishedSyncStoreTests {
    private func ids(_ store: CompanionStore) -> [String] { store.finished(in: project).map(\.target.agentID) }

    @Test func theDesktopsListReplacesThePhonesOnceShared() {
        let store = CompanionStore(service: FinishedService())
        // Before the desktop migrates, the phone's own record shows.
        store.apply(.hosts([host(list: nil, agents: [exited("local", minutesAgo: 2)])]))
        #expect(ids(store) == ["local"] && !store.sharesFinished(project))
        // Once shared: the desktop's list, plus what it hasn't listed yet.
        store.apply(.hosts([host(list: [run("desk", minutesAgo: 20)])]))
        #expect(ids(store) == ["desk"] && store.sharesFinished(project), "The phone's old record of an agent the catalog dropped isn't shown")
    }

    @Test func aDesktopWithoutTheCapabilityKeepsThePhonesList() async {
        let service = FinishedService()
        let store = CompanionStore(service: service)
        store.apply(.hosts([host(sync: false, list: [run("desk", minutesAgo: 1)], agents: [exited("local", minutesAgo: 2)])]))
        #expect(ids(store) == ["local"])
        await store.dismissFinished(.init(hostID: "mac", projectID: "p", agentID: "local"))
        #expect(service.sent.isEmpty, "A local list never sends commands")
        #expect(ids(store).isEmpty)
    }

    @Test func dismissIsSentAndHiddenAtOnce() async {
        let service = FinishedService()
        service.holds = true
        service.reply = [run("b", minutesAgo: 9)]
        let store = CompanionStore(service: service)
        store.apply(.hosts([host(list: [run("a", minutesAgo: 1), run("b", minutesAgo: 9)])]))
        let task = Task { await store.dismissFinished(.init(hostID: "mac", projectID: "p", agentID: "a")) }
        while service.gate == nil { await Task.yield() }
        #expect(ids(store) == ["b"], "Gone before the desktop replies")
        #expect(service.sent == ["dismiss:p:a"])
        service.release()
        await task.value
        #expect(ids(store) == ["b"] && store.finishedError == nil)
        #expect(store.pendingFinishedRemovals.isEmpty)
    }

    @Test func aRefusedDismissComesBackWithTheReason() async {
        let service = FinishedService()
        service.failure = .rejected("Your desktop is still setting up its finished list. Try again in a moment.")
        let store = CompanionStore(service: service)
        store.apply(.hosts([host(list: [run("a", minutesAgo: 1)])]))
        await store.dismissFinished(.init(hostID: "mac", projectID: "p", agentID: "a"))
        #expect(ids(store) == ["a"])
        #expect(store.finishedError?.contains("setting up") == true)
    }

    @Test func clearAllSendsOneCommandAndKeepsCatalogAgentsFromComingBack() async {
        let service = FinishedService()
        let store = CompanionStore(service: service)
        // "late" exited on the desktop but isn't in its list yet.
        let clock = Date()
        store.apply(.hosts([host(list: [run("a", minutesAgo: 1, from: clock)], agents: [exited("late", minutesAgo: 0.5, from: clock)])]))
        #expect(ids(store) == ["late", "a"])
        await store.clearFinished(in: project)
        #expect(service.sent == ["clear:p"])
        #expect(ids(store).isEmpty)
        // The next snapshot still lists "late" in the catalog for a minute; it stays cleared.
        store.apply(.hosts([host(list: [], agents: [exited("late", minutesAgo: 0.5, from: clock)])]))
        #expect(ids(store).isEmpty)
    }

    @Test func changesNeedAConnectedDesktop() async {
        let service = FinishedService()
        let store = CompanionStore(service: service)
        store.apply(.hosts([host(list: [run("a", minutesAgo: 1)], connection: .reconnecting)]))
        await store.dismissFinished(.init(hostID: "mac", projectID: "p", agentID: "a"))
        #expect(service.sent.isEmpty && ids(store) == ["a"])
        #expect(store.finishedError?.contains("Reconnect") == true)
    }
}
