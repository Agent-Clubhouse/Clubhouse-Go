import Foundation
import Security

/// URLSession delegate that handles both server trust (self-signed certs)
/// and client certificate presentation (mTLS) for v2 connections.
final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    /// The client identity to present for mTLS. When nil, client cert
    /// challenges are handled with default behavior (no cert).
    private let clientIdentity: SecIdentity?

    /// Expected server Ed25519 fingerprint (colon-separated hex).
    /// Validated against the TLS certificate's Common Name (CN),
    /// which the server sets to its Ed25519 fingerprint per the v2 spec.
    /// When nil, CN validation is skipped (legacy servers).
    private let expectedServerFingerprint: String?

    init(clientIdentity: SecIdentity? = nil, expectedServerFingerprint: String? = nil) {
        self.clientIdentity = clientIdentity
        self.expectedServerFingerprint = expectedServerFingerprint
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

            // Certificate pinning: verify the TLS cert's CN matches the expected
            // server Ed25519 fingerprint (the server sets CN = fingerprint per v2 spec).
            if let expectedFingerprint = expectedServerFingerprint {
                guard let certCN = Self.extractCommonName(from: serverTrust) else {
                    await AppLog.shared.error("TLS", "Cannot extract CN from \(host):\(port) — rejecting")
                    return (.cancelAuthenticationChallenge, nil)
                }
                guard certCN == expectedFingerprint else {
                    await AppLog.shared.error("TLS", "CN mismatch for \(host):\(port) — expected \(expectedFingerprint.prefix(12))..., got \(certCN.prefix(12))... — rejecting (possible MITM)")
                    return (.cancelAuthenticationChallenge, nil)
                }
                await AppLog.shared.info("TLS", "CN fingerprint verified for \(host):\(port)")
            } else {
                await AppLog.shared.info("TLS", "No expected fingerprint for \(host):\(port) — skipping CN check (legacy server)")
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

    /// Extract the Common Name (CN) from the leaf certificate in a trust chain.
    /// The v2 server sets CN to its Ed25519 fingerprint (colon-separated hex).
    static func extractCommonName(from trust: SecTrust) -> String? {
        guard SecTrustGetCertificateCount(trust) > 0,
              let certChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCert = certChain.first else {
            return nil
        }
        // SecCertificateCopySubjectSummary returns the CN for simple certs
        guard let summary = SecCertificateCopySubjectSummary(leafCert) as String? else {
            return nil
        }
        return summary
    }
}
