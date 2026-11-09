import Foundation

/// A machine-qualified agent reference (`docs/annex-network-phone.md` §Agent addresses, desktop `agent-address.ts`):
/// `<agentId>@<machine fingerprint>`. No machine means the desktop the reference came from or goes to. Agent ids
/// never contain `@`.
nonisolated public struct AnnexAgentAddress: Sendable, Hashable {
    public let agentID: String
    /// The identity fingerprint of the agent's machine, lowercased. Nil: the desktop in context.
    public let machine: String?

    public init(agentID: String, machine: String? = nil) {
        self.agentID = agentID; self.machine = machine?.lowercased()
    }

    /// Reads a reference. A plain id, or anything without a well-formed fingerprint after the last `@`, is unqualified.
    public init(parsing reference: String) {
        if let at = reference.lastIndex(of: "@"), at > reference.startIndex {
            let machine = String(reference[reference.index(after: at)...])
            if Self.isMachineFingerprint(machine) {
                self.init(agentID: String(reference[..<at]), machine: machine)
                return
            }
        }
        self.init(agentID: reference)
    }

    /// The bare id without a machine, otherwise `agentId@machine`.
    public var formatted: String { machine.map { "\(agentID)@\($0)" } ?? agentID }

    /// Whether the reference names a machine other than `host` (a pinned identity fingerprint).
    public func isElsewhere(than host: String) -> Bool { machine.map { $0 != host.lowercased() } ?? false }

    /// 16 to 32 colon-separated hex bytes, as the desktop checks.
    public static func isMachineFingerprint(_ value: String) -> Bool {
        let bytes = value.split(separator: ":", omittingEmptySubsequences: false)
        return (16...32).contains(bytes.count) && bytes.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }
}

/// The desktop a snapshot comes from (`snapshot.machine`). Its fingerprint must be the pinned host's identity.
nonisolated public struct AnnexMachine: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let name: String
    public init(fingerprint: String, name: String) { self.fingerprint = fingerprint; self.name = name }
}

/// `capabilities.agentAddress` v1: commands take addresses and refuse other machines' with `wrong_machine`.
nonisolated public struct AnnexAgentAddressCapability: Decodable, Sendable, Equatable {
    public static let wrongMachine = "wrong_machine"
    public let version: Int
    public let format: String
    public let snapshotField: String
    public let wrongMachineCode: String
    public var isSupported: Bool {
        version == 1 && format == "{agentId}@{machine}" && snapshotField == "machine" && wrongMachineCode == Self.wrongMachine
    }
}
