import Foundation
import Security

/// Manages an RSA-2048 client certificate for mTLS authentication with v2 servers.
///
/// The v2 server requires a client TLS certificate whose CN (Common Name) equals
/// the device's Ed25519 fingerprint. The server extracts the CN during the TLS
/// handshake and uses it to look up the peer in its authorized controller list.
///
/// Usage: call `loadOrCreate(fingerprint:)` during connection setup, then pass
/// the resulting `SecIdentity` to `TLSSessionDelegate`.
enum MTLSIdentity {
    private static let keyTag = "com.Agent-Clubhouse.Go.mTLS-RSA"
    private static let certLabel = "com.Agent-Clubhouse.Go.mTLS-Cert"

    // MARK: - Public API

    /// Load an existing mTLS identity from Keychain, or generate a new one.
    /// The certificate CN is set to the given Ed25519 fingerprint.
    static func loadOrCreate(fingerprint: String) -> SecIdentity? {
        // Try loading existing identity first
        if let identity = loadIdentity() {
            AppLog.shared.info("mTLS", "Loaded existing mTLS identity from Keychain")
            return identity
        }

        AppLog.shared.info("mTLS", "Generating new RSA-2048 keypair and self-signed cert (CN=\(fingerprint))")

        // Generate RSA-2048 keypair in Keychain
        guard let privateKey = generateRSAKeyPair() else {
            AppLog.shared.error("mTLS", "Failed to generate RSA keypair")
            return nil
        }

        // Get the public key DER for embedding in the certificate
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            AppLog.shared.error("mTLS", "Failed to export RSA public key")
            return nil
        }

        // Build self-signed X.509 certificate
        guard let certDER = buildSelfSignedCert(
            commonName: fingerprint,
            publicKeyDER: publicKeyData,
            privateKey: privateKey
        ) else {
            AppLog.shared.error("mTLS", "Failed to build self-signed certificate")
            return nil
        }

        // Store certificate in Keychain
        guard storeCertificate(certDER) else {
            AppLog.shared.error("mTLS", "Failed to store certificate in Keychain")
            return nil
        }

        // Load the identity (Keychain matches cert + private key by public key hash)
        guard let identity = loadIdentity() else {
            AppLog.shared.error("mTLS", "Failed to load identity after creation")
            return nil
        }

        AppLog.shared.info("mTLS", "mTLS identity created successfully")
        return identity
    }

    /// Delete any existing mTLS identity from Keychain.
    static func deleteIdentity() {
        // Delete private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ]
        SecItemDelete(keyQuery as CFDictionary)

        // Delete certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
        ]
        SecItemDelete(certQuery as CFDictionary)
        AppLog.shared.info("mTLS", "Deleted mTLS identity from Keychain")
    }

    // MARK: - Key Generation

    private static func generateRSAKeyPair() -> SecKey? {
        // Delete any existing key with this tag first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            ],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            AppLog.shared.error("mTLS", "SecKeyCreateRandomKey failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }

        AppLog.shared.debug("mTLS", "RSA-2048 keypair generated")
        return privateKey
    }

    // MARK: - Certificate Generation

    /// Build a minimal self-signed X.509 v3 certificate in DER format.
    /// The certificate has CN set to the given commonName (Ed25519 fingerprint).
    static func buildSelfSignedCert(
        commonName: String,
        publicKeyDER: Data,
        privateKey: SecKey
    ) -> Data? {
        let now = Date()
        let tenYears = Calendar.current.date(byAdding: .year, value: 10, to: now)!

        // Build TBSCertificate
        let tbsCert = DER.sequence([
            // version [0] EXPLICIT INTEGER 2 (v3)
            DER.contextTag(0, constructed: true, content: DER.integer(2)),
            // serialNumber — random 8-byte positive integer
            DER.integer(randomSerialNumber()),
            // signature algorithm: sha256WithRSAEncryption
            sha256WithRSAEncryptionAlgorithm(),
            // issuer: CN=commonName
            distinguishedName(cn: commonName),
            // validity
            DER.sequence([
                DER.utcTime(now),
                DER.utcTime(tenYears),
            ]),
            // subject: CN=commonName (same as issuer for self-signed)
            distinguishedName(cn: commonName),
            // subjectPublicKeyInfo (RSA)
            rsaPublicKeyInfo(publicKeyDER),
        ])

        // Sign the TBSCertificate
        guard let signature = sign(data: tbsCert, with: privateKey) else {
            AppLog.shared.error("mTLS", "Failed to sign TBSCertificate")
            return nil
        }

        // Build complete Certificate
        let cert = DER.sequence([
            tbsCert,
            sha256WithRSAEncryptionAlgorithm(),
            DER.bitString(signature),
        ])

        AppLog.shared.debug("mTLS", "Built self-signed cert: \(cert.count) bytes DER")
        return cert
    }

    // MARK: - Keychain Operations

    private static func storeCertificate(_ certDER: Data) -> Bool {
        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            AppLog.shared.error("mTLS", "SecCertificateCreateWithData failed — invalid DER?")
            return false
        }

        // Delete existing cert with same label
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecAttrLabel as String: certLabel,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.shared.error("mTLS", "SecItemAdd cert failed: OSStatus \(status)")
            return false
        }
        return true
    }

    private static func loadIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecReturnRef as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            AppLog.shared.debug("mTLS", "No identity found in Keychain (status=\(status))")
            return nil
        }
        // swiftlint:disable:next force_cast
        return (result as! SecIdentity)
    }

    // MARK: - Signing

    private static func sign(data: Data, with privateKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            AppLog.shared.error("mTLS", "RSA signature failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }
        return signature
    }

    // MARK: - Helpers

    private static func randomSerialNumber() -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] &= 0x7F // Ensure positive (clear high bit)
        if bytes[0] == 0 { bytes[0] = 1 } // Ensure non-zero leading byte
        return Data(bytes)
    }

    private static func sha256WithRSAEncryptionAlgorithm() -> Data {
        // SEQUENCE { OID 1.2.840.113549.1.1.11, NULL }
        DER.sequence([
            DER.oid([1, 2, 840, 113549, 1, 1, 11]),
            DER.null(),
        ])
    }

    private static func distinguishedName(cn: String) -> Data {
        // SEQUENCE { SET { SEQUENCE { OID 2.5.4.3, UTF8String cn } } }
        DER.sequence([
            DER.set([
                DER.sequence([
                    DER.oid([2, 5, 4, 3]),
                    DER.utf8String(cn),
                ]),
            ]),
        ])
    }

    private static func rsaPublicKeyInfo(_ publicKeyDER: Data) -> Data {
        // subjectPublicKeyInfo: SEQUENCE { algorithm, BIT STRING { publicKey } }
        // The publicKeyDER from SecKeyCopyExternalRepresentation is PKCS#1 RSAPublicKey
        DER.sequence([
            DER.sequence([
                DER.oid([1, 2, 840, 113549, 1, 1, 1]), // rsaEncryption
                DER.null(),
            ]),
            DER.bitString(publicKeyDER),
        ])
    }
}

