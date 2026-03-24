import Foundation

/// URLSession delegate that accepts self-signed server certificates for v2 connections.
final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {

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
            AppLog.shared.warn("TLS", "Client cert requested by \(host):\(port) — skipping (no mTLS yet)")
            return (.performDefaultHandling, nil)
        }

        AppLog.shared.debug("TLS", "Unhandled auth challenge: \(method) from \(host):\(port)")
        return (.performDefaultHandling, nil)
    }
}
