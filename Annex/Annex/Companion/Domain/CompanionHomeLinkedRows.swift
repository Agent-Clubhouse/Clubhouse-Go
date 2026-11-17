import Foundation

/// Retained quiet rows for the already-scoped Home group. HomeLayout still owns the
/// live tree and its order, including each helper's full host/project parent identity.
struct CompanionHomeLinkedRows: Sendable, Equatable {
    let foldID: String
    let finishedRuns: [CompanionFinishedRun]
    let finishedProjects: [CompanionProjectTarget]
    /// A desktop may contain several copies of a linked project. Those origins remain
    /// necessary even when the user scopes Home to that one desktop.
    let projectOriginLabels: [CompanionProjectTarget: String]

    init(entry: CompanionProjectEntry, finished: (CompanionProjectTarget) -> [CompanionFinishedRun]) {
        foldID = entry.orderKey
        let memberCounts = Dictionary(entry.members.map { ($0.host.id, 1) }, uniquingKeysWith: +)
        projectOriginLabels = Dictionary(entry.members.filter { memberCounts[$0.host.id, default: 0] > 1 }.map {
            ($0.id, entry.label(for: $0))
        }, uniquingKeysWith: { first, _ in first })
        var runs: [CompanionFinishedRun] = []
        var projects: [CompanionProjectTarget] = []
        var seen: Set<CompanionTarget> = []
        for member in entry.members where member.host.connection.canOperate {
            let memberRuns = finished(member.id).filter { seen.insert($0.target).inserted }
            if !memberRuns.isEmpty { projects.append(member.id) }
            runs.append(contentsOf: memberRuns)
        }
        // Equal completion times retain desktop order; identity includes the machine.
        finishedRuns = runs.enumerated().sorted {
            $0.element.completedAt == $1.element.completedAt
                ? $0.offset < $1.offset : $0.element.completedAt > $1.element.completedAt
        }.map(\.element)
        finishedProjects = projects
    }
}
