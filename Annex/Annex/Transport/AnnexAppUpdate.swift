import Foundation

nonisolated public enum AnnexUpdateMode: String, Sendable, CaseIterable {
    case now, whenIdle = "when_idle"
}

nonisolated public struct AnnexAppUpdateCapability: Decodable, Sendable, Equatable {
    public let version: Int
    public let snapshotField: String
    public let event: String
    public let commands: [String]
    public let approvalCommand: String
    public let approvalModeField: String
    public let modes: [String]
    public let idleWaitMs: Int
    public var isSupported: Bool {
        version >= 1 && snapshotField == "appUpdate" && event == "app_update:changed"
            && commands.contains("app.update.request") && commands.contains("app.update.cancel")
            && approvalCommand == "grant.answer" && approvalModeField == "updateMode"
            && modes.contains("now") && modes.contains("when_idle")
    }
}

nonisolated public struct AnnexAppUpdate: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable { case none, available, downloading, ready, unsupported }
    public struct Request: Decodable, Sendable, Equatable {
        public enum State: String, Decodable, Sendable {
            case pendingApproval = "pending_approval", waitingForIdle = "waiting_for_idle", restarting, failed, cancelled
        }
        public let requestId: String
        public let state: State
        public let version: String
        public let expiresAt: String?
        public let error: String?
        public init(requestId: String, state: State, version: String, expiresAt: String? = nil, error: String? = nil) {
            self.requestId = requestId; self.state = state; self.version = version; self.expiresAt = expiresAt; self.error = error
        }
        public var canCancel: Bool { state == .pendingApproval || state == .waitingForIdle }
        public var isActive: Bool { canCancel || state == .restarting }
    }
    public let state: State
    public let currentVersion: String
    public let availableVersion: String?
    public let downloadProgress: Double
    public let reason: String?
    public let request: Request?
    public init(state: State, currentVersion: String, availableVersion: String? = nil, downloadProgress: Double = 0,
                reason: String? = nil, request: Request? = nil) {
        self.state = state; self.currentVersion = currentVersion; self.availableVersion = availableVersion
        self.downloadProgress = downloadProgress; self.reason = reason; self.request = request
    }
    public var canRequest: Bool { state == .ready && availableVersion != nil && request?.isActive != true }
}

nonisolated public struct AnnexUpdateReview: Decodable, Sendable, Equatable {
    public struct Agent: Decodable, Sendable, Equatable {
        public let agentId: String
        public let name: String
        public init(agentId: String, name: String) { self.agentId = agentId; self.name = name }
    }
    public let version: String
    public let workingAgents: [Agent]
    public init(version: String, workingAgents: [Agent]) { self.version = version; self.workingAgents = workingAgents }
}
