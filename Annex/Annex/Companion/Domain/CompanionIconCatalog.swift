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

    func applyingSnapshot(_ snapshot: AnnexEnvelope, usesReferences: Bool, host: String, store: CompanionIconStore) async -> Self {
        let omitted = Set(snapshot.snapshotTruncated?.omitted ?? [])
        if usesReferences {
            var result = self
            if !omitted.contains("iconRefs") { result.applyReferences(snapshot.payload?["iconRefs"], host: host) }
            await store.setReferences(result.references, for: host)
            return result
        }
        var result = await Self.inline(projects: omitted.contains("projectIcons") ? nil : snapshot.payload?["projectIcons"],
                                       agents: omitted.contains("agentIcons") ? nil : snapshot.payload?["agentIcons"],
                                       host: host, store: store)
        if omitted.contains("projectIcons") { result.projects = projects }
        if omitted.contains("agentIcons") { result.agents = agents }
        await store.setReferences(result.references, for: host)
        return result
    }

    static func omissionNotice(_ snapshot: AnnexEnvelope, usesReferences: Bool) -> String? {
        let usedFields: Set<String> = usesReferences ? ["iconRefs"] : ["agentIcons", "projectIcons"]
        guard snapshot.snapshotTruncated?.omitted.contains(where: usedFields.contains) == true else { return nil }
        return "Some images were left out of the latest desktop update to keep it small. Previously loaded images are kept when available."
    }

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
