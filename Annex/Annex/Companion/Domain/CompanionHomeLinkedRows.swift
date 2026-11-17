import Foundation

/// Retained quiet rows for the already-scoped Home group. HomeLayout still owns the
/// live tree and its order, including each helper's full host/project parent identity.
struct CompanionHomeLinkedRows: Sendable, Equatable {
    let foldID: String
    let finishedRuns: [CompanionFinishedRun]
    let finishedProjects: [CompanionProjectTarget]

    init(entry: CompanionProjectEntry, finished: (CompanionProjectTarget) -> [CompanionFinishedRun]) {
        foldID = entry.orderKey
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
