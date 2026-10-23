import Foundation
import CryptoKit

public enum AnnexTransportError: Error, Sendable, Equatable {
    case invalidEndpoint
    case invalidPin
    case trustRequired
    case identityMismatch
    case credentialMissing
    case unauthorized
    case forbidden
    case unsupportedCapability(String)
    case rejected(status: Int, code: String?)
    case malformedResponse
    case responseTooLarge
    case queueOverflow
    case disconnected
    case commandOutcomeUnknown(commandID: String)
    case commandInFlight
    case duplicateCommandConflict
    case persistenceFailed(Int32)
}

/// An address is a route to a host, never that host's identity. Tailscale addresses
/// use the same pinned TLS transport as LAN addresses; no VPN privileges required.
public struct AnnexEndpoint: Hashable, Codable, Sendable {
    public enum Route: String, Codable, Sendable { case localNetwork, tailscale, manual, gateway }
    public let host: String
    public let port: UInt16
    public let route: Route

    public init(host: String, port: UInt16, route: Route = .manual) throws {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard port != 0, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains(where: { "/\\?#@".contains($0) }),
              !host.contains("://"), !host.contains("%25") else { throw AnnexTransportError.invalidEndpoint }
        self.host = host.lowercased()
        self.port = port
        self.route = route
        guard let url = try? url(path: []), url.host != nil else { throw AnnexTransportError.invalidEndpoint }
    }

    /// Path components are individually encoded, including slash, percent and query characters.
    public func url(path: [String], query: [URLQueryItem] = [], webSocket: Bool = false) throws -> URL {
        var components = URLComponents()
        components.scheme = webSocket ? "wss" : "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = Int(port)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AnnexTransportError.invalidEndpoint
        }
        components.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AnnexTransportError.invalidEndpoint }
        return url
    }

    private enum CodingKeys: String, CodingKey { case host, port, route }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(String.self, forKey: .host), port: c.decode(UInt16.self, forKey: .port), route: c.decode(Route.self, forKey: .route))
    }
}

public struct AnnexCertificatePin: Hashable, Codable, Sendable {
    /// Full SHA-256 of leaf certificate DER; distinct from the truncated Ed25519 host fingerprint.
    public let sha256: String
    public init(sha256: String) throws {
        let normalized = sha256.replacingOccurrences(of: ":", with: "").lowercased()
        guard normalized.count == 64, normalized.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw AnnexTransportError.invalidPin
        }
        self.sha256 = normalized
    }
    public func matches(certificateDER: Data) -> Bool {
        Self.digest(certificateDER) == sha256
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private enum CodingKeys: String, CodingKey { case sha256 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sha256: c.decode(String.self, forKey: .sha256))
    }
}

/// Construct only after the user verifies BOTH fingerprints on the desktop or
/// scans an authenticated pairing invitation. Bonjour TXT is never proof of trust.
public struct TrustedAnnexHost: Hashable, Codable, Sendable {
    public let endpoint: AnnexEndpoint
    public let hostID: String
    public let certificatePin: AnnexCertificatePin
    public init(endpoint: AnnexEndpoint, verifiedHostID: String, verifiedCertificatePin: AnnexCertificatePin) throws {
        let id = verifiedHostID.lowercased()
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 16, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isASCII && $0.isHexDigit }) }) else {
            throw AnnexTransportError.identityMismatch
        }
        self.endpoint = endpoint
        self.hostID = id
        self.certificatePin = verifiedCertificatePin
    }
    private enum CodingKeys: String, CodingKey { case endpoint, hostID, certificatePin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: c.decode(AnnexEndpoint.self, forKey: .endpoint), verifiedHostID: c.decode(String.self, forKey: .hostID), verifiedCertificatePin: c.decode(AnnexCertificatePin.self, forKey: .certificatePin))
    }
}
