import Foundation

/// Drafts contain no connection credentials. This storage is local to the app;
/// no iCloud defaults or external synchronization is used.
@MainActor final class CompanionLocalDrafts: CompanionDraftPersistence {
    private struct Entry: Codable { var target: CompanionTarget; var text: String }
    private let defaults: UserDefaults
    private let key = "clubhouse.companion.drafts.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [CompanionTarget: String] {
        guard let data = defaults.data(forKey: key), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.target, $0.text) }, uniquingKeysWith: { _, newer in newer })
    }
    func save(_ drafts: [CompanionTarget: String]) {
        let entries = drafts.filter { !$0.value.isEmpty }.map { Entry(target: $0.key, text: $0.value) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
