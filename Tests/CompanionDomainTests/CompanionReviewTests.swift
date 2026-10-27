import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Review's paging order, filters and empty states, against the desktop's Review plugin
/// (`src/renderer/plugins/builtin/review/reviewModel.ts` and `filters.ts`).
struct CompanionReviewTests {
    @MainActor private final class StubService: CompanionService {
        func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
        func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
        func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
        func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
        func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
        func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
        func reconnect(hostID: String) async {}
    }

    private func target(_ id: String, host: String = "mac", project: String = "p1") -> CompanionTarget { .init(hostID: host, projectID: project, agentID: id) }
    private func agent(_ id: String, _ status: CompanionAgentStatus, host: String = "mac", project: String = "p1") -> CompanionAgent {
        .init(id: target(id, host: host, project: project), name: id, subtitle: "", status: status, capabilities: [.chat, .approve])
    }
    private func entry(_ id: String, _ status: CompanionAgentStatus) -> CompanionReviewEntry {
        .init(agent: agent(id, status), hostName: "MacBook", projectName: "P1")
    }
    private func ids(_ entries: [CompanionReviewEntry]) -> [String] { entries.map(\.agent.id.agentID) }

    // MARK: Order

    @MainActor @Test func pagesFollowDesktopOrderAcrossDesktopsAndProjects() {
        let store = CompanionStore(service: StubService())
        var busy = agent("busy", .working); busy.lastActivity = Date()
        store.apply(.hosts([
            .init(id: "mac", name: "MacBook", endpoint: "", connection: .connected, projects: [
                .init(id: "p1", name: "P1", agents: [agent("a", .idle), busy]),
                .init(id: "p2", name: "P2", agents: [agent("asking", .waiting, project: "p2")])
            ]),
            .init(id: "studio", name: "Studio", endpoint: "", connection: .reconnecting, projects: [
                .init(id: "p1", name: "Notes", agents: [agent("c", .approval, host: "studio")])
            ]),
            .init(id: "laptop", name: "Laptop", endpoint: "", connection: .offline, projects: [
                .init(id: "p1", name: "Away", agents: [agent("away", .approval, host: "laptop")])
            ])
        ]))
        let entries = store.reviewEntries
        // Neither activity nor Needs you reorders the pages, so nothing moves under your finger. Offline desktops stay out.
        #expect(ids(entries) == ["a", "busy", "asking", "c"])
        #expect(entries[2].hostName == "MacBook" && entries[2].projectName == "P2")
        #expect(entries[3].projectName == "Notes")
    }

    /// The desktop drops an exited quick agent from its agent list, so Review never pages to it. A quick agent
    /// that's still running stays, and so does a durable agent that completed its turn.
    @MainActor @Test func finishedQuickAgentsAreLeftOut() {
        let store = CompanionStore(service: StubService())
        var running = agent("running", .working); running.isQuick = true
        var done = agent("done", .completed); done.isQuick = true; done.hasExited = true
        var failed = agent("failed", .failed); failed.isQuick = true; failed.hasExited = true; failed.exitCode = 1
        let durable = agent("durable", .completed)
        store.apply(.hosts([
            .init(id: "mac", name: "MacBook", endpoint: "", connection: .connected, projects: [
                .init(id: "p1", name: "P1", agents: [running, done, failed, durable])
            ])
        ]))
        #expect(ids(store.reviewEntries) == ["running", "durable"])
    }

    // MARK: Filters

    @Test func sleepingIsOffAndNeedsYouOnlyDependsOnTheEntryPoint() {
        let filters = CompanionReviewFilters()
        #expect(!filters.includeSleeping)
        #expect(!filters.needsYouOnly)
    }

