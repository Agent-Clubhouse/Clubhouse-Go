import Foundation

/// URLSession supplies network-sized Data chunks. The limit is checked before every append,
/// including chunked responses without Content-Length. State also accepts cancellation before start.
nonisolated final class AnnexFullEventDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let trust: AnnexPinnedSessionDelegate
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false
    private var cancelled = false

    init(trust: AnnexPinnedSessionDelegate, maximumBytes: Int) { self.trust = trust; self.maximumBytes = maximumBytes }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = PinnedAnnexIO.configuration(resourceTimeout: 300)
                configuration.timeoutIntervalForRequest = 300
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = request; request.timeoutInterval = 300
                let task = session.dataTask(with: request)
                let start = lock.withLock {
                    guard !cancelled else { return false }
                    self.continuation = continuation; self.session = session; self.task = task
                    return true
                }
                if start { task.resume() }
                else { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<(Data, HTTPURLResponse), Error>?, URLSession?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let result = (continuation, session)
            continuation = nil; session = nil; task = nil; body = Data()
            return result
        }
        completion.1?.invalidateAndCancel()
        completion.0?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(AnnexTransportError.malformedResponse)); return
        }
        guard response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel); finish(.failure(AnnexTransportError.responseTooLarge)); return
        }
        let accept = lock.withLock {
            guard !finished else { return false }
            self.response = response
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overLimit = lock.withLock {
            guard !finished else { return false }
            guard data.count <= maximumBytes - body.count else { return true }
            body.append(data)
            return false
        }
        if overLimit { finish(.failure(AnnexTransportError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let result = lock.withLock { () -> Result<(Data, HTTPURLResponse), Error> in
            guard let response else { return .failure(AnnexTransportError.malformedResponse) }
            return .success((body, response))
        }
        finish(result)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust.urlSession(session, didReceive: challenge)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust.urlSession(session, task: task, didReceive: challenge)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        trust.urlSession(session, task: task, didFinishCollecting: metrics)
    }
}
