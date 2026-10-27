import Foundation

/// Finished quick agents and the ones dismissed, kept on this phone like the desktop keeps its own list.
/// Names and missions only: no credentials, transcripts or desktop paths.
@MainActor final class CompanionLocalFinished: CompanionFinishedPersistence {
    private let defaults: UserDefaults
    private let key = "clubhouse.companion.finished.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> CompanionFinishedRuns? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CompanionFinishedRuns.self, from: $0) }
    }
    func save(_ runs: CompanionFinishedRuns) {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: key)
    }
}
