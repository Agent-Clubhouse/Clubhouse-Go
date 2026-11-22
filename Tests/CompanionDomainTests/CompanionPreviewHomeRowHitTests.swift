import Foundation
import Testing
@testable import CompanionDomain

#if DEBUG
@MainActor @Suite struct CompanionPreviewHomeRowHitTests {
    @Test(arguments: [false, true])
    func twoDesktopFixtureKeepsTargetsAndOnlyBlanksDetailsWhenRequested(blankDetails: Bool) async throws {
        let service = CompanionPreviewService(showsDispatcher: true, showsMultipleDispatchers: true)
        let arguments = blankDetails ? ["--companion-preview-home-row-hit-area"] : []
        let hosts = try await firstHosts(service.events(homeRowHitAreaArguments: arguments))
        try #require(hosts.count == 2)
        #expect(hosts.map(\.id) == ["preview-studio", "preview-laptop"])
        #expect(hosts.map(\.name) == ["Studio Mac", "Travel MacBook"])
        for host in hosts {
            #expect(host.connection == .connected)
            let agent = try #require(host.dispatcher?.agent)
            #expect(agent.id.hostID == host.id)
            #expect(agent.id.projectID == CompanionDispatcher.defaultProjectID)
            #expect(agent.id.agentID == "durable_dispatcher")
            #expect(agent.name == "Dispatcher" && agent.isDispatcher)
            #expect(agent.status == .idle && agent.capabilities.contains(.chat))
            if blankDetails {
                #expect(agent.detail == nil, "The synthetic blank-space fixture applies to BOTH desktop rows")
            } else {
                #expect(agent.detail == .init(state: "idle", message: "Sent River the reconnect follow-up"),
                        "The default fixture must keep its real status detail, not pass with two already-empty rows")
            }
        }
        #expect(hosts[0].dispatcher?.agent?.id != hosts[1].dispatcher?.agent?.id)
        #expect(hosts[0].projects.first?.id == "website")
        #expect(hosts[1].projects.first?.agents.first?.id == .init(hostID: "preview-laptop", projectID: "notes", agentID: "river"))
    }

    @Test func flagDoesNotEnableAMissingDispatcherOrChangeTheDefaultPreview() async throws {
        let single = CompanionPreviewService(showsDispatcher: true)
        let flagged = try await firstHosts(single.events(homeRowHitAreaArguments: ["--companion-preview-home-row-hit-area"]))
        try #require(flagged.count == 2)
        #expect(flagged[0].dispatcher?.agent?.id == CompanionPreviewService.dispatcherTarget)
        #expect(flagged[0].dispatcher?.agent?.detail == .init(state: "idle", message: "Sent River the reconnect follow-up"))
        #expect(flagged[1].connection == .offline && flagged[1].dispatcher == nil,
                "The blank-space flag alone cannot enable the two-desktop fixture")

        let ordinary = try await firstHosts(CompanionPreviewService(showsDispatcher: true).events())
        #expect(ordinary.map(\.id) == flagged.map(\.id))
        #expect(ordinary.map { $0.dispatcher?.agent?.id } == flagged.map { $0.dispatcher?.agent?.id })
        #expect(ordinary.map { $0.dispatcher?.agent?.detail } == flagged.map { $0.dispatcher?.agent?.detail })
        #expect(ordinary.map { $0.dispatcher?.agent?.name } == flagged.map { $0.dispatcher?.agent?.name })
        #expect(ordinary.map(\.connection) == flagged.map(\.connection))
        let defaultPreview = try await firstHosts(CompanionPreviewService().events())
        #expect(defaultPreview.map(\.id) == ["preview-studio", "preview-laptop"])
        #expect(defaultPreview.allSatisfy { $0.dispatcher == nil })
    }

    private func firstHosts(_ stream: AsyncStream<CompanionEvent>) async throws -> [CompanionHost] {
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        guard case .hosts(let hosts) = event else {
            Issue.record("Preview must first emit its real hosts event")
            return []
        }
        return hosts
    }
}
#endif
