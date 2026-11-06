import Foundation
import Testing
@testable import CompanionDomain

@MainActor private final class AttentionService: CompanionService {
    var retried: [String] = []
    var responses: [CompanionTarget] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { responses.append(target) }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async { retried.append(hostID) }
}

@Suite @MainActor struct CompanionAttentionAvailabilityTests {
    private let now = Date()
    private func host(_ id: String, _ connection: CompanionConnection, status: CompanionAgentStatus = .approval) -> CompanionHost {
        .init(id: id, name: "Mac \(id)", endpoint: "", connection: connection,
              projects: [.init(id: "project", name: "Project", agents: [
                .init(id: .init(hostID: id, projectID: "project", agentID: "same-local-id"), name: "Agent \(id)", subtitle: "", status: status, capabilities: [.approve])
              ])], hasLoadedCatalog: true)
    }
    private func approval(_ id: String, urgent: Bool = false) -> CompanionApproval {
        .init(id: id, toolName: "Edit", summary: "Edit a file", deadline: urgent ? now.addingTimeInterval(60) : nil,
              options: [.init(id: "allow", label: "Allow once", kind: .allowOnce)])
    }
    private func store(_ hosts: [CompanionHost], service: AttentionService = AttentionService()) -> CompanionStore {
        let store = CompanionStore(service: service)
        store.apply(.hosts(hosts))
        for host in hosts {
            for agent in host.allAgents {
                store.apply(.timeline(agent.id, items: [.approval(approval(host.id, urgent: host.id == "b"))], sequence: 1, reset: true))
            }
        }
        return store
    }

    @Test(arguments: [CompanionConnection.offline, .failed("Socket closed"), .connecting, .reconnecting, .synchronizing])
    func unavailableDesktopIsUnknownAndItsCachedApprovalCannotBeActedOn(connection: CompanionConnection) async throws {
        let service = AttentionService()
        let hosts = [host("a", .connected), host("b", connection)]
        let store = store(hosts, service: service)
        let availability = CompanionAttentionAvailability(hosts: hosts)
        let notice = try #require(availability.unavailableHosts.first)
        #expect(availability.unavailableHosts.map(\.id) == ["b"])
        #expect(notice.title == connection.sentence(hostName: "Mac b"))
        #expect(CompanionAttentionAvailability.UnavailableHost.detail.contains("unknown"))
        #expect(notice.isConnecting == [.connecting, .reconnecting, .synchronizing].contains(connection))
        #expect(notice.retryHostID == (notice.isConnecting ? nil : "b"))
        #expect(store.attentionItems(now: now).map(\.agent.id.hostID) == ["a"])
        #expect(store.needsYouCount == 1)
        let target = hosts[1].allAgents[0].id
        #expect(store.conversation(for: target).items.count == 1, "Cached history is retained, but not offered as an action")
        let cachedApproval = approval("b")
        await store.respond(cachedApproval, option: cachedApproval.options[0], target: target)
        #expect(service.responses.isEmpty)
        #expect(availability.emptyTitle == "No requests to show")
        #expect(availability.emptyDetail.contains("unavailable"))
    }

    @Test func bothOnlineKeepFlatUrgencyOrderAndRestoreItemsAfterReconnect() {
        var hosts = [host("a", .connected), host("b", .offline)]
        let store = store(hosts)
        #expect(store.needsYouCount == 1)
        hosts[1].connection = .connected
        store.apply(.hosts(hosts))
        #expect(store.attentionItems(now: now).map(\.agent.id.hostID) == ["b", "a"], "Urgency crosses desktop boundaries")
        #expect(store.needsYouCount == 2)
        #expect(CompanionAttentionAvailability(hosts: hosts).unavailableHosts.isEmpty)
    }

    @Test func neitherOnlineOffersSeparateScopedRetriesAndNoStaleRequests() async throws {
        let hosts = [host("a", .offline), host("b", .failed("Lost connection"))]
        let service = AttentionService()
        let store = store(hosts, service: service)
        let availability = CompanionAttentionAvailability(hosts: hosts)
        #expect(store.attentionItems(now: now).isEmpty && store.needsYouCount == 0)
        #expect(availability.unavailableHosts.map(\.id) == ["a", "b"])
        #expect(availability.emptyTitle != "All caught up")
        let retryHostID = try #require(availability.unavailableHosts[1].retryHostID)
        await store.reconnect(hostID: retryHostID)
        #expect(service.retried == ["b"], "Retry must target its own desktop, not every desktop or the selected chat")
    }

    @Test func reachableApprovalStillRoutesToItsDesktopWhenTheOtherIsOffline() async throws {
        let service = AttentionService()
        let store = store([host("a", .offline), host("b", .connected)], service: service)
        let item = try #require(store.attentionItems(now: now).first)
        guard case .approval(let approval) = item.kind else { Issue.record("Expected approval"); return }
        await store.respond(approval, option: approval.options[0], target: item.agent.id)
        #expect(service.responses == [item.agent.id])
        #expect(service.responses.first?.hostID == "b")
    }

    @Test func emptyCopyDistinguishesKnownEmptyUnknownCatalogAndNoPairing() {
        let hosts = [host("a", .connected, status: .idle), host("b", .connected, status: .idle)]
        #expect(store(hosts).attentionItems(now: now).isEmpty)
        let ready = CompanionAttentionAvailability(hosts: hosts)
        #expect(ready.emptyTitle == "All caught up" && ready.emptyDetail == "Nothing is waiting on you.")
        #expect(ready.emptySystemImage == "checkmark.circle")
        var incomplete = hosts
        incomplete[1].hasLoadedCatalog = false
        let unknown = CompanionAttentionAvailability(hosts: incomplete)
        #expect(unknown.emptyTitle == "No requests to show")
        #expect(unknown.emptyDetail.contains("still loading"))
        #expect(unknown.emptySystemImage == "arrow.triangle.2.circlepath")
        let unpaired = CompanionAttentionAvailability(hosts: [])
        #expect(unpaired.unavailableHosts.isEmpty)
        #expect(unpaired.emptyTitle == "No desktops paired")
        #expect(unpaired.emptyDetail == "Pair a desktop to see what needs you.")
        #expect(unpaired.emptySystemImage == "desktopcomputer")
    }

    @Test func quietReachableDesktopDoesNotHideUnknownPendingItemsOnTheOtherDesktop() {
        let hosts = [host("a", .connected, status: .idle), host("b", .offline)]
        let store = store(hosts)
        #expect(store.attentionItems(now: now).isEmpty && store.needsYouCount == 0)
        let availability = CompanionAttentionAvailability(hosts: hosts)
        #expect(availability.unavailableHosts.map(\.id) == ["b"])
        #expect(availability.emptyTitle == "No requests to show")
        #expect(availability.emptyDetail.contains("may be missing"))
        #expect(availability.emptySystemImage == "wifi.slash")
    }
}
