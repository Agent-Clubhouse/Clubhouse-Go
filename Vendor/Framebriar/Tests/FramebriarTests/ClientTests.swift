import Foundation
import Testing
@testable import Framebriar

final class MemoryEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord()
    var fail = false
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws {
        try lock.withLock { if fail { throw FramebriarError.storage }; self.record = record }
    }
}
final class MemoryQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QueuedFeedback] = []
    var fail = false
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    func save(_ items: [QueuedFeedback], scope: String) throws {
        try lock.withLock { if fail { throw FramebriarError.storage }; self.items = items }
    }
}
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
actor MockTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> HTTPResponse
    var requests: [URLRequest] = []
    var handlers: [Handler] = []
    func add(_ handler: @escaping Handler) { handlers.append(handler) }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !handlers.isEmpty else { throw FramebriarError.network }
        return try await handlers.removeFirst()(request)
    }
    func count() -> Int { requests.count }
}
let invitation = String(repeating: "i", count: 43)
let refresh = String(repeating: "r", count: 43)
let bearer = String(repeating: "b", count: 43)
let uploadTicket = String(repeating: "t", count: 43)
func json(_ value: [String: Any], status: Int = 200, headers: [String: String] = ["content-type": "application/json"]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: value))
}
func access(_ clock: Clock, days: Double = 30) -> HTTPResponse {
    json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh,
          "expiresAt": iso(clock.now() + 3600), "refreshExpiresAt": iso(clock.now() + days * 86400)])
}
func ack(_ request: URLRequest, status: String = "ready") -> HTTPResponse {
    let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    return json(["id": body["id"]!, "status": status, "gameId": "test-app", "ticket": uploadTicket])
}
struct Rig {
    let clock = Clock()
    let network = MockTransport()
    let enrollment = MemoryEnrollment()
    let queue = MemoryQueue()
    let config = try! Configuration(gameID: "test-app", buildSHA: "abcdef0")
    func client() throws -> Client {
        try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: queue, now: clock.now)
    }
    func connected() async throws -> Client {
        let client = try client(); await client.resume()
        await network.add { _ in access(clock) }
        try await client.connect(invitation: invitation)
        return client
    }
    func review(_ notes: String = "A button does not respond", png: Data? = nil) throws -> ReviewedFeedback {
        try ReviewedFeedback(configuration: config, notes: notes, reviewedScreenshotPNG: png, capturedAt: clock.now())
    }
}

@Test func enrollmentAndTextDeliveryMatchWireContract() async throws {
    let r = Rig(); let client = try await r.connected()
    let report = try r.review()
    #expect(try await client.enqueue(report) == report.id)
    await r.network.add { request in
        #expect(request.url!.path == "/api/v1/reports")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + bearer)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["v"] as? Int == 1)
        #expect(body["buildSha"] as? String == "abcdef0")
        #expect(body["media"] is NSNull)
        #expect((body["breadcrumbs"] as? [Any])?.isEmpty == true)
        #expect(body["traceId"] == nil)
        return ack(request)
    }
    try await client.flush()
    #expect(await client.status().queued == 0)
    #expect(await client.status().lastReceivedID == report.id)
    let request = await r.network.requests[0]
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["scopeVersion"] as? Int == 2)
    #expect(body["invitation"] as? String == invitation)
    #expect(body["attemptId"] != nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func screenshotTwoPhaseUploadAndNoSecretInQueue() async throws {
    let r = Rig(); let client = try await r.connected()
    let png = Data([137,80,78,71,13,10,26,10,0,1,2,3])
    let report = try r.review(png: png)
    try await client.enqueue(report)
    await r.network.add { request in
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let media = body["media"] as! [String: Any]
        #expect(media["sha256"] as? String == digest(png))
        #expect(media["bytes"] as? Int == png.count)
        return ack(request, status: "pending")
    }
    await r.network.add { request in
        #expect(request.httpMethod == "PUT")
        #expect(request.url!.path.hasSuffix("/\(report.id.uuidString.lowercased())/media"))
        #expect(request.value(forHTTPHeaderField: "x-upload-ticket") == uploadTicket)
        #expect(request.httpBody == png)
        return json(["id": report.id.uuidString.lowercased(), "status": "ready", "gameId": "test-app"])
    }
    let bytes = try JSONEncoder().encode(r.queue.load(scope: r.config.storageScope))
    let stored = String(decoding: bytes, as: UTF8.self)
    for secret in [bearer, refresh, invitation, uploadTicket] { #expect(!stored.contains(secret)) }
    try await client.flush()
    #expect(await client.status().queued == 0)
}

