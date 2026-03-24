import Foundation

/// URLSession delegate that handles both server trust (self-signed certs)
/// and client certificate presentation (mTLS) for v2 connections.
final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    /// The client identity to present for mTLS. When nil, client cert
    /// challenges are handled with default behavior (no cert).
    private let clientIdentity: SecIdentity?

    init(clientIdentity: SecIdentity? = nil) {
        self.clientIdentity = clientIdentity
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        AppLog.shared.debug("TLS", "Auth challenge: method=\(method) host=\(host):\(port)")

        if method == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                AppLog.shared.error("TLS", "No server trust for \(host):\(port) — cancelling")
                return (.cancelAuthenticationChallenge, nil)
            }
            let certCount = SecTrustGetCertificateCount(serverTrust)
            AppLog.shared.info("TLS", "Accepting self-signed cert from \(host):\(port) (\(certCount) cert(s) in chain)")
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = clientIdentity {
                AppLog.shared.info("TLS", "Presenting client certificate to \(host):\(port)")
                let credential = URLCredential(
                    identity: identity,
                    certificates: nil,
                    persistence: .forSession
                )
                return (.useCredential, credential)
            } else {
                AppLog.shared.warn("TLS", "Client cert requested by \(host):\(port) — no identity available")
                return (.performDefaultHandling, nil)
            }
        }

        AppLog.shared.debug("TLS", "Unhandled auth challenge: \(method) from \(host):\(port)")
        return (.performDefaultHandling, nil)
    }
}
