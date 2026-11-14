import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

nonisolated enum CompanionAppUpdateText {
    static let restart = "Restart now interrupts the listed working agents, then stops any that do not become idle. Stopped agents will not resume. Restart when idle waits up to 30 minutes and never interrupts agents. Agent conversations resume, not interrupted turns."
    static let platform = "On Windows, the package downloads during installation; ready does not mean it is already on disk. A newer Clubhouse release published during installation may replace the reviewed version. On Linux, a local installer or elevation prompt may need an answer on the desktop."
    static let pairing = "Remembered desktops reconnect with the same secure pairing after restart. Session-only pairings may need pairing again. A disconnect does not confirm installation."
    static func indicator(_ update: AnnexAppUpdate, desktop: String) -> String {
        let status = switch update.state {
        case .ready: "Restart to update on \(desktop)"
        case .available: "Update available on \(desktop)"
        case .downloading: "Update downloading on \(desktop)"
        case .unsupported: "Updates unavailable on \(desktop)"
        case .none: "No update known on \(desktop)"
        }
        if let available = update.availableVersion {
            return "\(status): \(available) (running \(update.currentVersion))"
        }
        return "\(status) (running \(update.currentVersion))"
    }
    static func status(_ update: AnnexAppUpdate) -> String {
        switch update.state {
        case .ready: "Update ready: \(update.availableVersion ?? update.currentVersion)"
        case .available: "Update available: \(update.availableVersion ?? update.currentVersion)"
        case .downloading: "Downloading \(update.availableVersion ?? update.currentVersion): \(update.downloadProgress.formatted(.number.precision(.fractionLength(0...1))))%"
        case .none: "No update known (running \(update.currentVersion))"
        case .unsupported: "Updates unavailable"
        }
    }
    static func requestState(_ request: AnnexAppUpdate.Request) -> String {
        switch request.state {
        case .pendingApproval: "Choose how to restart below."
        case .waitingForIdle: "Waiting for every agent to be idle. Nothing will be interrupted."
        case .restarting: "Restarting. Cancellation is no longer available."
        case .failed: request.error ?? "The update failed. Nothing will be retried automatically."
        case .cancelled: "Update request cancelled."
        }
    }

}

nonisolated struct CompanionAppUpdateCheckRunning: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension CompanionHost {
    var hasAppUpdateAffordance: Bool {
        guard canUpdateApp, let state = appUpdate?.state else { return false }
        return state == .available || state == .downloading || state == .ready
    }

    var appUpdateApproval: CompanionGrantRequest? {
        guard canUpdateApp, let request = appUpdate?.request, request.state == .pendingApproval else { return nil }
        return grantRequests.first {
            $0.id == request.requestId && $0.controlEpoch == controlEpoch && $0.isAppUpdate
                && $0.update?.version == request.version
        }
    }
    var canRequestAppUpdate: Bool {
        appUpdate?.canRequest == true && dispatcher?.enabled == true && dispatcher?.liveAgent != nil
            && dispatcher?.mcpOff == nil
    }
}