// MARK: - Minimal DER Encoder

/// Lightweight DER (Distinguished Encoding Rules) encoder for X.509 certificate construction.
/// Only implements the subset needed for a self-signed RSA certificate.
enum DER {
    // Tag numbers
    private static let tagInteger: UInt8 = 0x02
    private static let tagBitString: UInt8 = 0x03
    private static let tagNull: UInt8 = 0x05
    private static let tagOID: UInt8 = 0x06
    private static let tagUTF8String: UInt8 = 0x0C
    private static let tagUTCTime: UInt8 = 0x17
    private static let tagSequence: UInt8 = 0x30
    private static let tagSet: UInt8 = 0x31

    static func sequence(_ items: [Data]) -> Data {
        let content = items.reduce(Data()) { $0 + $1 }
        return tlv(tagSequence, content)
    }

    static func set(_ items: [Data]) -> Data {
        let content = items.reduce(Data()) { $0 + $1 }
        return tlv(tagSet, content)
    }

    static func integer(_ value: Int) -> Data {
        if value <= 127 {
            return tlv(tagInteger, Data([UInt8(value)]))
        }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes.first! & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tlv(tagInteger, Data(bytes))
    }

    static func integer(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        // Ensure positive encoding
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tlv(tagInteger, Data(bytes))
    }

    static func bitString(_ data: Data) -> Data {
        // BIT STRING: first byte is number of unused bits (always 0 for us)
        var content = Data([0x00])
        content.append(data)
        return tlv(tagBitString, content)
    }

    static func null() -> Data {
        Data([tagNull, 0x00])
    }

    static func utf8String(_ string: String) -> Data {
        tlv(tagUTF8String, Data(string.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date) + "Z"
        return tlv(tagUTCTime, Data(str.utf8))
    }

    static func oid(_ components: [UInt]) -> Data {
        guard components.count >= 2 else { return Data() }
        var bytes: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for i in 2..<components.count {
            bytes.append(contentsOf: encodeOIDComponent(components[i]))
        }
        return tlv(tagOID, Data(bytes))
    }

    static func contextTag(_ tag: UInt8, constructed: Bool, content: Data) -> Data {
        let tagByte: UInt8 = 0x80 | (constructed ? 0x20 : 0) | (tag & 0x1F)
        return tlv(tagByte, content)
    }

    // MARK: - TLV Encoding

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }

    private static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        }
        var bytes: [UInt8] = []
        var len = length
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        return bytes
    }

    private static func encodeOIDComponent(_ value: UInt) -> [UInt8] {
        if value < 128 {
            return [UInt8(value)]
        }
        var bytes: [UInt8] = []
        var v = value
        bytes.insert(UInt8(v & 0x7F), at: 0)
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }
}
