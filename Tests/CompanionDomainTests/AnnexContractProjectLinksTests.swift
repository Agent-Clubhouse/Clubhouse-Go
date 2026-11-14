import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct AnnexContractProjectLinksDomainTests {
    @Test func desktopSnapshotAndEventReplacementsGroupThenSplitAcrossTwoPairedMachines() async throws {
        let fixture = try ContractFixtures.json("project-links.json")
        let links = try #require(fixture["snapshot"]).decode(AnnexProjectLinks.self)
        let machines = try #require(links.projectLinks.first).projects.map(\.machine)
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop(); for machine in machines { service.remove(hostID: machine) } }
        var transports: [ContractTransport] = []
        for (index, machine) in machines.enumerated() {
            let transport = ContractTransport()
            let host = try TrustedAnnexHost(endpoint: .init(host: "127.0.0.1", port: 7432), verifiedHostID: machine,
                                           verifiedCertificatePin: .init(sha256: String(repeating: "ab", count: 32)))
            await service.register(.init(host: host, alias: "Desktop \(index)", transport: transport))
            transports.append(transport)
        }
        try await waitUntil { store.hosts.count == 2 && store.hosts.allSatisfy { $0.connection.canOperate && $0.canLinkProjects } }
        guard case .object(var snapshot)? = try ContractFixtures.json("snapshot.json")["frame"],
              case .object(var payload)? = snapshot["payload"] else { throw AnnexTransportError.malformedResponse }
        payload["projectLinks"] = fixture["snapshot"]?["projectLinks"]
        snapshot["payload"] = .object(payload)
        try transports[0].emit(.object(snapshot))
        try await waitUntil { store.projectEntries.count == 3 && store.projectEntries.first?.isLinked == true }
        let linked = try #require(store.projectEntries.first)
        #expect(linked.members.map(\.host.id) == machines)
        #expect(Set(linked.project.agents.map(\.id.hostID)) == Set(machines))
        for key in ["keptSeparate", "linked", "unlinked"] {
            try transports[0].emit(try #require(fixture[key]))
            let expected = key == "linked" ? 3 : 4
            try await waitUntil { store.projectEntries.count == expected }
        }
        #expect(store.projectEntries.allSatisfy { !$0.isLinked })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for linked-project fixture")
        throw AnnexTransportError.disconnected
    }
}
