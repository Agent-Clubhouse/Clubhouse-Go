import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Only small references survive a snapshot. Protocol negotiation can replace this inline adapter
/// without changing the store, row identity, or sender resolver.
nonisolated struct CompanionIconCatalog: Sendable, Equatable {
    var projects: [String: CompanionIconReference] = [:]
    var agents: [String: CompanionIconReference] = [:]

    var references: Set<CompanionIconReference> { Set(projects.values).union(agents.values) }
    /// Only object submaps establish absence. Missing/null/invalid maps are unknown.
    mutating func applyReferences(_ value: AnnexJSON?, host: String) {
        if case .object(let entries)? = value?["projects"] {
            projects = entries.reduce(into: [:]) { result, entry in
                if !entry.key.isEmpty, let metadata = CompanionIconMetadata(entry.value) { result[entry.key] = .init(host: host, kind: .project, id: entry.key, version: entry.value["version"]!.string!, metadata: metadata) }
            }
        }
        if case .object(let entries)? = value?["agents"] {
            agents = entries.reduce(into: [:]) { result, entry in
                if !entry.key.isEmpty, let metadata = CompanionIconMetadata(entry.value) { result[entry.key] = .init(host: host, kind: .agent, id: entry.key, version: entry.value["version"]!.string!, metadata: metadata) }
            }
        }
    }

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
