import Foundation
import Testing
@testable import Framebriar
@testable import FramebriarUI

// A queued or prepared report must never deliver under a different enrollment than it was saved
// under, and must never be silently deleted. tests/fixtures/held-reports-v1.json is mirrored here and
// kept byte-identical by tests/swift-wire-contract.test.mjs.

private func heldFixture() throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "held-reports-v1", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
private func release(_ name: String) throws -> HeldReleaseResult {
    let value = try #require((try heldFixture()["release"] as? [String: Any])?[name] as? [String: Any])
    return HeldReleaseResult(released: value["released"] as! Int, remaining: value["remaining"] as! Int, failed: value["failed"] as! Int, code: value["code"] as? String)
}
/// Every redemption is a distinct family and every token distinct, so a test can say which enrollment
/// carried each report. Delivery can be parked to change the enrollment during it.
private actor HeldNetwork: HTTPTransport {
    private let clock: Clock
    private var tokens = 0, families = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    var park = false
    var failReports = false
    var offline = false
    private(set) var reports: [(token: String, body: Data)] = []
    private(set) var refreshes = 0
    private(set) var all: [Data] = []
    init(clock: Clock) { self.clock = clock }
    func set(failReports: Bool = false, offline: Bool = false, park: Bool = false) { self.failReports = failReports; self.offline = offline; self.park = park }
    func token(_ n: Int) -> String { ("t\(n)" + String(repeating: "a", count: 43)).prefix(43).description }
    func currentToken() -> String { token(tokens) }
    func untilParked() async { if parked != nil { return }; await withCheckedContinuation { arrived = $0 } }
    func unpark() { parked?.resume(); parked = nil }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let body = request.httpBody { all.append(body) }
        if offline { throw FramebriarError.network }
        let path = request.url!.path
        if path.hasSuffix("/redeem") || path.hasSuffix("/refresh") {
            if path.hasSuffix("/refresh") { refreshes += 1 } else { families += 1 }
            tokens += 1
            let sent = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let family = path.hasSuffix("/refresh") ? sent["refreshToken"] as! String : ("f\(families)" + String(repeating: "r", count: 43)).prefix(43).description
            return json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": token(tokens), "refreshToken": family, "feedbackCorrelationVersion": 1,
                         "expiresAt": iso(clock.now() + 3600), "refreshExpiresAt": iso(Date(timeIntervalSince1970: 1_800_000_000) + 20 * 86400)])
        }
        if path.hasSuffix("/disconnect") { return json(["v": 1, "disconnected": true]) }
        reports.append((request.value(forHTTPHeaderField: "Authorization")!.replacingOccurrences(of: "Bearer ", with: ""), request.httpBody!))
        if park {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in parked = c; arrived?.resume(); arrived = nil }
        }
        if failReports { throw FramebriarError.network }
        return ack(request)
    }
}
private final class FlakyQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [QueuedFeedback] = []
    var failAfter: Int?
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    func save(_ next: [QueuedFeedback], scope: String) throws {
        try lock.withLock {
            if let n = failAfter { if n <= 0 { throw FramebriarError.storage }; failAfter = n - 1 }
            items = next
        }
    }
    func seed(_ next: [QueuedFeedback]) { lock.withLock { items = next } }
}
private struct HeldRig {
    let clock = Clock()
    let network: HeldNetwork
    let enrollment = MemoryEnrollment()
    let queue = FlakyQueue()
    let config = try! Configuration(gameID: "test-app", buildSHA: "abcdef0")
    init() { network = HeldNetwork(clock: clock) }
    func client() throws -> Client { try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: queue, now: clock.now) }
    func started() async throws -> Client { let c = try client(); await c.resume(); return c }
    func enrolled(_ c: Client, _ character: String = "a") async throws { try await c.connect(invitation: String(repeating: character, count: 43)) }
    func review(_ notes: String = "reviewed", png: Data? = nil) throws -> ReviewedFeedback {
        try ReviewedFeedback(configuration: config, notes: notes, reviewedScreenshotPNG: png, capturedAt: clock.now())
    }
    /// Saved while delivery can't complete, so it's still queued when the enrollment moves.
    @discardableResult func saveUnsent(_ c: Client) async throws -> ReviewedFeedback {
        let report = try review(); try await c.enqueue(report, enrollmentRef: try #require(c.enrollmentSignal.enrollmentRef)); return report
    }
    func ref(_ c: Client) -> String? { c.enrollmentSignal.enrollmentRef }
    func row(_ id: UUID) throws -> QueuedFeedback? { try queue.load(scope: config.storageScope).first { $0.feedback.id == id } }
}
private func ids(_ network: HeldNetwork) async -> [String] {
    await network.reports.map { (try! JSONSerialization.jsonObject(with: $0.body) as! [String: Any])["id"] as! String }
}

