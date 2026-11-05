import Foundation

// Provider control v1 from Clubhouse main 4b3b4f59e67adcbe9df477b5f091ae1d9fb81953.
// Availability and instruction comparison have the limited scopes carried in each result.
nonisolated public struct AnnexProviderControlCapability: Decodable, Sendable, Equatable {
    public let version: Int
    public let preview: String
    public let change: String
    public let stoppedAcknowledgment: Bool
    public let strictStart: Bool
    public var isSupported: Bool {
        version == 1 && preview == "agent.providerPreview" && change == "agent.providerChange"
            && stoppedAcknowledgment && strictStart
    }
}

/// Common preview/change fields. These describe local CLI and native primary files only.
nonisolated public struct AnnexProviderOutcome: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable { case running, stopping, starting, creating, sleeping }
    public enum Instructions: String, Decodable, Sendable { case equivalent, different, unverified }
    public enum Runtime: String, Decodable, Sendable { case terminal, chat }
    public enum NextStart: String, Decodable, Sendable { case newSession = "new_session", resumeRequiresValidation = "resume_requires_validation" }
    public let agentId: String
    public let savedProvider: String
    public let activeProvider: String?
    public let provider: String
    public let state: State
    public let available: Bool
    public let availabilityMeaning: String
    public let instructions: Instructions
    public let instructionScope: String
    public let targetRuntime: Runtime
    /// Preserve unknown refusal codes; they still block Save.
    public let blocked: String?
    public let canSave: Bool
    public let historyRetained: Bool
    public let contextTransferred: Bool
    public let nextStart: NextStart
    public let settingsReset: [String]

    /// A contradictory or unsupported response cannot grant a write.
    /// This says nothing about authentication, quota, skills or full MCP compatibility.
    public var permitsSave: Bool {
        canSave && blocked == nil && state == .sleeping && activeProvider == nil
            && available && availabilityMeaning == "local_cli_only"
            && instructions == .equivalent && instructionScope == "native_primary_only"
            && historyRetained && !contextTransferred
            && !agentId.isEmpty && !provider.isEmpty && !savedProvider.isEmpty
    }
}

nonisolated public struct AnnexProviderPreview: Decodable, Sendable, Equatable {
    public let outcome: AnnexProviderOutcome
    /// Opaque precondition. Forward unchanged; never interpret or display it.
    public let expectedState: String
    public init(from decoder: Decoder) throws {
        outcome = try AnnexProviderOutcome(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expectedState = try c.decode(String.self, forKey: .expectedState)
        guard !expectedState.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .expectedState, in: c, debugDescription: "Missing provider precondition")
        }
    }
    private enum CodingKeys: String, CodingKey { case expectedState }
}

/// A changed result has no reusable token. Already-selected preserves its preview.
nonisolated public enum AnnexProviderChangeResult: Decodable, Sendable, Equatable {
    case changed(AnnexProviderOutcome)
    case alreadySelected(AnnexProviderPreview)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "changed":
            let outcome = try AnnexProviderOutcome(from: decoder)
            guard outcome.savedProvider == outcome.provider, outcome.state == .sleeping,
                  outcome.activeProvider == nil, outcome.nextStart == .newSession else {
                throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Inconsistent provider change result")
            }
            self = .changed(outcome)
        case "already_selected": self = .alreadySelected(try AnnexProviderPreview(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Unsupported provider change result")
        }
    }
    private enum CodingKeys: String, CodingKey { case status }
}

/// Only an affirmative stopped result acknowledges exit plus session capture.
nonisolated public struct AnnexStoppedAcknowledgment: Decodable, Sendable, Equatable {
    public let agentId: String
    public let stopRequested: Bool
    public let state: String?
    public let stopped: Bool?
    public var confirmsSleep: Bool { !agentId.isEmpty && stopRequested && stopped == true && state == "sleeping" }
}