@Test func lostReceiptRetriesSameUUIDAndBackoffSurvivesRestart() async throws {
    let r = Rig(); let client = try await r.connected(); let report = try r.review()
    try await client.enqueue(report)
    await r.network.add { _ in throw FramebriarError.network }
    try await client.flush()
    #expect(await client.status().queued == 1)
    let restarted = try r.client(); await restarted.resume()
    try await restarted.flush()
    #expect(await r.network.count() == 2)
    r.clock.advance(5)
    let deadline = try r.enrollment.load(scope: r.config.storageScope).expiresAt!
    await r.network.add { _ in json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh, "expiresAt": iso(r.clock.now()+3600), "refreshExpiresAt": iso(deadline)]) }
    await r.network.add { request in ack(request) }
    try await restarted.flush()
    #expect(await restarted.status().queued == 0)
    let reports = await r.network.requests.filter { $0.url!.path == "/api/v1/reports" }
    #expect(reports.count == 2)
    #expect(reports[0].httpBody == reports[1].httpBody)
}

@Test func uncertainRedemptionReusesAttemptWithoutAutoRetry() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in throw FramebriarError.network }
    await #expect(throws: FramebriarError.network) { try await client.connect(invitation: invitation) }
    #expect(await r.network.count() == 1)
    #expect(await client.status().canSubmit == false)
    await r.network.add { _ in access(r.clock) }
    try await client.connect(invitation: invitation)
    let requests = await r.network.requests
    #expect(requests[0].httpBody == requests[1].httpBody)
}

@Test func renewalRejectsExtendedFamilyOrWrongScope() async throws {
    let r = Rig(); let client = try await r.connected()
    r.clock.advance(3400)
    await r.network.add { _ in access(r.clock) }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.refreshAccess() }
    #expect(await client.status().access == .offline)
    #expect(try r.enrollment.load(scope: r.config.storageScope).refreshToken == refresh)
}

@Test func enrollmentMayUseIssuerSupportedLongerDeadline() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in access(r.clock, days: 365) }
    try await client.connect(invitation: invitation)
    #expect(await client.status().enrollmentExpiresAt == r.clock.now() + 365 * 86400)
}

@Test func expirationRetainsReportsAndAllowsLocalFeedback() async throws {
    let r = Rig(); let client = try await r.connected()
    try await client.enqueue(r.review())
    r.clock.advance(31 * 86400)
    try await client.flush()
    #expect(await client.status().access == .expired)
    #expect(await client.status().queued == 1)
    #expect(await client.status().canSubmit)
    try await client.enqueue(r.review("Another issue"))
    #expect(await client.status().queued == 2)
    #expect(await r.network.count() == 1)
}

@Test func quotaBackoffAndPermanentConflictRetainReports() async throws {
    let r = Rig(); let client = try await r.connected(); try await client.enqueue(r.review())
    await r.network.add { _ in json([:], status: 429, headers: ["retry-after": "120"]) }
    try await client.flush()
    r.clock.advance(119); try await client.flush()
    #expect(await r.network.count() == 2)
    r.clock.advance(2)
    await r.network.add { _ in json([:], status: 409) }
    try await client.flush(); try await client.flush()
    #expect(await client.status().blocked == 1)
    #expect(await client.status().queued == 1)
    #expect(await r.network.count() == 3)
}

