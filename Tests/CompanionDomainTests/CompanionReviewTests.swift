import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Review's paging order, filters and empty states, against the desktop's Review plugin
/// (`src/renderer/plugins/builtin/review/reviewModel.ts` and `filters.ts`).
struct CompanionReviewTests {
    @MainActor private final class StubService: CompanionService {
        var history: [CompanionTarget: [CompanionTimelineItem]] = [:]
        func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
        func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: history[target] ?? []) }
        func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
        func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
        func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
        func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
        func reconnect(hostID: String) async {}
    }

    private func target(_ id: String, host: String = "mac") -> CompanionTarget { .init(hostID: host, projectID: "p1", agentID: id) }
    private func agent(_ id: String, _ status: CompanionAgentStatus, host: String = "mac") -> CompanionAgent {
        .init(id: target(id, host: host), name: id, subtitle: "", status: status, capabilities: [.chat, .approve])
    }
    private func entry(_ id: String, _ status: CompanionAgentStatus, remote: Bool = false, host: String = "mac", attention: CompanionAttentionItem.Kind? = nil) -> CompanionReviewEntry {
        .init(agent: agent(id, status, host: host), hostName: host == "mac" ? "MacBook" : "Studio", projectName: "P1", isRemote: remote, attention: attention)
    }
    private func ids(_ entries: [CompanionReviewEntry]) -> [String] { entries.map(\.agent.id.agentID) }
    private let everyone = CompanionReviewFilters(needsYouOnly: false, includeSleeping: true, includeRemote: true)

    // MARK: Order

    @Test func needsYouComesFirstInAttentionOrderThenTheRest() {
        let entries = [entry("a", .working), entry("b", .approval), entry("c", .idle), entry("d", .failed), entry("e", .waiting)]
        let ordered = CompanionReviewModel.ordered(entries, attentionOrder: [target("e"), target("b"), target("d")])
        #expect(ids(ordered) == ["e", "b", "d", "a", "c"])
    }

    @Test func needsYouMissingFromAttentionStillLeadsTheRest() {
        // An offline desktop's agent isn't in Needs you, but still waits on you once you include it.
        let entries = [entry("a", .working), entry("b", .approval, remote: true, host: "studio"), entry("c", .waiting)]
        let ordered = CompanionReviewModel.ordered(entries, attentionOrder: [target("c")])
        #expect(ids(ordered) == ["c", "b", "a"])
    }

    @MainActor @Test func storeEntriesFollowNeedsYouThenActivity() {
        let store = CompanionStore(service: StubService())
        var old = agent("old", .working); old.lastActivity = Date(timeIntervalSince1970: 100)
        var recent = agent("recent", .idle); recent.lastActivity = Date(timeIntervalSince1970: 200)
        let asking = agent("asking", .waiting)
        store.apply(.hosts([
            .init(id: "mac", name: "MacBook", endpoint: "", connection: .connected, projects: [.init(id: "p1", name: "P1", agents: [old, recent, asking])]),
            .init(id: "studio", name: "Studio", endpoint: "", connection: .offline, projects: [.init(id: "p1", name: "Notes", agents: [agent("away", .idle, host: "studio")])])
        ]))
        let entries = store.reviewEntries()
        #expect(ids(entries) == ["asking", "recent", "old", "away"])
        #expect(entries[0].attention == .unreviewed)
        #expect(entries[0].hostName == "MacBook" && entries[0].projectName == "P1")
        #expect(entries.map(\.isRemote) == [false, false, false, true])
        #expect(entries[3].projectName == "Notes")
    }

    @MainActor @Test func pendingApprovalRidesOnTheCard() async {
        let service = StubService()
        let store = CompanionStore(service: service)
        let river = agent("river", .approval)
        let approval = CompanionApproval(id: "ap", toolName: "Bash", summary: "Run tests", options: [.init(id: "allow", label: "Allow once", kind: .allowOnce)])
        service.history[river.id] = [.approval(approval)]
        store.apply(.hosts([.init(id: "mac", name: "MacBook", endpoint: "", connection: .connected, projects: [.init(id: "p1", name: "P1", agents: [river])])]))
        await store.load(river.id)
        #expect(store.reviewEntries().first?.attention == .approval(approval))
    }

    // MARK: Filters

    @Test func needsYouOnlyIsTheDefault() {
        let filters = CompanionReviewFilters()
        #expect(filters.needsYouOnly)
        #expect(filters.includeSleeping)
        #expect(!filters.includeRemote)
    }

    @Test func needsYouOnlyKeepsApprovalsQuestionsAndErrors() {
        let entries = [entry("a", .working), entry("b", .approval), entry("c", .waiting), entry("d", .failed), entry("e", .idle), entry("f", .sleeping)]
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init(needsYouOnly: true, includeSleeping: true, includeRemote: true))) == ["b", "c", "d"])
        #expect(ids(CompanionReviewModel.visible(entries, filters: everyone)) == ["a", "b", "c", "d", "e", "f"])
    }

    @Test func sleepingFilterHidesSleepingAndStopped() {
        let entries = [entry("a", .working), entry("b", .sleeping), entry("c", .stopped)]
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init(needsYouOnly: false, includeSleeping: false, includeRemote: true))) == ["a"])
    }

    @Test func remoteFilterHidesUnreachableDesktops() {
        let entries = [entry("a", .working), entry("b", .approval, remote: true, host: "studio")]
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init(needsYouOnly: false, includeSleeping: true, includeRemote: false))) == ["a"])
        #expect(ids(CompanionReviewModel.visible(entries, filters: .init(needsYouOnly: true, includeSleeping: true, includeRemote: true))) == ["b"])
    }

    // MARK: Paging

    @Test func nextWrapsAndStopsWhenAlone() {
        let ids = [target("a"), target("b"), target("c")]
        #expect(CompanionReviewModel.next(after: target("a"), in: ids) == target("b"))
        #expect(CompanionReviewModel.next(after: target("c"), in: ids) == target("a"))
        #expect(CompanionReviewModel.next(after: target("a"), in: [target("a")]) == nil)
        #expect(CompanionReviewModel.next(after: target("z"), in: ids) == target("a"))
    }

    @Test func answeredCardHandsOverToTheNextOneStillListed() {
        let previous = [target("a"), target("b"), target("c"), target("d")]
        // b was answered and c left too: go to d.
        #expect(CompanionReviewModel.successor(of: target("b"), previous: previous, in: [target("a"), target("d")]) == target("d"))
        // The last card went: step back to the one before it.
        #expect(CompanionReviewModel.successor(of: target("d"), previous: previous, in: [target("a"), target("b")]) == target("b"))
        // Still listed: stay.
        #expect(CompanionReviewModel.successor(of: target("c"), previous: previous, in: [target("c"), target("a")]) == target("c"))
        // Nothing left.
        #expect(CompanionReviewModel.successor(of: target("a"), previous: previous, in: []) == nil)
        // Nothing chosen yet: the first.
        #expect(CompanionReviewModel.successor(of: nil, previous: [], in: [target("c")]) == target("c"))
    }

    @Test func positionCountsFromOne() {
        let ids = [target("a"), target("b")]
        #expect(CompanionReviewModel.position(of: target("b"), in: ids) == "2 of 2")
        #expect(CompanionReviewModel.position(of: target("z"), in: ids) == nil)
    }

    // MARK: Empty states

    @Test func noAgents() {
        let cause = CompanionReviewModel.emptyCause([], filters: .init())
        #expect(cause == .noAgents)
        #expect(cause.title == "No agents yet")
        #expect(cause.message == "Agents you start show up here, one at a time.")
    }

    @Test func nobodyNeedsYouDescribesTheOthers() {
        let entries = [entry("a", .working), entry("b", .working), entry("c", .sleeping)]
        let cause = CompanionReviewModel.emptyCause(entries, filters: .init())
        #expect(cause == .nobodyNeedsYou(others: entries))
        #expect(cause.title == "Nobody needs you")
        #expect(cause.message == "2 agents are running and 1 is asleep. One shows up here when it asks for permission or hits an error.")
    }

    @Test func nothingRunningWhenEveryoneSleepsAndSleepingIsOff() {
        let entries = [entry("a", .sleeping), entry("b", .sleeping, remote: true, host: "studio")]
        let cause = CompanionReviewModel.emptyCause(entries, filters: .init(needsYouOnly: false, includeSleeping: false, includeRemote: false))
        #expect(cause == .nothingRunning(sleepers: [entries[0]]))
        #expect(cause.title == "Nothing is running")
        #expect(cause.message == "1 agent is asleep. Turn on Sleeping to step through them, or wake one here.")
    }

    @Test func filtersHideEveryoneCountsWhatEachWouldShow() {
        let entries = [entry("a", .sleeping), entry("b", .working, remote: true, host: "studio"), entry("c", .sleeping, remote: true, host: "studio")]
        let cause = CompanionReviewModel.emptyCause(entries, filters: .init(needsYouOnly: false, includeSleeping: false, includeRemote: false))
        #expect(cause == .filtered(total: 3, hiddenBySleeping: 1, hiddenByRemote: 1))
        #expect(cause.title == "Your filters hide all 3 agents")
        #expect(cause.message == "Turn one of these on, or clear the filters.")
        #expect(CompanionReviewModel.remoteWhere(entries) == "on Studio")
    }

    @Test func filtersHideTheOnlyAgent() {
        let entries = [entry("a", .working, remote: true, host: "studio")]
        let cause = CompanionReviewModel.emptyCause(entries, filters: .init())
        #expect(cause == .filtered(total: 1, hiddenBySleeping: 0, hiddenByRemote: 1))
        #expect(cause.title == "Your filters hide the only agent")
    }

    @Test func remoteWhereCountsDesktops() {
        let entries = [entry("a", .working, remote: true, host: "studio"), entry("b", .working, remote: true, host: "laptop")]
        #expect(CompanionReviewModel.remoteWhere(entries) == "on 2 desktops")
    }

    @Test func latestReplySkipsUserMessagesAndBlanks() {
        let items: [CompanionTimelineItem] = [
            .message(.init(id: "1", role: .assistant, text: "First")),
            .message(.init(id: "2", role: .assistant, text: "  ")),
            .message(.init(id: "3", role: .user, text: "Thanks")),
            .tool(.init(id: "t", name: "Read", summary: "", state: .completed))
        ]
        #expect(CompanionReviewModel.latestReply(in: items)?.id == "1")
        #expect(CompanionReviewModel.latestReply(in: []) == nil)
    }
}
