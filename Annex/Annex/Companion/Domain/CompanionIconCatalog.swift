import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Only small references survive a snapshot. Protocol negotiation can replace this inline adapter
/// without changing the store, row identity, or sender resolver.
nonisolated struct CompanionIconCatalog: Sendable, Equatable {
    var projects: [String: CompanionIconReference] = [:]
    var agents: [String: CompanionIconReference] = [:]

    static func inline(projects: AnnexJSON?, agents: AnnexJSON?, host: String, store: CompanionIconStore) async -> Self {
        var result = Self()
        if case .object(let values) = projects {
            for (id, value) in values {
                if let url = value.string { result.projects[id] = await store.ingest(dataURL: url, host: host, kind: .project, id: id) }
            }
        }
        if case .object(let values) = agents {
            for (id, value) in values {
                if let url = value.string { result.agents[id] = await store.ingest(dataURL: url, host: host, kind: .agent, id: id) }
            }
        }
        return result
    }
}