@Test func invalidAcknowledgementNeverDeletesReport() async throws {
    let r = Rig(); let client = try await r.connected(); try await client.enqueue(r.review())
    await r.network.add { _ in json(["id": UUID().uuidString, "status": "ready"]) }
    try await client.flush()
    #expect(await client.status().queued == 1)
    #expect(await client.status().lastReceivedID == nil)
}

@Test func queueCapacityAndIdempotentEnqueue() async throws {
    let r = Rig(); let client = try await r.connected(); let report = try r.review()
    try await client.enqueue(report); try await client.enqueue(report)
    for _ in 0..<9 { try await client.enqueue(r.review()) }
    #expect(await client.status().queued == 10)
    await #expect(throws: FramebriarError.capacity) { try await client.enqueue(r.review()) }
    #expect(await r.network.count() == 1)
}

@Test func storageFailureDoesNotClaimSaveOrReceipt() async throws {
    let r = Rig(); let client = try await r.connected(); let report = try r.review()
    r.queue.fail = true
    await #expect(throws: FramebriarError.storage) { try await client.enqueue(report) }
    #expect(await client.status().queued == 0)
    r.queue.fail = false; try await client.enqueue(report)
    r.queue.fail = true
    await r.network.add { request in ack(request) }
    await #expect(throws: FramebriarError.storage) { try await client.flush() }
    #expect(await client.status().queued == 1)
    #expect(await client.status().lastReceivedID == nil)
}

@Test func disconnectForgetAndRevocationAreSeparate() async throws {
    let r = Rig(); let client = try await r.connected(); try await client.enqueue(r.review())
    await r.network.add { _ in throw FramebriarError.network }
    #expect(try await client.disconnect() == false)
    #expect(await client.status().canSubmit == false)
    #expect(await client.status().queued == 1)
    #expect(try r.enrollment.load(scope: r.config.storageScope).refreshToken == nil)
    await #expect(throws: FramebriarError.accessRequired) { try await client.enqueue(r.review()) }
}

actor Gate {
    var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func isStarted() -> Bool { started }
}
@Test func pauseDuringReportDoesNotUploadMediaOrDropQueue() async throws {
    let r = Rig(); let client = try await r.connected(); let gate = Gate()
    try await client.enqueue(r.review(png: Data([137,80,78,71,13,10,26,10])))
    await r.network.add { request in await gate.wait(); return ack(request, status: "pending") }
    let work = Task { try await client.flush() }
    while !(await gate.isStarted()) { await Task.yield() }
    await client.pause(); await gate.release()
    await #expect(throws: FramebriarError.paused) { try await work.value }
    #expect(await client.status().queued == 1)
    #expect(await r.network.count() == 2)
}

@Test func disconnectDuringRedemptionCannotRestoreEnrollment() async throws {
    let r = Rig(); let client = try r.client(); await client.resume(); let gate = Gate()
    await r.network.add { _ in await gate.wait(); return access(r.clock) }
    let work = Task { try await client.connect(invitation: invitation) }
    while !(await gate.isStarted()) { await Task.yield() }
    try await client.disconnect(); await gate.release()
    await #expect(throws: FramebriarError.paused) { try await work.value }
    #expect(await client.status().canSubmit == false)
}

@Test func privacyValidationAndScopeIsolation() throws {
    let r = Rig()
    let report = try r.review("email me@sample.com https://sample.com token=private /Users/person/file sk-abc123")
    #expect(report.notes == "email [email] [url] [redacted] [path] [credential]")
    #expect(throws: FramebriarError.invalidConfiguration) { try Configuration(gameID: "test-app", endpoint: URL(string: "https://sample.com?token=x")!) }
    #expect(throws: FramebriarError.invalidInput) { try r.review(" ") }
    #expect(throws: FramebriarError.invalidInput) { try r.review(png: Data([1,2,3])) }
    #expect(throws: FramebriarError.invalidInput) { try report.validate(for: Configuration(gameID: "another-app")) }
    #expect(try Configuration(gameID: "test-app", buildSHA: "1234567").storageScope == r.config.storageScope)
}

