#if DEBUG
import Foundation

/// Only the in-memory preview uses these byte-exact request checks; no desktop is contacted.
enum CompanionUnicodeFocusFixture {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--companion-preview-unicode-focus")
    }

    static func seed(_ store: CompanionStore) {
        guard enabled else { return }
        let target = CompanionPreviewService.sleepingTarget
        store.drafts[target] = ProcessInfo.processInfo.environment["COMPANION_UNICODE_DRAFT"] ?? ""
        store.justCreated = target
    }

    static func requestError(_ text: String) -> CompanionServiceError {
        guard let expected = ProcessInfo.processInfo.environment["COMPANION_UNICODE_EXPECTED"] else {
            return .unavailable("Unicode fixture is missing its expected request.")
        }
        return .unavailable(Array(text.utf8) == Array(expected.utf8)
            ? "Unicode fixture: request bytes match."
            : "Unicode fixture: request bytes differ.")
    }
}
#endif
