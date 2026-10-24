import Foundation
import Security

/// Inspection is not trust. This deliberately cancels the TLS challenge without
/// sending a PIN, bearer token, client certificate or HTTP application request.
/// UI must compare the returned pin with the desktop before constructing trust.
nonisolated public enum AnnexTrustProbe {
    public static func inspect(endpoint: AnnexEndpoint) async throws -> AnnexCertificatePin {
        return try await AnnexTelemetry.shared.measure(.trustInspection) {
            let delegate = ProbeDelegate(endpoint: endpoint)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do { _ = try await session.data(for: URLRequest(url: endpoint.url(path: []))) }
            catch {
                try Task.checkCancellation()
                if let pin = delegate.observedPin() { return pin }
                throw error
            }
            throw AnnexTransportError.trustRequired

        }
    }
}

nonisolated private final class ProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: AnnexEndpoint
    private let lock = NSLock()
    private var pin: AnnexCertificatePin?
    init(endpoint: AnnexEndpoint) { self.endpoint = endpoint }
    func observedPin() -> AnnexCertificatePin? { lock.withLock { pin } }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) { inspect(challenge) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) { inspect(challenge) }
    private func inspect(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == endpoint.host,
           challenge.protectionSpace.port == Int(endpoint.port),
           let trust = challenge.protectionSpace.serverTrust,
           let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first {
            let bytes = SecCertificateCopyData(leaf) as Data
            let found = try? AnnexCertificatePin(sha256: AnnexCertificatePin.digest(bytes))
            lock.withLock { pin = found }
        }
        return (.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
