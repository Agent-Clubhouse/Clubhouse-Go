import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// The desktop's `GitInfo` (`GET /api/v1/projects/{id}/git/info`). Only the branch and uncommitted files are read.
extension CompanionChanges {
    init(json: AnnexJSON) throws {
        guard let hasGit = json["hasGit"]?.boolOrNil else {
            throw CompanionServiceError.unavailable("The desktop sent changes this phone can't read.")
        }
        isRepository = hasGit
        branch = json["branch"]?.string ?? ""
        files = json["status"].arrayValue.compactMap { value in
            guard let path = value["path"]?.string, !path.isEmpty else { return nil }
            return CompanionChangedFile(path: path, originalPath: value["origPath"]?.string, code: value["status"]?.string ?? "",
                                        staged: value["staged"].boolValue)
        }
        ahead = json["ahead"]?.integer.map(Int.init) ?? 0
        behind = json["behind"]?.integer.map(Int.init) ?? 0
        hasConflicts = json["hasConflicts"].boolValue
    }
}
