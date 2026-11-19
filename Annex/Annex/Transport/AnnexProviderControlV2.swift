import Foundation

/// Opt-in desktop contract c4cdbacc. These values do not change providerControl v1.
nonisolated public struct AnnexManagedProviderPlatform: Decodable, Sendable, Equatable {
    public let current: String
    public let supported: Bool
    public let supportedPlatforms: [String]
    public let refusalCode: String
    public var permitsManaged: Bool {
        supported && ["darwin", "linux"].contains(current)
            && Set(supportedPlatforms) == Set(["darwin", "linux"])
            && refusalCode == "managed_platform_unsupported"
    }
}

nonisolated public struct AnnexProviderApplyV2Capability: Decodable, Sendable, Equatable {
    public let version: Int
    public let requestContractVersion: Int
    public let preview: String
    public let change: String
    public let selection: String
    public let applyStartsAgent: Bool
    public let managedDelivery: String
    public let managedPlatform: AnnexManagedProviderPlatform?
    public var isSupported: Bool {
        version == 2 && requestContractVersion == 2 && preview == "agent.providerPreview"
            && change == "agent.providerChange" && selection == "tagged_model_nullable_effort"
            && !applyStartsAgent && managedDelivery == "codex_terminal_no_skills"
    }
}

nonisolated public struct AnnexProviderStartV2Capability: Decodable, Sendable, Equatable {
    public let version: Int
    public let requestContractVersion: Int
    public let command: String
    public let requiredPreconditions: [String]
    public let managedDelivery: String
    public let managedPlatform: AnnexManagedProviderPlatform?
    public let creationEvidence: String
    public var isSupported: Bool {
        version == 2 && requestContractVersion == 2 && command == "agent.start"
            && Set(requiredPreconditions) == Set(["expectedProvider", "expectedNextWake", "expectedState"])
            && requiredPreconditions.count == 3 && managedDelivery == "codex_terminal_no_skills"
            && creationEvidence == "pty_created_selection" && managedPlatform?.permitsManaged == true
    }
}

nonisolated private struct ProviderV2Key: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
nonisolated private func providerV2Keys(_ decoder: Decoder, allowed: Set<String>, required: Set<String>) throws {
    let c = try decoder.container(keyedBy: ProviderV2Key.self)
    let keys = Set(c.allKeys.map(\.stringValue))
    guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Incomplete or unsupported provider v2 value"))
    }
}

