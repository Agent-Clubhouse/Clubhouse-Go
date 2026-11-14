import Foundation
import CryptoKit
import Security

/// Full, display-only replacement from one network member. Never union replicas.
nonisolated public struct AnnexProjectLinks: Codable, Sendable, Equatable {
    public struct Reference: Codable, Hashable, Sendable {
        public var machine: String
        public var projectId: String
        public init(machine: String, projectId: String) { self.machine = machine; self.projectId = projectId }
    }
    public struct Group: Codable, Sendable, Equatable {
        public var id: String
        public var projects: [Reference]
        public var name: String?
        public init(id: String, projects: [Reference], name: String? = nil) {
            self.id = id; self.projects = projects; self.name = name
        }
    }
    public var projectLinks: [Group]
    public var projectLinksTruncated: Bool?
    public init(projectLinks: [Group], projectLinksTruncated: Bool? = nil) {
        self.projectLinks = projectLinks; self.projectLinksTruncated = projectLinksTruncated
    }
}

/// A pairing is an immutable stamp made by the desktop that accepted the join.
nonisolated public struct AnnexNetworkPairing: Codable, Sendable, Equatable {
    public let id: String
    public let joinedAt: String
    public init(id: String, joinedAt: String) { self.id = id; self.joinedAt = joinedAt }
}

nonisolated public struct AnnexNetworkCapability: Decodable, Sendable {
    public let version: Int
    public let path: String
    public let membersPath: String
    public let event: String
    public let pairField: String
    public var isSupported: Bool {
        version == 1 && path == "/api/v1/mobile/network" && membersPath == "/api/v1/mobile/network/members"
            && event == "network:changed" && pairField == "network"
    }
}

nonisolated public struct AnnexNetworkMember: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let publicKey: String?
    public let name: String
    public let icon: String?
    public let color: String?
    public let kind: String
    public let hosts: [String]
    public let port: UInt16?
    public let certFingerprint: String
    public let certPem: String?
    public let online: Bool?
    public let isSelf: Bool?
    public let joinedAt: String
    public let pairingId: String?
    private enum CodingKeys: String, CodingKey {
        case fingerprint, publicKey, name, icon, color, kind, hosts, port, certFingerprint, certPem, online, joinedAt, pairingId
        case isSelf = "self"
    }
    public var endpoints: [AnnexEndpoint] {
        guard let port, port > 0 else { return [] }
        return hosts.prefix(8).compactMap { try? .advertised(host: $0, port: port) }
    }
    func keepingPairing(id: String?, joinedAt: String) -> Self {
        .init(fingerprint: fingerprint, publicKey: publicKey, name: name, icon: icon, color: color, kind: kind,
              hosts: hosts, port: port, certFingerprint: certFingerprint, certPem: certPem, online: online,
              isSelf: isSelf, joinedAt: joinedAt, pairingId: id)
    }
    /// Only a pinned member can vouch for another member. Validate its record as
    /// well, before creating any transport or persisting trust for that desktop.
    public func trustedHost() throws -> TrustedAnnexHost {
        guard kind == "desktop", let publicKey, let certPem, let endpoint = endpoints.first,
              try AnnexPairingIdentity.fingerprint(publicKeyBase64: publicKey) == fingerprint.lowercased() else {
            throw AnnexTransportError.identityMismatch
        }
        let base64 = certPem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64), SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw AnnexTransportError.identityMismatch
        }
        let pin = try AnnexCertificatePin(sha256: certFingerprint)
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard pin.sha256 == actual else { throw AnnexTransportError.identityMismatch }
        return try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: fingerprint, verifiedCertificatePin: pin)
    }
}

nonisolated public struct AnnexNetworkRemoval: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let removedAt: String
    public let pairingId: String?
    public let joinedAt: String?
    /// #3107: compare the pairing stamp, never the phone's clock or removedAt
    /// for a stamped removal. A legacy record without an id counts as that pairing.
    public func ends(pairingID: String?, joinedAt memberJoinedAt: String) -> Bool {
        if let pairingId, let joinedAt {
            if pairingID == nil || pairingID == pairingId { return true }
            return Self.noLater(memberJoinedAt, than: joinedAt)
        }
        return Self.noLater(memberJoinedAt, than: removedAt)
    }
    private static func noLater(_ lhs: String, than rhs: String) -> Bool {
        guard let l = date(lhs), let r = date(rhs) else { return true }
        return l <= r
    }
    static func date(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

nonisolated public struct AnnexNetworkSnapshot: Codable, Sendable, Equatable {
    public let version: Int
    public let joined: Bool
    public let members: [AnnexNetworkMember]
    public let removals: [AnnexNetworkRemoval]
}

/// Stored inside the existing atomic, device-only Keychain pairing item. The
/// removal journal is copied to surviving items before a removed host is erased.
nonisolated public struct AnnexNetworkState: Codable, Sendable, Equatable {
    public var pairing: AnnexNetworkPairing
    public var serverPairing: AnnexNetworkPairing?
    public var member: AnnexNetworkMember?
    public var learned: Bool
    public var removals: [AnnexNetworkRemoval]
    /// New desktop still needs the two membership exchanges; retried after reconnect.
    public var needsIntroduction: Bool
}
