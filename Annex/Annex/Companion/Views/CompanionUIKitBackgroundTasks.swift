import UIKit

/// UIKit's finite background-task assertion and nothing more: no background mode, no entitlement, no state.
struct CompanionUIKitBackgroundTasks: CompanionBackgroundTasking {
    func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expiration() } }
        return id == .invalid ? nil : id.rawValue
    }
    func end(_ id: Int) { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id)) }
}
