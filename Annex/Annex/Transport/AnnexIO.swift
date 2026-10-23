import Foundation
import Security

nonisolated public struct AnnexHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

nonisolated public protocol AnnexWebSocket: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func ping() async throws
    func close() async
}

/// Injection boundary for deterministic protocol tests. Implementations MUST
/// honor TrustedAnnexHost before sending any credential or application bytes.
nonisolated public protocol AnnexIO: Sendable {
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse
    func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket
}

/// Pinned leaf certificate plus exact endpoint; TLS interception, DNS changes
/// and a forged certificate common name cannot replace the approved host.
nonisolated final class AnnexPinnedSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let host: TrustedAnnexHost
    let clientIdentity: AnnexClientIdentity?
    init(host: TrustedAnnexHost, clientIdentity: AnnexClientIdentity?) { self.host = host; self.clientIdentity = clientIdentity }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        authenticate(challenge)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        authenticate(challenge)
    }
    private func authenticate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            guard challenge.protectionSpace.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host.endpoint.host,
                  challenge.protectionSpace.port == Int(host.endpoint.port), let clientIdentity else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(identity: clientIdentity.securityIdentity, certificates: nil, persistence: .none))
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host.endpoint.host,
              challenge.protectionSpace.port == Int(host.endpoint.port),
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              host.certificatePin.matches(certificateDER: SecCertificateCopyData(leaf) as Data) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
    /// Even same-host redirects can transform a POST into a GET. All redirect
    /// responses are surfaced to the caller; credentials never follow redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}

nonisolated public final class PinnedAnnexIO: AnnexIO, Sendable {
    private let session: URLSession
    private let host: TrustedAnnexHost
    private let maximumResponseBytes: Int
    public init(host: TrustedAnnexHost, clientIdentity: AnnexClientIdentity? = nil, maximumResponseBytes: Int = 16 * 1024 * 1024) {
        self.host = host
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: config, delegate: AnnexPinnedSessionDelegate(host: host, clientIdentity: clientIdentity), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private func validate(_ request: URLRequest, scheme: String) throws {
        guard let url = request.url, url.scheme == scheme,
              url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host.endpoint.host,
              url.port == Int(host.endpoint.port), url.user == nil, url.password == nil else {
            throw AnnexTransportError.invalidEndpoint
        }
    }
    public func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        try validate(request, scheme: "https")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnnexTransportError.malformedResponse }
        guard response.expectedContentLength <= maximumResponseBytes else { throw AnnexTransportError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumResponseBytes else { throw AnnexTransportError.responseTooLarge }
            body.append(byte)
        }
        return AnnexHTTPResponse(status: http.statusCode, data: body)
    }
    public func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket {
        try validate(request, scheme: "wss")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumResponseBytes
        task.resume()
        return URLSessionAnnexWebSocket(task: task)
    }
}

nonisolated private final class URLSessionAnnexWebSocket: AnnexWebSocket, Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let bytes): return bytes
        case .string(let text): return Data(text.utf8)
        @unknown default: throw AnnexTransportError.malformedResponse
        }
    }
    func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw AnnexTransportError.malformedResponse }
        try await task.send(.string(text))
    }
    func ping() async throws {
        let completion = AnnexPingCompletion()
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                completion.resolve(.failure(URLError(.timedOut)))
                task.cancel(with: .goingAway, reason: nil)
            } catch { }
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                task.sendPing { error in
                    completion.resolve(error.map { .failure($0) } ?? .success(()))
                }
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
            task.cancel(with: .goingAway, reason: nil)
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Races timeout, callback and cancellation without double-resuming or relying
/// on URLSession to invoke a callback after the task has already been closed.
nonisolated final class AnnexPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let ready: Result<Void, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil as Result<Void, Error>?
        }
        if let ready { continuation.resume(with: ready) }
    }
    func resolve(_ result: Result<Void, Error>) {
        let waiting = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Void, Error>? }
            self.result = result
            let waiting = continuation; continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }
}
