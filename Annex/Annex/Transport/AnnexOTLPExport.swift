import Foundation

/// A verified-by-user OTLP/HTTP JSON traces route. This is independent of
/// Framebriar feedback and can target a collector forwarding to App Insights.
nonisolated public struct AnnexOTLPConfiguration: Codable, Sendable, Equatable {
    public let endpoint: URL
    public let backendReference: UUID
    public init(address: String, backendReference: UUID = UUID()) throws {
        guard address.utf8.count <= 2048, let url = URL(string: address), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.hasSuffix("/v1/traces"),
              AnnexTelemetryHandshake.canonicalUUID(backendReference.uuidString.lowercased()) != nil else {
            throw AnnexTransportError.invalidEndpoint
        }
        endpoint = url; self.backendReference = backendReference
    }
    private enum CodingKeys: String, CodingKey { case endpoint, backendReference }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(address: values.decode(String.self, forKey: .endpoint), backendReference: values.decode(UUID.self, forKey: .backendReference))
    }
}

/// Serializes only records already filtered by our SDK exporter. No raw SpanData
/// or user-controlled resource maps can reach the wire. Millisecond clock precision.
nonisolated public enum AnnexOTLPJSON {
    public static func encode(_ records: [AnnexDiagnosticRecord]) throws -> Data {
        guard records.count <= 64 else { throw AnnexTransportError.responseTooLarge }
        for record in records {
            guard record.serviceName == "clubhouse-go",
                  AnnexTelemetryHandshake.canonicalUUID(record.serviceInstanceID) != nil,
                  AnnexTraceContext(traceparent: "00-\(record.traceID)-\(record.id)-01") != nil,
                  record.parentID == nil || AnnexTraceContext(traceparent: "00-\(record.traceID)-\(record.parentID!)-01") != nil,
                  record.startedAt.timeIntervalSince1970.isFinite,
                  (0...9_000_000_000).contains(record.startedAt.timeIntervalSince1970),
                  record.durationMs.isFinite, (0...600_000).contains(record.durationMs) else { throw AnnexTransportError.malformedResponse }
        }
        func attribute(_ key: String, _ value: AnnexJSON) -> AnnexJSON { .object(["key": .string(key), "value": value]) }
        let groups = Dictionary(grouping: records, by: \.serviceInstanceID)
        let resources: [AnnexJSON] = groups.keys.sorted().map { instance in
            let spans: [AnnexJSON] = (groups[instance] ?? []).map { record in
                let start = Int64(record.startedAt.timeIntervalSince1970 * 1000) * 1_000_000
                let end = start + Int64(record.durationMs * 1_000_000)
                var attrs = record.measurements.keys.sorted().compactMap { key -> AnnexJSON? in
                    guard AnnexDiagnosticNumber(rawValue: key) != nil, let value = record.measurements[key], value.isFinite else { return nil }
                    return attribute(key, .object(["doubleValue": .number(min(1_000_000_000, max(0, value)))]))
                }
                attrs += record.identifiers.keys.sorted().compactMap { key -> AnnexJSON? in
                    guard AnnexDiagnosticIdentifier(rawValue: key) != nil, let value = record.identifiers[key], AnnexTelemetryHandshake.canonicalUUID(value) != nil else { return nil }
                    return attribute(key, .object(["stringValue": .string(value)]))
                }
                if record.failure != .none { attrs.append(attribute("failure", .object(["stringValue": .string(record.failure.rawValue)]))) }
                var span: [String: AnnexJSON] = ["traceId": .string(record.traceID), "spanId": .string(record.id),
                    "name": .string(record.operation.rawValue), "kind": .integer(Int64([1, 3, 5].contains(record.spanKind) ? record.spanKind : 1)),
                    "startTimeUnixNano": .string(String(start)), "endTimeUnixNano": .string(String(end)),
                    "attributes": .array(attrs), "flags": .integer(1), "status": .object(["code": .integer(record.failure == .none ? 1 : 2)])]
                if let parent = record.parentID { span["parentSpanId"] = .string(parent) }
                // Local summary events have no retained timestamps; never invent OTLP event times.
                return .object(span)
            }
            return .object(["resource": .object(["attributes": .array([
                attribute("service.name", .object(["stringValue": .string("clubhouse-go")])),
                attribute("service.instance.id", .object(["stringValue": .string(instance)]))])]),
                "scopeSpans": .array([.object(["scope": .object(["name": .string("clubhouse.annex"), "version": .string("1")]), "spans": .array(spans)])])])
        }
        let result = try JSONEncoder().encode(AnnexJSON.object(["resourceSpans": .array(resources)]))
        guard result.count <= 256 * 1024 else { throw AnnexTransportError.responseTooLarge }
        return result
    }
}
nonisolated public struct AnnexOTLPResponse: Sendable {
    public let status: Int
    public let rejectedSpans: Int
    public let retryAfter: TimeInterval
    public init(status: Int, rejectedSpans: Int = 0, retryAfter: TimeInterval = 0) {
        self.status = status; self.rejectedSpans = max(0, rejectedSpans)
        self.retryAfter = retryAfter.isFinite ? max(0, min(86400, retryAfter)) : 0
    }
}
nonisolated public protocol AnnexOTLPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AnnexOTLPResponse
}
nonisolated private final class AnnexOTLPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
nonisolated public final class AnnexOTLPHTTP: AnnexOTLPTransport, Sendable {
    public init() {}
    public func send(_ request: URLRequest) async throws -> AnnexOTLPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: AnnexOTLPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnnexTransportError.malformedResponse }
        guard (200...299).contains(http.statusCode) else { return .init(status: http.statusCode, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))) }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < 64 * 1024 else { throw AnnexTransportError.responseTooLarge }
            body.append(byte)
        }
        // Partial success is not retried; never retain collector error messages.
        guard !body.isEmpty else { return .init(status: http.statusCode) }
        guard let reply = try? JSONDecoder().decode(AnnexJSON.self, from: body) else { throw AnnexTransportError.malformedResponse }
        return try Self.parseResponse(reply, status: http.statusCode)
    }
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval {
        guard let header, header.utf8.count <= 128 else { return 0 }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let delay = Double(header) ?? formatter.date(from: header)?.timeIntervalSince(now) ?? 0
        return delay.isFinite ? max(0, min(86400, delay)) : 0
    }
    static func parseResponse(_ reply: AnnexJSON, status: Int) throws -> AnnexOTLPResponse {
        guard case .object = reply else { throw AnnexTransportError.malformedResponse }
        guard let partial = reply["partialSuccess"] else { return .init(status: status) }
        guard case .object = partial else { throw AnnexTransportError.malformedResponse }
        guard let rejected = partial["rejectedSpans"] else { return .init(status: status) }
        guard let count = rejected.integer.flatMap(Int.init(exactly:)) ?? rejected.string.flatMap(Int.init), count >= 0 else {
            throw AnnexTransportError.malformedResponse
        }
        return .init(status: status, rejectedSpans: count)
    }
}
public actor AnnexOTLPExporter {
    public struct Health: Sendable { public let delivered: Int; public let dropped: Int; public let failure: AnnexDiagnosticFailure }
    private let transport: any AnnexOTLPTransport
    private let now: @Sendable () -> TimeInterval
    private let jitter: @Sendable () -> Double
    private var owner: UUID?
    private var configuration: AnnexOTLPConfiguration?
    private var seen: [String] = []
    private var batch: [AnnexDiagnosticRecord] = []
    private var attempt = 0
    private var nextAttempt = 0.0
    private var generation = UUID()
    private var inFlight: Task<AnnexOTLPResponse, Error>?
    private var delivered = 0
    private var dropped = 0
    private var failure = AnnexDiagnosticFailure.none
    public init(transport: any AnnexOTLPTransport = AnnexOTLPHTTP(), now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }) {
        self.transport = transport; self.now = now; self.jitter = jitter
    }
    public func beginSession() -> UUID? {
        guard !Task.isCancelled else { return nil }
        reset(); let id = UUID(); owner = id; return id
    }
    public func endSession(_ id: UUID) { guard owner == id else { return }; reset(); owner = nil }
    public func health() -> Health { .init(delivered: delivered, dropped: dropped, failure: failure) }
    public func reset() {
        generation = UUID(); inFlight?.cancel(); inFlight = nil
        configuration = nil; batch = []; seen = []; attempt = 0; nextAttempt = 0; failure = .none
    }
    /// Foreground pump only. One in-flight request, one batch, bounded retries and
    /// dedup IDs. Initial enable/destination change excludes pre-consent records.
    public func flush(configuration desired: AnnexOTLPConfiguration?, enabled: Bool, records: [AnnexDiagnosticRecord], session: UUID? = nil) async {
        guard session == nil || session == owner else { return }
        guard enabled, let desired else { reset(); return }
        if configuration != desired {
            reset(); configuration = desired; seen = Array(records.suffix(512).map(\.id)); return
        }
        guard inFlight == nil, now() >= nextAttempt else { return }
        if batch.isEmpty {
            let known = Set(seen)
            batch = Array(records.suffix(512).filter { !known.contains($0.id) }.prefix(64))
        }
        guard !batch.isEmpty else { return }
        let ticket = generation
        var retryAfter = 0.0
        do {
            var request = URLRequest(url: desired.endpoint)
            request.httpMethod = "POST"; request.httpBody = try AnnexOTLPJSON.encode(batch)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let task = Task { [transport] in try await transport.send(request) }
            inFlight = task
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard ticket == generation else { return }
            inFlight = nil
            let status = response.status
            if (200...299).contains(status) {
                let rejected = min(batch.count, response.rejectedSpans)
                delivered = min(1_000_000_000, delivered + batch.count - rejected); dropped = min(1_000_000_000, dropped + rejected)
                failure = rejected == 0 ? .none : .rejected; finishBatch(); return
            }
            if [429, 502, 503, 504].contains(status), response.retryAfter <= 300 {
                retryAfter = response.retryAfter
                throw AnnexTransportError.rejected(status: status, code: nil)
            }
            failure = status == 401 ? .authentication : status == 403 ? .forbidden : .rejected
            dropped = min(1_000_000_000, dropped + batch.count); finishBatch()
        } catch {
            guard ticket == generation else { return }
            inFlight = nil
            if Task.isCancelled || error is CancellationError { reset(); return }
            failure = AnnexDiagnosticFailure.classify(error)
            attempt += 1
            if attempt >= 3 { dropped = min(1_000_000_000, dropped + batch.count); finishBatch() }
            else {
                let value = jitter(), factor = value.isFinite ? min(1.2, max(0.8, value)) : 1
                nextAttempt = now() + max(retryAfter, min(300, pow(2, Double(attempt)) * 15 * factor))
            }
        }
    }
    private func finishBatch() {
        seen = Array((seen + batch.map(\.id)).suffix(512))
        batch = []; attempt = 0; nextAttempt = 0
    }
}
