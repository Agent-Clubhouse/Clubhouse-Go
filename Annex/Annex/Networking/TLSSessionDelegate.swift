import Foundation

/// URLSession delegate that accepts self-signed server certificates for v2 connections.
final class TLSSessionDelegate: NSObject, URLSessionDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        return (.performDefaultHandling, nil)
    }
}
