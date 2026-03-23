import Foundation

/// URLSession delegate that accepts self-signed server certificates for v2 connections.
final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                AppLog.shared.error("TLS", "No server trust for \(host) — cancelling")
                return (.cancelAuthenticationChallenge, nil)
            }
            AppLog.shared.debug("TLS", "Accepting self-signed cert from \(host)")
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        if method == NSURLAuthenticationMethodClientCertificate {
            AppLog.shared.debug("TLS", "Client cert requested by \(host) — skipping (no mTLS)")
            return (.performDefaultHandling, nil)
        }

        AppLog.shared.debug("TLS", "Unhandled auth challenge: \(method) from \(host)")
        return (.performDefaultHandling, nil)
    }
}
