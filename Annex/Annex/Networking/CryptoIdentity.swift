import Foundation
import CryptoKit

/// Manages the device's Ed25519 identity for v2 protocol pairing.
/// One identity per device, shared across all server connections.
struct CryptoIdentity {
    let privateKey: Curve25519.Signing.PrivateKey

    /// Fixed 12-byte SPKI prefix for Ed25519 public keys per RFC 8410.
    private static let spkiPrefix: [UInt8] = [
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00
    ]

    /// Public key in DER/SPKI format, base64-encoded (for pairing requests).
    var publicKeyBase64: String {
        let raw = privateKey.publicKey.rawRepresentation
        let spki = Data(Self.spkiPrefix) + raw
        return spki.base64EncodedString()
    }

    /// SHA-256 fingerprint of the SPKI public key, first 16 bytes, colon-separated hex.
    var fingerprint: String {
        let raw = privateKey.publicKey.rawRepresentation
        let spki = Data(Self.spkiPrefix) + raw
        let hash = SHA256.hash(data: spki)
        return hash.prefix(16)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")
    }

    /// Load existing identity from Keychain, or generate and persist a new one.
    static func loadOrCreate() -> CryptoIdentity {
        if let keyData = KeychainHelper.loadEd25519PrivateKey(),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            let identity = CryptoIdentity(privateKey: key)
            AppLog.shared.info("Crypto", "Loaded existing Ed25519 identity, fingerprint=\(identity.fingerprint)")
            return identity
        }

        AppLog.shared.info("Crypto", "Generating new Ed25519 identity")
        let key = Curve25519.Signing.PrivateKey()
        KeychainHelper.saveEd25519PrivateKey(key.rawRepresentation)
        let identity = CryptoIdentity(privateKey: key)
        AppLog.shared.info("Crypto", "New identity created, fingerprint=\(identity.fingerprint)")
        return identity
    }
}