@Test func fileStoreRoundTripsWithoutAutomaticDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileFeedbackStore(directory: directory); let r = Rig()
    let report = try r.review(); try store.save([QueuedFeedback(feedback: report)], scope: r.config.storageScope)
    #expect(try store.load(scope: r.config.storageScope).first?.feedback == report)
    let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
    try Data("corrupt".utf8).write(to: file)
    #expect(throws: FramebriarError.storage) { try store.load(scope: r.config.storageScope) }
    #expect(try Data(contentsOf: file) == Data("corrupt".utf8))
}

@Test func earlyRenewalUsesRefreshOnlyAndPreservesDeadline() async throws {
    let r = Rig(); let client = try await r.connected()
    let deadline = try r.enrollment.load(scope: r.config.storageScope).expiresAt!
    r.clock.advance(3301)
    await r.network.add { request in
        #expect(request.url!.path == "/api/v1/access/refresh")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["refreshToken"] as? String == refresh)
        #expect(body["scopeVersion"] as? Int == 2)
        #expect(body["invitation"] == nil)
        return json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer,
                     "refreshToken": refresh, "expiresAt": iso(r.clock.now()+3600), "refreshExpiresAt": iso(deadline)])
    }
    try await client.refreshAccess()
    #expect(await client.status().access == .connected)
    #expect(await client.status().enrollmentExpiresAt == deadline)
}

@Test func deniedRenewalPreservesEligibilityWithoutCredential() async throws {
    let r = Rig(); let client = try await r.connected(); r.clock.advance(3301)
    await r.network.add { _ in json([:], status: 403) }
    await #expect(throws: FramebriarError.accessRequired) { try await client.refreshAccess() }
    #expect(await client.status().canSubmit)
    #expect(await client.status().access == .accessRequired)
    #expect(try r.enrollment.load(scope: r.config.storageScope).refreshToken == nil)
    let restarted = try r.client(); await restarted.resume()
    #expect(await restarted.status().access == .accessRequired)
    try await restarted.enqueue(r.review())
}

@Test func servicePauseKeepsEnrollmentAndHonorsRetryAfter() async throws {
    let r = Rig(); let client = try await r.connected(); r.clock.advance(3301)
    await r.network.add { _ in json([:], status: 503, headers: ["retry-after": "300"]) }
    await #expect(throws: FramebriarError.unavailable(retryAfter: 300)) { try await client.refreshAccess() }
    #expect(await client.status().access == .offline)
    #expect(try r.enrollment.load(scope: r.config.storageScope).refreshToken == refresh)
    r.clock.advance(299)
    await #expect(throws: FramebriarError.unavailable(retryAfter: 1)) { try await client.refreshAccess() }
    #expect(await r.network.count() == 2)
}

@Test func lostMediaReplyObtainsNewTicketForSameReport() async throws {
    let r = Rig(); let client = try await r.connected()
    let report = try r.review(png: Data([137,80,78,71,13,10,26,10]))
    try await client.enqueue(report)
    await r.network.add { ack($0, status: "pending") }
    await r.network.add { _ in throw FramebriarError.network }
    try await client.flush(); #expect(await client.status().queued == 1)
    r.clock.advance(5)
    await r.network.add { ack($0, status: "pending") }
    await r.network.add { _ in json(["id": report.id.uuidString.lowercased(), "status": "processed"]) }
    try await client.flush(); #expect(await client.status().queued == 0)
    let requests = await r.network.requests
    #expect(requests[1].httpBody == requests[3].httpBody)
    #expect(requests[2].httpBody == requests[4].httpBody)
}

