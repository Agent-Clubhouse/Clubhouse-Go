import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// The snapshot's `finishedQuickAgents` and the `quick.dismiss` / `quick.clear` replies (desktop #2468,
/// `docs/mobile-control-v1.md` → Finished quick agents).
extension CompanionFinishedRun {
    /// Every project's list, or nil when the desktop didn't send the field (an older desktop, or one not yet migrated).
    static func desktopLists(_ json: AnnexJSON?, hostID: String) -> [String: [CompanionFinishedRun]]? {
        guard case .object(let projects)? = json else { return nil }
        return Dictionary(uniqueKeysWithValues: projects.map { id, list in (id, desktopList(list, project: .init(hostID: hostID, projectID: id))) })
    }

    /// One project's entries, in the desktop's order. An entry without an `agentId` is skipped.
    static func desktopList(_ json: AnnexJSON, project: CompanionProjectTarget) -> [CompanionFinishedRun] {
        Optional(json).arrayValue.compactMap { value in
            guard let agentID = value["agentId"]?.string, !agentID.isEmpty else { return nil }
            let exitCode = value["exitCode"]?.integer.map(Int.init) ?? 0
            let cancelled = value["cancelled"].boolValue
            return CompanionFinishedRun(target: .init(hostID: project.hostID, projectID: project.projectID, agentID: agentID),
                                        name: value["name"]?.string ?? agentID, mission: value["prompt"]?.string ?? "",
                                        exitCode: exitCode, status: cancelled ? .stopped : exitCode != 0 ? .failed : .completed,
                                        completedAt: value["finishedAt"].flatMap(CompanionLiveService.date(from:)) ?? Date(timeIntervalSince1970: 0),
                                        summary: value["summary"]?.string)
        }
    }
}
