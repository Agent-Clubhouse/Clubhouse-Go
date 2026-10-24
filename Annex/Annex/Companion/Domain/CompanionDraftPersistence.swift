import Foundation

@MainActor protocol CompanionDraftPersistence: AnyObject {
    func load() -> [CompanionTarget: String]
    func save(_ drafts: [CompanionTarget: String])
}
