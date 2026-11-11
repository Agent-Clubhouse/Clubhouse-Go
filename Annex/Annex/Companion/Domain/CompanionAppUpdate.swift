import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

nonisolated enum CompanionAppUpdateText {
    static let restart = "Restart now interrupts the listed working agents, then stops any that do not become idle. Stopped agents will not resume. Restart when idle waits up to 30 minutes and never interrupts agents. Agent conversations resume, not interrupted turns."
    static let platform = "On Windows, the package downloads during installation; ready does not mean it is already on disk. A newer Clubhouse release published during installation may replace the reviewed version. On Linux, a local installer or elevation prompt may need an answer on the desktop."
    static let pairing = "Remembered desktops reconnect with the same secure pairing after restart. Session-only pairings may need pairing again. A disconnect does not confirm installation."
    static func indicator(_ update: AnnexAppUpdate, desktop: String) -> String {
        switch update.state {
        case .ready: "Update ready on \(desktop)"
        case .available: "Update available on \(desktop)"
        case .downloading: "Update downloading on \(desktop)"
        case .unsupported: "Updates unavailable on \(desktop)"
        case .none: "Clubhouse on \(desktop)"
        }
    }
    static func requestState(_ request: AnnexAppUpdate.Request) -> String {
        switch request.state {
        case .pendingApproval: "Waiting for approval in Needs you."
        case .waitingForIdle: "Waiting for every agent to be idle. Nothing will be interrupted."
        case .restarting: "Restarting. Cancellation is no longer available."
        case .failed: request.error ?? "The update failed. Nothing will be retried automatically."
        case .cancelled: "Update request cancelled."
        }
    }
}