@Test func concurrentFlushDoesNotDoubleSubmit() async throws {
    let r = Rig(); let client = try await r.connected(); let gate = Gate()
    try await client.enqueue(r.review())
    await r.network.add { request in await gate.wait(); return ack(request) }
    let work = Task { try await client.flush() }
    while !(await gate.isStarted()) { await Task.yield() }
    try await client.flush()
    #expect(await r.network.count() == 2)
    await gate.release(); try await work.value
    #expect(await client.status().queued == 0)
}

@Test func byteCapacityAndOversizedMediaAreBounded() async throws {
    let r = Rig(); let client = try await r.connected()
    var png = Data([137,80,78,71,13,10,26,10]); png.append(Data(repeating: 0, count: 8*1024*1024-8))
    for _ in 0..<4 { try await client.enqueue(r.review(png: png)) }
    #expect(await client.status().queuedBytes == 32*1024*1024)
    await #expect(throws: FramebriarError.capacity) { try await client.enqueue(r.review(png: Data([137,80,78,71,13,10,26,10]))) }
    png.append(0)
    #expect(throws: FramebriarError.invalidInput) { try r.review(png: png) }
}

@Test func invalidAccessResponseNeverPersistsCredential() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in json(["v": 1, "scopeVersion": 1, "gameId": "test-app", "token": bearer, "refreshToken": refresh, "expiresAt": iso(r.clock.now()+3600), "refreshExpiresAt": iso(r.clock.now()+86400)]) }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    #expect(try r.enrollment.load(scope: r.config.storageScope).refreshToken == nil)
    #expect(await client.status().canSubmit == false)
}

@Test func wrongGameAndRedirectAcknowledgementsRemainQueued() async throws {
    let r = Rig(); let client = try await r.connected(); let report = try r.review()
    try await client.enqueue(report)
    await r.network.add { _ in json(["id": report.id.uuidString.lowercased(), "status": "ready", "gameId": 123]) }
    try await client.flush(); #expect(await client.status().queued == 1)
    r.clock.advance(5)
    await r.network.add { _ in json([:], status: 302, headers: ["location": "https://example.invalid"]) }
    try await client.flush(); #expect(await client.status().queued == 1)
    #expect(await r.network.count() == 3)
}

@Test func wireMatchesFixtureValidatedByActualServiceNormalizer() throws {
    let file = try #require(Bundle.module.url(forResource: "text-report", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let report = try ReviewedFeedback(configuration: Configuration(gameID: "test-app", buildSHA: "abcdef0"),
        notes: fixture["notes"] as! String, id: UUID(uuidString: fixture["id"] as! String)!, capturedAt: parseDate(fixture["capturedAt"] as! String)!)
    var wire = try JSONSerialization.jsonObject(with: report.wire()) as! [String: Any]
    wire["sessionId"] = "SESSION"
    #expect(NSDictionary(dictionary: wire) == NSDictionary(dictionary: fixture))
}

@Test func upgradeAndReplacementEnrollmentPreserveOriginalReportProvenance() async throws {
    let r = Rig(); let first = try await r.connected(); let report = try r.review()
    try await first.enqueue(report); _ = try await first.disconnect()
    let upgraded = try Client(configuration: Configuration(gameID: "test-app", buildSHA: "1234567"),
        transport: r.network, enrollmentStore: r.enrollment, feedbackStore: r.queue, now: r.clock.now)
    await upgraded.resume()
    await r.network.add { _ in access(r.clock) }
    try await upgraded.connect(invitation: String(repeating: "j", count: 43))
    await r.network.add { request in
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["buildSha"] as? String == "abcdef0")
        #expect(body["id"] as? String == report.id.uuidString.lowercased())
        #expect(body["capturedAt"] as? String == iso(report.capturedAt))
        return ack(request)
    }
    try await upgraded.flush()
    #expect(await upgraded.status().queued == 0)
}