    @Test func needsYouOnlyKeepsApprovalsQuestionsAndErrors() {
        let entries = [entry("a", .working), entry("b", .approval), entry("c", .waiting), entry("d", .failed), entry("e", .idle), entry("f", .sleeping)]
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init(needsYouOnly: true, includeSleeping: true))) == ["b", "c", "d"])
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init(needsYouOnly: false, includeSleeping: true))) == ["a", "b", "c", "d", "e", "f"])
    }

    @Test func sleepingFilterHidesSleepingAndStopped() {
        let entries = [entry("a", .working), entry("b", .sleeping), entry("c", .stopped), entry("d", .starting)]
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init())) == ["a", "d"])
    }

    // MARK: Paging

    @Test func pageThatLeavesHandsOverToTheNextOneStillListed() {
        let previous = [target("a"), target("b"), target("c"), target("d")]
        // b was answered and c left too: go to d.
        #expect(CompanionReviewModel.successor(of: target("b"), previous: previous, in: [target("a"), target("d")]) == target("d"))
        // The last page went: step back to the one before it.
        #expect(CompanionReviewModel.successor(of: target("d"), previous: previous, in: [target("a"), target("b")]) == target("b"))
        // Still listed: stay, even when others come and go.
        #expect(CompanionReviewModel.successor(of: target("c"), previous: previous, in: [target("e"), target("c")]) == target("c"))
        // Nothing left.
        #expect(CompanionReviewModel.successor(of: target("a"), previous: previous, in: []) == nil)
        // Nothing chosen yet: the first.
        #expect(CompanionReviewModel.successor(of: nil, previous: [], in: [target("c"), target("a")]) == target("c"))
    }

    @Test func positionCountsFromOne() {
        let ids = [target("a"), target("b"), target("c")]
        #expect(CompanionReviewModel.position(of: target("c"), in: ids) == "3 of 3")
        #expect(CompanionReviewModel.position(of: target("z"), in: ids) == nil)
        #expect(CompanionReviewModel.position(of: nil, in: ids) == nil)
    }

    // MARK: Empty states

    @Test func noAgents() {
        let cause = CompanionReviewModel.emptyCause([], filters: .init())
        #expect(cause == .noAgents)
        #expect(cause.title == "No agents yet")
        #expect(cause.message == "Agents you start show up here, one at a time.")
    }

    @Test func nobodyNeedsYouDescribesTheOthers() {
        let entries = [entry("a", .working), entry("b", .idle), entry("c", .sleeping)]
        let cause = CompanionReviewModel.emptyCause(entries, filters: .init(needsYouOnly: true, includeSleeping: true))
        #expect(cause == .nobodyNeedsYou(others: entries))
        #expect(cause.title == "Nobody needs you")
        #expect(cause.message == "2 agents are running and 1 is asleep. One shows up here when it asks for permission or hits an error.")
        // Sleeping off: only the awake ones are described.
        #expect(CompanionReviewModel.emptyCause(entries, filters: .init(needsYouOnly: true)).message
                == "2 agents are running. One shows up here when it asks for permission or hits an error.")
    }

    @Test func nothingRunningWhenEveryoneSleepsAndSleepingIsOff() {
        let entries = [entry("a", .sleeping), entry("b", .stopped)]
        for needsYouOnly in [false, true] {
            let cause = CompanionReviewModel.emptyCause(entries, filters: .init(needsYouOnly: needsYouOnly))
            #expect(cause == .nothingRunning(sleepers: entries))
            #expect(cause.title == "Nothing is running")
            #expect(cause.message == "2 agents are asleep. Turn on Sleeping to step through them, or wake one here.")
        }
        #expect(CompanionReviewModel.emptyCause([entry("a", .sleeping)], filters: .init()).message
                == "1 agent is asleep. Turn on Sleeping to step through them, or wake one here.")
    }

    @Test func describeCountsRunningAndAsleep() {
        #expect(CompanionReviewModel.describe([entry("a", .working)]) == "1 agent is running")
        #expect(CompanionReviewModel.describe([entry("a", .sleeping), entry("b", .sleeping)]) == "2 agents are asleep")
        #expect(CompanionReviewModel.describe([entry("a", .working), entry("b", .sleeping)]) == "1 agent is running and 1 is asleep")
    }
}
