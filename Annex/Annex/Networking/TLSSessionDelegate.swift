import Foundation
import Security

/// URLSession delegate that handles both server trust (self-signed certs)
/// and client certificate presentation (mTLS) for v2 connections.
final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    /// The client identity to present for mTLS. When nil, client cert
    /// challenges are handled with default behavior (no cert).
    private let clientIdentity: SecIdentity?

    /// Base64-encoded server public key for certificate pinning.
    /// When nil, pinning is skipped (migration: servers paired before
    /// this feature may not have a stored key).
    private let expectedPublicKeyBase64: String?

    init(clientIdentity: SecIdentity? = nil, expectedPublicKeyBase64: String? = nil) {
        self.clientIdentity = clientIdentity
        self.expectedPublicKeyBase64 = expectedPublicKeyBase64
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        await AppLog.shared.debug("TLS", "Auth challenge: method=\(method) host=\(host):\(port)")

        if method == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                await AppLog.shared.error("TLS", "No server trust for \(host):\(port) — cancelling")
                return (.cancelAuthenticationChallenge, nil)
            }

            // Certificate pinning: verify the server's public key matches
            if let expectedKey = expectedPublicKeyBase64 {
                guard let presentedKey = Self.extractPublicKeyBase64(from: serverTrust) else {
                    await AppLog.shared.error("TLS", "Cannot extract public key from \(host):\(port) — rejecting")
                    return (.cancelAuthenticationChallenge, nil)
                }
                guard presentedKey == expectedKey else {
                    await AppLog.shared.error("TLS", "Public key mismatch for \(host):\(port) — rejecting (possible MITM)")
                    return (.cancelAuthenticationChallenge, nil)
                }
                await AppLog.shared.info("TLS", "Public key pinning verified for \(host):\(port)")
            } else {
                await AppLog.shared.info("TLS", "No pinned key for \(host):\(port) — skipping pin check (legacy server)")
            }

            let certCount = SecTrustGetCertificateCount(serverTrust)
            await AppLog.shared.info("TLS", "Accepting cert from \(host):\(port) (\(certCount) cert(s) in chain)")
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = clientIdentity {
                // Extract the certificate from the identity to include in the chain
                var certRef: SecCertificate?
                let copyStatus = SecIdentityCopyCertificate(identity, &certRef)
                let certs: [Any]? = (copyStatus == errSecSuccess && certRef != nil) ? [certRef!] : nil
                await AppLog.shared.info("TLS", "Presenting client certificate to \(host):\(port) (hasCertChain=\(certs != nil))")
                let credential = URLCredential(
                    identity: identity,
                    certificates: certs,
                    persistence: .forSession
                )
                return (.useCredential, credential)
            } else {
                await AppLog.shared.warn("TLS", "Client cert requested by \(host):\(port) — no identity available")
                return (.performDefaultHandling, nil)
            }
        }

        await AppLog.shared.debug("TLS", "Unhandled auth challenge: \(method) from \(host):\(port)")
        return (.performDefaultHandling, nil)
    }

    /// Extract the base64-encoded public key from the leaf certificate in a trust chain.
    static func extractPublicKeyBase64(from trust: SecTrust) -> String? {
        guard SecTrustGetCertificateCount(trust) > 0,
              let certChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCert = certChain.first else {
            return nil
        }
        guard let publicKey = SecCertificateCopyKey(leafCert) else { return nil }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        return keyData.base64EncodedString()
    }
}
