import Foundation
import Security

/// Immutable Security references can be used concurrently. Keys are generated
/// in process memory (kSecAttrIsPermanent=false), never in the user's Keychain.
nonisolated public final class AnnexClientIdentity: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let securityIdentity: SecIdentity
    private let privateKey: SecKey
    public let certificateDER: Data
    public let pairingIdentity: AnnexPairingIdentity
    public var fingerprint: String { get throws { try AnnexPairingIdentity.fingerprint(publicKeyBase64: pairingIdentity.publicKeyBase64) } }
    public var certificateFingerprint: String { AnnexCertificatePin.digest(certificateDER) }
    public var description: String { "AnnexClientIdentity(<redacted>)" }
    public var debugDescription: String { description }

    private init(identity: SecIdentity, privateKey: SecKey, certificateDER: Data, pairingIdentity: AnnexPairingIdentity) {
        self.privateKey = privateKey; self.securityIdentity = identity; self.certificateDER = certificateDER; self.pairingIdentity = pairingIdentity
    }

    struct Archive: Codable, Sendable {
        let certificateDER: Data
        let rsaPrivateKey: Data
        let ed25519PrivateKey: Data
    }
    func archive() throws -> Archive {
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw AnnexTransportError.identityMismatch
        }
        return Archive(certificateDER: certificateDER, rsaPrivateKey: bytes, ed25519PrivateKey: pairingIdentity.privateKeyData)
    }
    static func restore(_ archive: Archive) throws -> AnnexClientIdentity {
        let pairing = try AnnexPairingIdentity(privateKeyData: archive.ed25519PrivateKey)
        let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: pairing.publicKeyBase64)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(archive.rsaPrivateKey as CFData, attributes as CFDictionary, &error),
              let cert = SecCertificateCreateWithData(nil, archive.certificateDER as CFData),
              let identity = SecIdentityCreate(nil, cert, key) else { throw AnnexTransportError.identityMismatch }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(cert, &commonName) == errSecSuccess,
              commonName as String? == fingerprint else { throw AnnexTransportError.identityMismatch }
        return AnnexClientIdentity(identity: identity, privateKey: key, certificateDER: archive.certificateDER, pairingIdentity: pairing)
    }

    public static func ephemeral(now: Date = Date()) throws -> AnnexClientIdentity {
        let pairing = AnnexPairingIdentity()
        let name = try AnnexPairingIdentity.fingerprint(publicKeyBase64: pairing.publicKeyBase64)
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeySizeInBits as String: 2048,
                                         kSecAttrIsPermanent as String: false]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw AnnexTransportError.identityMismatch
        }
        // X.509 encoding only; cryptographic key generation and signatures are
        // performed by Security.framework, never custom cryptography.
        let algorithm = AnnexClientDER.sequence(AnnexClientDER.oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b]) + AnnexClientDER.null)
        let rsaAlgorithm = AnnexClientDER.sequence(AnnexClientDER.oid([0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01]) + AnnexClientDER.null)
        let distinguishedName = AnnexClientDER.sequence(AnnexClientDER.tag(0x31, AnnexClientDER.sequence(AnnexClientDER.oid([0x55,0x04,0x03]) + AnnexClientDER.tag(0x0c, Data(name.utf8)))))
        var serial = Data(count: 16)
        let status = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AnnexTransportError.identityMismatch }
        serial[0] = (serial[0] & 0x7f) | 0x01
        let validity = AnnexClientDER.sequence(AnnexClientDER.time(now.addingTimeInterval(-300)) + AnnexClientDER.time(now.addingTimeInterval(365 * 86400)))
        let tbs = AnnexClientDER.sequence(AnnexClientDER.tag(0xa0, AnnexClientDER.tag(0x02, Data([2])))
            + AnnexClientDER.tag(0x02, serial) + algorithm + distinguishedName + validity + distinguishedName
            + AnnexClientDER.sequence(rsaAlgorithm + AnnexClientDER.bitString(publicBytes)))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw AnnexTransportError.identityMismatch
        }
        let bytes = AnnexClientDER.sequence(tbs + algorithm + AnnexClientDER.bitString(signature))
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else { throw AnnexTransportError.identityMismatch }
        return AnnexClientIdentity(identity: identity, privateKey: key, certificateDER: bytes, pairingIdentity: pairing)
    }
}

nonisolated private enum AnnexClientDER {
    static func tag(_ tag: UInt8, _ contents: Data) -> Data {
        var length = Data()
        if contents.count < 128 { length.append(UInt8(contents.count)) }
        else {
            var count = contents.count
            var bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + contents
    }
    static func sequence(_ contents: Data) -> Data { tag(0x30, contents) }
    static func oid(_ contents: [UInt8]) -> Data { tag(0x06, Data(contents)) }
    static let null = Data([0x05,0x00])
    static func bitString(_ contents: Data) -> Data { tag(0x03, Data([0]) + contents) }
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tag(0x18, Data(formatter.string(from: date).utf8))
    }
}