@Test func refreshKeepsTheRefAndStillDelivers() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let ref = r.ref(c)
    let report = try await r.saveUnsent(c)
    r.clock.advance(3400); try await c.refreshAccess()
    #expect(r.ref(c) == ref); #expect(await r.network.refreshes == 1)
    try await c.flush()
    #expect(await ids(r.network) == [report.id.uuidString.lowercased()])
    let (token, last) = (await r.network.reports[0].token, await r.network.currentToken()); #expect(token == last)
    #expect(await c.status().queued == 0)
}
@Test func aRedemptionHoldsWithNoRequestNoTokenWorkAndSeparateFromBlocked() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c)
    let report = try await r.saveUnsent(c)
    try await r.enrolled(c, "b")
    #expect(r.ref(c) != first)
    r.clock.advance(3500)
    for _ in 0..<3 { try await c.flush() }
    #expect(await r.network.reports.isEmpty); #expect(await r.network.refreshes == 0)
    let s = await c.status()
    #expect(s.heldForEnrollment == 1); #expect(s.blocked == 0); #expect(s.queued == 1); #expect(s.releaseToken?.count == 64)
    #expect(!(s.releaseToken ?? "").contains(first!)); #expect(try r.row(report.id)?.enrollmentRef == first)
}
@Test func releaseDeliversByteIdenticalAndClearRemoves() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); await r.network.set(failReports: true)
    let report = try await r.saveUnsent(c); try? await c.flush()
    let original = await r.network.reports[0].body; #expect(try r.row(report.id)?.attempts == 1)
    await r.network.set(); try await r.enrolled(c, "b"); try await c.flush(); #expect(await r.network.reports.count == 1)
    #expect(await c.releaseHeldReports(releaseToken: c.status().releaseToken) == HeldReleaseResult(released: 1, remaining: 0, failed: 0))
    #expect(try r.row(report.id)?.blocked == false); #expect(await r.network.reports.count == 1, "a release doesn't itself send")
    try await c.flush()
    #expect(await r.network.reports.count == 2); #expect(await r.network.reports[1].body == original)
    let (token, last) = (await r.network.reports[1].token, await r.network.currentToken()); #expect(token == last)

    let keep = try await r.saveUnsent(c); await r.network.set(offline: true); try? await c.flush(); await r.network.set()
    let cleared = HeldRig(), d = try await cleared.started(); try await cleared.enrolled(d); try await cleared.saveUnsent(d)
    _ = try await d.disconnect(); #expect(await d.status().heldForEnrollment == 1); #expect(await d.status().releaseToken == nil)
    let requests = await cleared.network.all.count
    #expect(await d.clearHeldReports() == HeldClearResult(cleared: 1, remaining: 0, failed: 0))
    #expect(await cleared.network.all.count == requests, "no token and nothing sent"); #expect(await d.status().queued == 0)
    try await c.clearQueuedFeedback(); #expect(await c.status().queued == 0); #expect(try r.row(keep.id) == nil)
}
@Test func theReproFailedSaveDisconnectReEnrollRetry() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c)
    let model = await FeedbackModel(client: c); let draft = await model.openDraft()
    r.queue.failAfter = 0
    await #expect(throws: FramebriarError.storage) { try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) }
    r.queue.failAfter = nil; _ = try await c.disconnect(); try await r.enrolled(c)
    await #expect(throws: FramebriarError.enrollmentChanged) { try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) }
    #expect(await c.status().queued == 0); #expect(await r.network.reports.isEmpty)
}
@Test func deadDraftStaysDeadAndAReopenIsANewReportWithNewCaptures() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c)
    let box = LabelBox(); box.label = "old.capture"
    let model = await FeedbackModel(client: c, diagnosticsProvider: { box.snapshot(r.clock.now()) }, reportDiagnostics: .on); let draft = await model.openDraft()
    try await r.enrolled(c, "b")
    for _ in 0..<2 {
        await #expect(throws: FramebriarError.enrollmentChanged) { try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) }
        #expect(await c.status().queued == 0)
    }
    #expect(await model.send(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .needsAttention(.enrollmentChanged))
    #expect(FeedbackDisclosure.detail(.needsAttention(.enrollmentChanged)).hasPrefix("Not saved"))
    #expect(await c.status().queued == 0)
    box.label = "new.capture"
    let again = await model.openDraft()
    #expect(again.id != draft.id); #expect(again.enrollmentRef != draft.enrollmentRef)
    #expect(again.capturedDiagnostics != draft.capturedDiagnostics)
    let png = Data([137,80,78,71,13,10,26,10,1])
    let report = try await model.save(again, notes: "n", screenshotPNG: png, includeDiagnostics: true)
    #expect(report.screenshotPNG == png)
    let bytes = String(decoding: try report.wire(), as: UTF8.self)
    #expect(bytes.contains("new.capture")); #expect(!bytes.contains("old.capture")); #expect(!bytes.contains(draft.id.uuidString.lowercased()))
    #expect(!bytes.contains(try #require(again.enrollmentRef)), "identity is never in the report")
}
@Test func releaseSendsTheFrozenBytesWhateverTheModelsDiagnosticsModeIsNow() async throws {
    for current in [FeedbackReportDiagnostics.off, .on] {
        let r = HeldRig(), c = try await r.started(); try await r.enrolled(c)
        let box = LabelBox(); box.label = "frozen.capture"
        let provider: @MainActor () -> FeedbackDiagnostics? = { box.snapshot(r.clock.now()) }
        let saving = await FeedbackModel(client: c, diagnosticsProvider: provider, reportDiagnostics: .off)
        let on = try await saving.save(await saving.openDraft(reportDiagnostics: .on), notes: "on", screenshotPNG: nil, includeDiagnostics: true)
        let off = try await saving.save(await saving.openDraft(), notes: "off", screenshotPNG: nil, includeDiagnostics: true)
        let frozenOn = try on.wire(), frozenOff = try off.wire()
        try await r.enrolled(c, "b"); #expect(await c.status().heldForEnrollment == 2)

        box.label = "later.capture"
        let releasing = await FeedbackModel(client: c, diagnosticsProvider: provider, reportDiagnostics: current)
        let token = await c.status().releaseToken
        #expect(await releasing.releaseHeldReports(releaseToken: token).released == 2)
        let bodies = await r.network.reports.map(\.body)
        #expect(bodies.count == 2); #expect(bodies.contains(frozenOn)); #expect(bodies.contains(frozenOff))
        let sentOn = String(decoding: frozenOn, as: UTF8.self), sentOff = String(decoding: frozenOff, as: UTF8.self)
        #expect(sentOn.contains("\"diagnostics\"")); #expect(sentOn.contains("frozen.capture"))
        #expect(!sentOff.contains("\"diagnostics\"")); #expect(!sentOff.contains("frozen.capture"))
    }
}
@Test func sameEnrollmentRetryIsIdempotentAndByteIdentical() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c)
    let model = await FeedbackModel(client: c); let draft = await model.openDraft()
    r.queue.failAfter = 0
    await #expect(throws: FramebriarError.storage) { try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) }
    r.queue.failAfter = nil
    let a = try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true)
    let b = try await model.save(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true)
    #expect(a.id == b.id); #expect(try a.wire() == b.wire()); #expect(await c.status().queued == 1)
    #expect(!String(decoding: try a.wire(), as: UTF8.self).contains(draft.enrollmentRef!))
}
@Test func disconnectThenTheSameInvitationStillHolds() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c); try await r.saveUnsent(c)
    _ = try await c.disconnect(); #expect(r.ref(c) == nil)
    try await r.enrolled(c); #expect(r.ref(c) != first)
    try await c.flush(); #expect(await r.network.reports.isEmpty); #expect(await c.status().heldForEnrollment == 1)
}
@Test func reRedeemWhileEnrolledHolds() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c); let report = try await r.saveUnsent(c)
    try await r.enrolled(c); #expect(r.ref(c) != first); try await c.flush()
    #expect(await r.network.reports.isEmpty); #expect(try r.row(report.id)?.enrollmentRef == first)
}
@Test func restartPreservesHeldStateAndRefs() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c); let report = try await r.saveUnsent(c)
    try await r.enrolled(c, "b"); let current = r.ref(c)
    let next = try await r.started(); #expect(r.ref(next) == current)
    try await next.flush(); #expect(await r.network.reports.isEmpty); #expect(await next.status().heldForEnrollment == 1)
    #expect(try r.row(report.id)?.enrollmentRef == first); #expect(try r.row(report.id)?.heldForEnrollment == true)
}
@Test func olderItemSeenWhileEnrolledBindsAndDelivers() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let ref = r.ref(c)
    let report = try r.review(); r.queue.seed([QueuedFeedback(feedback: report)])
    let next = try await r.started(); #expect(try r.row(report.id)?.enrollmentRef == ref)
    _ = try await next.refreshAccess(); try await next.flush(); #expect(await ids(r.network) == [report.id.uuidString.lowercased()])
}
@Test func olderItemSeenUnenrolledStaysHeldAfterRedemptionAndRestart() async throws {
    let r = HeldRig(); let report = try r.review(); r.queue.seed([QueuedFeedback(feedback: report)])
    let c = try await r.started(); #expect(try r.row(report.id)?.enrollmentRef == "unbound"); #expect(await c.status().heldForEnrollment == 1)
    try await r.enrolled(c); try await c.flush(); #expect(await r.network.reports.isEmpty)
    let next = try await r.started(); try await next.flush()
    #expect(await r.network.reports.isEmpty); #expect(try r.row(report.id)?.enrollmentRef == "unbound"); #expect(await next.status().heldForEnrollment == 1)
    #expect(await next.releaseHeldReports(releaseToken: next.status().releaseToken).released == 1)
    try await next.refreshAccess(); try await next.flush(); #expect(await r.network.reports.count == 1)
}
@Test func anEnrollmentRecordFromBeforeRefsGetsOneOnLoadAndKeepsIt() async throws {
    let r = HeldRig(); try r.enrollment.save(EnrollmentRecord(refreshToken: refresh, expiresAt: r.clock.now() + 86400, enrolled: true, notice: .connected), scope: r.config.storageScope)
    let c = try await r.started(); let minted = try #require(r.ref(c)); #expect(try r.enrollment.load(scope: r.config.storageScope).enrollmentRef == minted)
    #expect(try r.ref(await r.started()) == minted)
}
@Test func theRefIsAbsentFromEveryRequestAndHeldSpendNoRetries() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = try #require(r.ref(c)); let report = try await r.saveUnsent(c)
    try await r.enrolled(c, "b"); let second = try #require(r.ref(c)); let before = try r.row(report.id)
    for _ in 0..<4 { r.clock.advance(3600); try await c.flush() }
    #expect(try r.row(report.id)?.attempts == before?.attempts); #expect(await r.network.reports.isEmpty)
    #expect(await c.releaseHeldReports(releaseToken: c.status().releaseToken).released == 1); try await c.refreshAccess(); try await c.flush()
    _ = try await c.disconnect()
    let everything = await r.network.all.map { String(decoding: $0, as: UTF8.self) }.joined()
    #expect(!everything.contains(first)); #expect(!everything.contains(second)); #expect(!everything.contains("enrollmentRef"))
}
@Test func disconnectDuringDeliveryNeitherRebindsNorLosesAndSendsNothingNew() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c), oldToken = await r.network.currentToken()
    let report = try await r.saveUnsent(c); await r.network.set(failReports: true, park: true)
    let pass = Task { try? await c.flush() }; await r.network.untilParked()
    _ = try await c.disconnect()
    await r.network.unpark(); await pass.value; await r.network.set()
    #expect(try r.row(report.id)?.attempts == 0); #expect(try r.row(report.id)?.enrollmentRef == first)
    try await r.enrolled(c, "b"); try await c.flush()
    #expect(await r.network.reports.map(\.token) == [oldToken], "never resent with the new token")
    #expect(await c.status().heldForEnrollment == 1)
}
@Test func aRedemptionCannotStartDuringDelivery() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); try await r.saveUnsent(c); await r.network.set(park: true)
    let pass = Task { try? await c.flush() }; await r.network.untilParked()
    await #expect(throws: FramebriarError.busy) { try await r.enrolled(c, "b") }
    await r.network.unpark(); await pass.value; #expect(await c.status().queued == 0)
}
@Test func releaseDuringDeliveryOfOthersSendsEachOnce() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let held = try await r.saveUnsent(c)
    try await r.enrolled(c, "b"); let current = try await r.saveUnsent(c); await r.network.set(park: true)
    let token = await c.status().releaseToken
    let pass = Task { try? await c.flush() }; await r.network.untilParked()
    #expect(await c.releaseHeldReports(releaseToken: token).released == 1)
    await r.network.unpark(); await pass.value; await r.network.set(); try await c.flush()
    let sent = await ids(r.network); #expect(sent.count == 2); #expect(Set(sent) == [held.id.uuidString.lowercased(), current.id.uuidString.lowercased()])
    #expect(await c.status().queued == 0)
}
@Test func doubleAndStaleReleases() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); try await r.saveUnsent(c); try await r.saveUnsent(c); _ = try await c.disconnect()
    #expect(await c.releaseHeldReports(releaseToken: "x") == (try release("notEnrolled")))
    try await r.enrolled(c, "b"); let stale = await c.status().releaseToken
    #expect(await c.releaseHeldReports(releaseToken: nil) == (try release("missingToken")))
    try await r.enrolled(c, "c")
    #expect(await c.releaseHeldReports(releaseToken: stale) == (try release("staleAfterEnrollmentChange")))
    #expect(await c.status().releaseToken != stale)
    let token = await c.status().releaseToken
    async let a = c.releaseHeldReports(releaseToken: token); async let b = c.releaseHeldReports(releaseToken: token)
    let results = await [a, b]
    #expect(results.contains(try release("success"))); #expect(results.contains(try release("double")))
    try await c.refreshAccess(); try await c.flush(); #expect(await r.network.reports.count == 2, "no double send")
}
@Test func partialReleaseKeepsFailedHeldUnderANewToken() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); try await r.saveUnsent(c); try await r.saveUnsent(c)
    try await r.enrolled(c, "b"); let token = await c.status().releaseToken
    r.queue.failAfter = 1
    #expect(await c.releaseHeldReports(releaseToken: token) == (try release("partial")))
    r.queue.failAfter = nil
    let after = await c.status(); #expect(after.heldForEnrollment == 1); #expect(after.queued == 2); #expect(after.releaseToken != token)
    #expect(await c.releaseHeldReports(releaseToken: token) == (try release("staleAfterHeldSetChange")))
    #expect(await c.releaseHeldReports(releaseToken: after.releaseToken).released == 1)
}
@Test func releaseIsExplicitOnly() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c); let report = try await r.saveUnsent(c); try await r.enrolled(c, "b")
    for _ in 0..<2 {
        r.clock.advance(4000); try await c.refreshAccess(); try await c.flush()
        let next = try await r.started(); try await next.refreshAccess(); try await next.flush()
        _ = await next.deliver(report.id)
    }
    #expect(try r.row(report.id)?.enrollmentRef == first); #expect(await r.network.reports.isEmpty)
    #expect(await c.deliver(report.id) == .needsAttention(.heldForEnrollment))
}
@Test func releaseVersusClearLeavesNothingToSend() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); try await r.saveUnsent(c); try await r.enrolled(c, "b"); let token = await c.status().releaseToken
    try await c.clearQueuedFeedback()
    #expect(await c.releaseHeldReports(releaseToken: token).code == "stale-release"); try await c.flush(); #expect(await r.network.reports.isEmpty)
}
@Test func expiryKeepsTheRefAndAReplacementHolds() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let first = r.ref(c)
    r.clock.advance(21 * 86400); await #expect(throws: FramebriarError.expired) { try await c.refreshAccess() }
    #expect(r.ref(c) == first); #expect(await c.status().canSubmit)
    let report = try await r.saveUnsent(c); #expect(await c.status().heldForEnrollment == 0)
    #expect(await c.releaseHeldReports(releaseToken: "x").code == "not-enrolled")
    #expect(await c.clearHeldReports().cleared == 0)
    r.clock.advance(-21 * 86400); try await r.enrolled(c, "b"); try await c.flush()
    #expect(await r.network.reports.isEmpty); #expect(await c.status().heldForEnrollment == 1); #expect(try r.row(report.id)?.enrollmentRef == first)
}
@Test func heldFillTheQueueAndARealRejectionStaysBlocked() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c)
    for _ in 0..<10 { try await r.saveUnsent(c) }
    try await r.enrolled(c, "b"); let s = await c.status(); #expect(s.queued == 10); #expect(s.heldForEnrollment == 10); #expect(s.blocked == 0)
    await #expect(throws: FramebriarError.capacity) { try await r.saveUnsent(c) }
    #expect(await c.clearHeldReports().cleared == 10); #expect(await c.status().queued == 0)
    var rejected = QueuedFeedback(feedback: try r.review(), blocked: true); rejected.enrollmentRef = "11111111-1111-4111-8111-111111111111"
    r.queue.seed([rejected]); let next = try await r.started(); let t = await next.status(); #expect(t.blocked == 1); #expect(t.heldForEnrollment == 0); #expect(t.releaseToken == nil)
}
@Test func theFenceIsWrittenBeforeTheNewEnrollmentCanSend() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); let report = try await r.saveUnsent(c)
    r.enrollment.fail = false; try await r.enrolled(c, "b")
    #expect(try r.row(report.id)?.blocked == true); #expect(try r.row(report.id)?.heldForEnrollment == true); #expect(await c.status().blocked == 0)
    _ = await c.releaseHeldReports(releaseToken: c.status().releaseToken)
    #expect(try r.row(report.id)?.blocked == false); #expect(try r.row(report.id)?.heldForEnrollment == false)
}
@Test func theModelUsesTheTokenTheUserSawAndComposerCopyNeverClaimsSent() async throws {
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); try await r.saveUnsent(c); try await r.enrolled(c, "b")
    let model = await FeedbackModel(client: c); await model.update(); let shown = await model.status?.releaseToken
    try await r.enrolled(c, "c")
    let stale = await model.releaseHeldReports(releaseToken: shown); #expect(stale.code == "stale-release"); #expect(await r.network.reports.isEmpty)
    #expect(!FeedbackDisclosure.releaseResult(stale).lowercased().contains("will send"))
    await model.update(); let fresh = await model.status?.releaseToken
    let done = await model.releaseHeldReports(releaseToken: fresh); #expect(done.released == 1); #expect(await r.network.reports.count == 1)
    #expect(FeedbackDisclosure.releaseResult(done).contains("aren't confirmed sent"))
    #expect(FeedbackDisclosure.heldSummary(count: 2).contains("haven't been sent")); #expect(FeedbackDisclosure.releaseConfirmation(count: 1).contains("this one"))
    try await r.saveUnsent(c); _ = try await c.disconnect(); await model.update(); #expect(await model.status?.heldForEnrollment == 1); #expect(await model.status?.releaseToken == nil)
    #expect(await model.clearHeldReports().cleared == 1); #expect(await model.status?.queued == 0)
}
@Test func theSharedFixtureHasTheStatusShapeAndCodes() async throws {
    let f = try heldFixture(); let codes = try #require(f["codes"] as? [String: String])
    #expect(codes["enrollmentChanged"] == FramebriarError.enrollmentChanged.code); #expect(FramebriarError.enrollmentChanged.code == "enrollment-changed")
    #expect(try release("staleAfterEnrollmentChange").code == codes["staleRelease"]); #expect(try release("notEnrolled").code == codes["notEnrolled"])
    let r = HeldRig(), c = try await r.started(); try await r.enrolled(c); try await r.saveUnsent(c); try await r.saveUnsent(c); _ = try await c.disconnect()
    let status = await c.status(), held = try #require((f["status"] as? [String: Any])?["heldWhileUnenrolled"] as? [String: Any])
    #expect(status.queued == held["items"] as? Int); #expect(status.heldForEnrollment == held["heldForEnrollment"] as? Int); #expect(status.heldBytes == held["heldBytes"] as? Int)
    #expect(status.releaseToken == nil); #expect(ClientStatus.maxItems == held["maxItems"] as? Int); #expect(ClientStatus.maxBytes == held["maxBytes"] as? Int)
    let clear = try #require((f["clear"] as? [String: Any])?["whileUnenrolled"] as? [String: Int])
    #expect(await c.clearHeldReports() == HeldClearResult(cleared: clear["cleared"]!, remaining: clear["remaining"]!, failed: clear["failed"]!))
}
@Test func aFileStoreFromAnOlderSDKDecodesAndKeepsReports() async throws {
    let r = HeldRig(); let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try FileFeedbackStore(directory: dir); let report = try r.review()
    let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode([QueuedFeedback(feedback: report)])) as! [[String: Any]]
    let stripped = old.map { $0.filter { $0.key != "enrollmentRef" && $0.key != "heldForEnrollment" } }
    let file = dir.appendingPathComponent(digest(Data(r.config.storageScope.utf8)) + ".json")
    try JSONSerialization.data(withJSONObject: stripped).write(to: file)
    let loaded = try store.load(scope: r.config.storageScope)
    #expect(loaded.first?.feedback == report); #expect(loaded.first?.enrollmentRef == nil); #expect(loaded.first?.heldForEnrollment == false)
}
private final class LabelBox: @unchecked Sendable {
    var label = ""
    func snapshot(_ at: Date) -> FeedbackDiagnostics {
        FeedbackDiagnostics(windowStart: at - 60, windowEnd: at, entries: [.init(at: at - 1, level: .warn, ns: "net.socket", event: label)])
    }
}
