import Foundation
@testable import ClubhouseGo

/// A URLProtocol subclass that intercepts HTTP requests for unit testing.
/// Register mock responses keyed by URL path, then inject a URLSession
/// configured with this protocol into AnnexAPIClient.
final class MockURLProtocol: URLProtocol {

    /// Thread-safe storage for registered responses.
    private static let lock = NSLock()
    private static var _handlers: [String: MockResponse] = [:]

    /// A mock HTTP response to return for a given URL path.
    struct MockResponse {
        let statusCode: Int
        let headers: [String: String]
        let data: Data?
        let error: Error?

        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            data: Data? = nil,
            error: Error? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
            self.error = error
        }

        /// Convenience for a JSON body response.
        static func json(_ json: String, statusCode: Int = 200) -> MockResponse {
            MockResponse(statusCode: statusCode, data: Data(json.utf8))
        }

        /// Convenience for a plain text body response.
        static func text(_ text: String, statusCode: Int = 200) -> MockResponse {
            MockResponse(
                statusCode: statusCode,
                headers: ["Content-Type": "text/plain"],
                data: Data(text.utf8)
            )
        }

        /// Convenience for a network error.
        static func networkError(_ error: Error = URLError(.notConnectedToInternet)) -> MockResponse {
            MockResponse(error: error)
        }
    }

    // MARK: - Registration

    /// Register a mock response for a URL path (e.g. "/api/v1/status").
    /// Path matching uses `contains` so partial paths work.
    static func register(path: String, response: MockResponse) {
        lock.lock()
        defer { lock.unlock() }
        _handlers[path] = response
    }

    /// Remove all registered handlers.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _handlers.removeAll()
    }

    private static var handlers: [String: MockResponse] {
        lock.lock()
        defer { lock.unlock() }
        return _handlers
    }

    /// Create a URLSession configured to use this mock protocol.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }

    /// Create an AnnexAPIClient wired to the mock protocol using HTTP (v2Pairing config).
    /// Uses HTTP to avoid TLS handshake issues with URLProtocol interception.
    static func mockClient(host: String = "localhost", port: UInt16 = 9999) -> AnnexAPIClient {
        AnnexAPIClient(config: .v2Pairing(host: host, pairingPort: port), session: session())
    }

    /// Create an AnnexAPIClient wired to the mock protocol for v2 (HTTPS) config.
    /// Only use for tests that need HTTPS-specific behavior (e.g. WebSocket URL construction).
    static func mockV2Client(host: String = "localhost", port: UInt16 = 9999) -> AnnexAPIClient {
        AnnexAPIClient(config: .v2(host: host, mainPort: port), session: session())
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let path = url.path
        let query = url.query

        // Find a matching handler: try exact path first, then partial match
        let mockResponse: MockResponse? = {
            let all = MockURLProtocol.handlers
            // Try path + query match first
            if let q = query {
                let fullPath = "\(path)?\(q)"
                if let r = all[fullPath] { return r }
            }
            // Try exact path
            if let r = all[path] { return r }
            // Try partial match (longest match first)
            let sorted = all.keys.sorted { $0.count > $1.count }
            for key in sorted {
                if path.contains(key) || (query != nil && "\(path)?\(query!)".contains(key)) {
                    return all[key]
                }
            }
            return nil
        }()

        guard let mock = mockResponse else {
            // No handler registered — return 404
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"error\":\"not_found\"}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // If the mock specifies a network error, fail
        if let error = mock.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: mock.headers
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = mock.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
