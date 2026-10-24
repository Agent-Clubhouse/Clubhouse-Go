import Foundation
import CryptoKit

nonisolated public struct AnnexPairingIdentity: Sendable {
    /// Ephemeral by default. Applications may supply a separately approved key.
    private let privateKey: Curve25519.Signing.PrivateKey
    public init() { privateKey = Curve25519.Signing.PrivateKey() }
    public init(privateKeyData: Data) throws { privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) }
    private static let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    var privateKeyData: Data { privateKey.rawRepresentation }
    public var publicKeyBase64: String { (Self.spkiPrefix + privateKey.publicKey.rawRepresentation).base64EncodedString() }
    public static func fingerprint(publicKeyBase64: String) throws -> String {
        guard let bytes = Data(base64Encoded: publicKeyBase64), bytes.count == 44,
              bytes.prefix(12) == spkiPrefix else { throw AnnexTransportError.identityMismatch }
        return SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

nonisolated public enum AnnexPairingMode: String, Sendable { case session, persistent }

nonisolated public struct AnnexPairingResult: Sendable {
    public let host: TrustedAnnexHost
    public let publicKey: String
    public let alias: String
}

nonisolated public struct AnnexPairingClient: Sendable {
    private let host: TrustedAnnexHost
    private let io: any AnnexIO
    private let clientIdentity: AnnexClientIdentity
    private let credentials: any AnnexCredentialStore
    public init(host: TrustedAnnexHost, clientIdentity: AnnexClientIdentity, credentials: any AnnexCredentialStore, io: (any AnnexIO)? = nil) {
        self.host = host; self.clientIdentity = clientIdentity; self.credentials = credentials
        self.io = io ?? PinnedAnnexIO(host: host, clientIdentity: clientIdentity)
    }

    /// Explicit action after desktop trust verification. PIN and token are only
    /// carried inside pinned TLS. No fallback to the legacy HTTP pairing port.
    public func pair(pin: String, alias: String, mode: AnnexPairingMode = .session) async throws -> AnnexPairingResult {
        return try await AnnexTelemetry.shared.measure(.pairing) {
            guard !pin.isEmpty, pin.count <= 128, !alias.isEmpty, alias.count <= 128 else { throw AnnexTransportError.malformedResponse }
            struct Request: Encodable {
                let pin: String, publicKey: String, alias: String
                let icon = "smartphone"
                let color = "indigo"
                let pairingMode: String
            }
            var request = URLRequest(url: try host.endpoint.url(path: ["pair"]))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Request(pin: pin, publicKey: clientIdentity.pairingIdentity.publicKeyBase64, alias: alias, pairingMode: mode.rawValue))
            try Task.checkCancellation()
            let response = try await io.perform(request)
            try Task.checkCancellation()
            guard response.status == 200 else { throw AnnexHTTPValidation.error(response) }
            struct Response: Decodable {
                let token: String, publicKey: String, fingerprint: String, alias: String
                let tlsCertificateFingerprint: String
                let mobileProtocolVersion: Int
                let pairingMode: String
            }
            guard let result = try? JSONDecoder().decode(Response.self, from: response.data) else { throw AnnexTransportError.malformedResponse }
            guard result.mobileProtocolVersion == 1, result.pairingMode == mode.rawValue,
                  try AnnexCertificatePin(sha256: result.tlsCertificateFingerprint) == host.certificatePin else {
                throw AnnexTransportError.identityMismatch
            }
            let actual = try AnnexPairingIdentity.fingerprint(publicKeyBase64: result.publicKey)
            guard result.fingerprint.lowercased() == actual, actual == host.hostID else { throw AnnexTransportError.identityMismatch }
            let credential = try AnnexCredential(bearerToken: result.token)
            try await credentials.save(credential, for: host.hostID)
            return AnnexPairingResult(host: host, publicKey: result.publicKey, alias: result.alias)

        }
    }
}

nonisolated enum AnnexHTTPValidation {
    static func error(_ response: AnnexHTTPResponse) -> AnnexTransportError {
        switch response.status {
        case 401: return .unauthorized
        case 403: return .forbidden
        default:
            // Only known machine codes are retained, never server-provided content.
            let code = (try? JSONDecoder().decode(AnnexJSON.self, from: response.data))?["error"]?.string
            let safe = code.flatMap { $0.count <= 80 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? $0 : nil }
            return .rejected(status: response.status, code: safe)
        }
    }
}