/// Omission preserves intent differently from an explicit provider-default/null choice.
nonisolated public struct AnnexProviderSelectionV2: Codable, Sendable, Equatable {
    public enum Model: Codable, Sendable, Equatable {
        case selected(String), providerDefault
        private enum CodingKeys: String, CodingKey { case kind, id }
        public init(from decoder: Decoder) throws {
            try providerV2Keys(decoder, allowed: ["kind", "id"], required: ["kind"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "selected":
                let id = try c.decode(String.self, forKey: .id)
                guard !id.isEmpty, id != "default", id.count <= 256 else {
                    throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid selected model")
                }
                self = .selected(id)
            case "provider_default":
                guard !c.contains(.id) else {
                    throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A default choice has no selected ID")
                }
                self = .providerDefault
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported model choice")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .selected(let id):
                guard !id.isEmpty, id != "default", id.count <= 256 else { throw AnnexTransportError.malformedResponse }
                try c.encode("selected", forKey: .kind); try c.encode(id, forKey: .id)
            case .providerDefault: try c.encode("provider_default", forKey: .kind)
            }
        }
    }
    public enum Effort: Sendable, Equatable { case omitted, clear, selected(String) }
    public let model: Model?
    public let effort: Effort
    public init(model: Model? = nil, effort: Effort = .omitted) { self.model = model; self.effort = effort }
    private enum CodingKeys: String, CodingKey { case contractVersion, model, effort }
    public init(from decoder: Decoder) throws {
        try providerV2Keys(decoder, allowed: ["contractVersion", "model", "effort"], required: ["contractVersion"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .contractVersion) == 2 else { throw AnnexTransportError.malformedResponse }
        model = c.contains(.model) ? try c.decode(Model.self, forKey: .model) : nil
        if !c.contains(.effort) { effort = .omitted }
        else if try c.decodeNil(forKey: .effort) { effort = .clear }
        else {
            let value = try c.decode(String.self, forKey: .effort)
            guard !value.isEmpty, value.count <= 256 else { throw AnnexTransportError.malformedResponse }
            effort = .selected(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .contractVersion)
        try c.encodeIfPresent(model, forKey: .model)
        switch effort {
        case .omitted: break
        case .clear: try c.encodeNil(forKey: .effort)
        case .selected(let value):
            guard !value.isEmpty, value.count <= 256 else { throw AnnexTransportError.malformedResponse }
            try c.encode(value, forKey: .effort)
        }
    }
    public var fields: [String: AnnexJSON] {
        get throws {
            guard case .object(let fields) = try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(self)) else {
                throw AnnexTransportError.malformedResponse
            }
            return fields
        }
    }
}

/// Exact nullable values and source are echoed to Start; null keys must not disappear.
nonisolated public struct AnnexProviderNextWakeV2: Codable, Sendable, Equatable {
    public struct Value: Codable, Sendable, Equatable {
        public enum Source: String, Codable, Sendable { case agent, providerDefault = "provider_default" }
        public let value: String?
        public let source: Source
        private enum CodingKeys: String, CodingKey { case value, source }
        public init(from decoder: Decoder) throws {
            try providerV2Keys(decoder, allowed: ["value", "source"], required: ["value", "source"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.decodeIfPresent(String.self, forKey: .value)
            source = try c.decode(Source.self, forKey: .source)
            guard (source == .providerDefault ? value == nil : value?.isEmpty == false) else { throw AnnexTransportError.malformedResponse }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
            try c.encode(source, forKey: .source)
        }
    }
    public let provider: String
    public let providerOverride: String?
    public let model: Value
    public let effort: Value
    private enum CodingKeys: String, CodingKey { case provider, providerOverride, model, effort }
    public init(from decoder: Decoder) throws {
        try providerV2Keys(decoder, allowed: ["provider", "providerOverride", "model", "effort"], required: ["provider", "providerOverride", "model", "effort"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        providerOverride = try c.decodeIfPresent(String.self, forKey: .providerOverride)
        model = try c.decode(Value.self, forKey: .model); effort = try c.decode(Value.self, forKey: .effort)
        guard !provider.isEmpty, providerOverride?.isEmpty != true else { throw AnnexTransportError.malformedResponse }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        if let providerOverride { try c.encode(providerOverride, forKey: .providerOverride) } else { try c.encodeNil(forKey: .providerOverride) }
        try c.encode(model, forKey: .model); try c.encode(effort, forKey: .effort)
    }
    public var json: AnnexJSON { get throws { try JSONDecoder().decode(AnnexJSON.self, from: JSONEncoder().encode(self)) } }
}

nonisolated public struct AnnexProviderContractV2: Decodable, Sendable, Equatable {
    public struct Target: Decodable, Sendable, Equatable { public let agentId: String }
    public struct Result: Decodable, Sendable, Equatable {
        public let status: String
        public let persisted: Bool
        public let started: Bool
    }
    public struct Running: Decodable, Sendable, Equatable {
        public let provider: String?
        public let evidence: String
        public let model: String?
        public let effort: String?
    }
    public let version: Int
    public let target: Target
    public let selection: AnnexProviderSelectionV2
    public let current: AnnexProviderNextWakeV2
    public let saved: AnnexProviderNextWakeV2
    public let proposed: AnnexProviderNextWakeV2
    public let result: Result
    public let running: Running
}

nonisolated public struct AnnexProviderNextWakePermissionV2: Decodable, Sendable, Equatable {
    public let state: String
    public let expectedState: String?
    public let code: String?
    public var readyToken: String? {
        guard state == "ready", code == nil, let expectedState, !expectedState.isEmpty, expectedState.count <= 256 else { return nil }
        return expectedState
    }
}

nonisolated public struct AnnexProviderPreviewV2: Decodable, Sendable, Equatable {
    public struct Delivery: Decodable, Sendable, Equatable {
        public let nativeInstructions: String
        public let skills: String
        public let mcp: String
        public let nextWake: String
        public let loaded: Bool
        public var isAdmittedUnloaded: Bool {
            nativeInstructions == "prepared_on_apply" && skills == "none_supported" && mcp == "launch_flags"
                && ["blocked", "revalidation_required"].contains(nextWake) && !loaded
        }
    }
    public let preview: AnnexProviderPreview
    public let contract: AnnexProviderContractV2
    public let delivery: Delivery?
    public let managedPreparation: String?
    private enum CodingKeys: String, CodingKey { case contract, delivery, managedPreparation }
    public init(from decoder: Decoder) throws {
        preview = try AnnexProviderPreview(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contract = try c.decode(AnnexProviderContractV2.self, forKey: .contract)
        delivery = try c.decodeIfPresent(Delivery.self, forKey: .delivery)
        managedPreparation = try c.decodeIfPresent(String.self, forKey: .managedPreparation)
    }
    public func matches(agent: String, provider: String, selection: AnnexProviderSelectionV2) -> Bool {
        contract.version == 2 && contract.target.agentId == agent && preview.outcome.agentId == agent
            && preview.outcome.provider == provider && contract.proposed.provider == provider
            && contract.selection == selection && contract.result.status == "preview" && !contract.result.persisted
            && !contract.result.started && contract.saved == contract.current
            && preview.outcome.savedProvider == contract.saved.provider
            && contract.running.provider == nil && contract.running.evidence == "none"
            && contract.running.model == nil && contract.running.effort == nil
    }
    public func permitsApply(capability: AnnexProviderApplyV2Capability) -> Bool {
        let value = preview.outcome
        guard matches(agent: value.agentId, provider: value.provider, selection: contract.selection),
              capability.isSupported, value.canSave, value.blocked == nil, value.state == .sleeping,
              value.activeProvider == nil, value.available, value.availabilityMeaning == "local_cli_only",
              value.instructions == .equivalent, value.historyRetained, !value.contextTransferred else { return false }
        if value.instructionScope == "native_primary_only" { return delivery == nil && managedPreparation == nil }
        return value.instructionScope == "managed_composition" && capability.managedPlatform?.permitsManaged == true
            && value.provider == "codex-cli" && value.targetRuntime == .terminal
            && delivery?.isAdmittedUnloaded == true && ["prepare", "keep"].contains(managedPreparation ?? "")
    }
}

nonisolated public extension AnnexCommandReceipt {
    /// These are only interpreted by an explicitly negotiated v2 caller. Missing
    /// remains unknown; malformed evidence throws instead of becoming permission.
    var providerTransitionV2: AnnexProviderTransitionV2? { get throws { try transition?.decode(AnnexProviderTransitionV2.self) } }
    var providerStartEvidenceV2: AnnexProviderStartReceiptV2? { get throws { try contract?.decode(AnnexProviderStartReceiptV2.self) } }
    var providerPlatformV2: AnnexManagedProviderPlatform? { get throws { try managedPlatform?.decode(AnnexManagedProviderPlatform.self) } }
}

nonisolated public struct AnnexProviderApplyReceiptV2: Decodable, Sendable, Equatable {
    public let status: String
    public let outcome: AnnexProviderOutcome
    public let contract: AnnexProviderContractV2
    public let nextWake: AnnexProviderNextWakePermissionV2?
    private enum CodingKeys: String, CodingKey { case status, contract, nextWake }
    public init(from decoder: Decoder) throws {
        outcome = try AnnexProviderOutcome(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        contract = try c.decode(AnnexProviderContractV2.self, forKey: .contract)
        nextWake = try c.decodeIfPresent(AnnexProviderNextWakePermissionV2.self, forKey: .nextWake)
    }
    public func matches(_ preview: AnnexProviderPreviewV2) -> Bool {
        contract.version == 2 && contract.target == preview.contract.target && contract.selection == preview.contract.selection
            && contract.current == preview.contract.current
            && contract.proposed == preview.contract.proposed && contract.saved == preview.contract.proposed
            && ["changed", "already_selected"].contains(contract.result.status) && contract.result.persisted && !contract.result.started
            && status == contract.result.status
            && outcome.agentId == contract.target.agentId && outcome.provider == contract.saved.provider
            && outcome.savedProvider == contract.saved.provider && outcome.state == .sleeping && outcome.activeProvider == nil
            && outcome.targetRuntime == preview.preview.outcome.targetRuntime
            && outcome.instructionScope == preview.preview.outcome.instructionScope
    }
}

/// Failed Apply evidence is top-level, never a successful result inferred from HTTP409.
nonisolated public struct AnnexProviderTransitionV2: Decodable, Sendable, Equatable {
    public let status: String
    public let persisted: Bool?
    public let requestedSelectionSaved: Bool?
    public let savedUnchanged: Bool?
    public let target: AnnexProviderContractV2.Target?
    public let proposed: AnnexProviderNextWakeV2?
    public let saved: AnnexProviderNextWakeV2?
    public let savedProvider: String?
    public let savedOverrides: AnnexJSON?
    public let conflicts: [String]?
    public let nativePreparation: String?
    public let completeness: String?
    public let historyRetained: Bool?
    public let nextWake: String?
    public var isAcknowledgedConflict: Bool {
        status == "committed_state_conflict" && persisted == true && requestedSelectionSaved == false
            && nextWake == "fresh_read_and_review_required" && conflicts?.isEmpty == false
    }
}

/// Selection/observation at this command, not CLI handshake or current session/model proof.
nonisolated public struct AnnexProviderStartReceiptV2: Decodable, Sendable, Equatable {
    public struct Target: Decodable, Sendable, Equatable {
        public let agentId: String
        public let commandId: String
        public let hostEpoch: String
    }
    public struct Result: Decodable, Sendable, Equatable {
        public let configuration: String
        public let configPersistedByStart: Bool
        public let status: String
    }
    public struct Creation: Decodable, Sendable, Equatable {
        public enum State: Sendable, Equatable { case observed, notObserved, unknown }
        public let creation: String
        public let evidence: String
        public let providerSelection: String?
        public let observedAt: String?
        public var state: State {
            if creation == "observed", evidence == "pty_created", providerSelection?.isEmpty == false, observedAt?.isEmpty == false { return .observed }
            if creation == "not_observed", evidence == "unknown", providerSelection == nil, observedAt == nil { return .notObserved }
            return .unknown
        }
        public var wasObserved: Bool { state == .observed }
    }
    public struct Running: Decodable, Sendable, Equatable {
        public let state: String
        public let evidence: String
        public let providerSelection: String?
        public let appSessionId: String?
        public let nativeProviderSessionId: String?
        public let model: String?
        public let effort: String?
        public let observedAt: String
    }
    public let version: Int
    public let target: Target
    public let configured: AnnexProviderNextWakeV2
    public let result: Result
    public let start: Creation
    public let running: Running
    public func matches(agent: String, command: String, epoch: String, expected: AnnexProviderNextWakeV2) -> Bool {
        version == 2 && target.agentId == agent && target.commandId == command && target.hostEpoch == epoch
            && configured == expected && result.configuration == "verified_at_start" && !result.configPersistedByStart
            && (!start.wasObserved || start.providerSelection == expected.provider)
    }
}
