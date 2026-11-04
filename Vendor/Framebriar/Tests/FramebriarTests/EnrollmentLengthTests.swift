import Foundation
import Testing
@testable import Framebriar
@testable import FramebriarUI

private let rejectedNotice = "enrollment-response-rejected"
private func redeemAttempt(_ request: URLRequest) throws -> String {
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    return body["attemptId"] as! String
}
private func reply(_ clock: Clock, _ change: (inout [String: Any]) -> Void = { _ in }) -> HTTPResponse {
    var value: [String: Any] = ["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh,
                                "expiresAt": iso(clock.now() + 3600), "refreshExpiresAt": iso(clock.now() + 180 * 86400)]
    change(&value)
    return json(value)
}

private let lengthsWithinCap: [Double] = [30, 31, 180, 365]
private let secondsOverCap: [Double] = [31_536_301, 31_622_400, 31_622_700] // 365 days + 5 min + 1 s, 366 days, 366 days + 5 min
private let secondsBehindWithinAllowance: [Double] = [1, 60, 240, 300]
private let secondsBehindBeyondAllowance: [Double] = [301, 360, 3600]
private struct RejectedCase: Sendable {
    let reason: String, key: String, value: String?
}
private let rejectedCases: [RejectedCase] = [
    RejectedCase(reason: "invalid-deadline", key: "refreshExpiresAt", value: "not-a-date"),
    RejectedCase(reason: "invalid-deadline", key: "expiresAt", value: "not-a-date"),
    RejectedCase(reason: "invalid-token", key: "refreshToken", value: "short"),
    RejectedCase(reason: "invalid-token", key: "token", value: "short"),
    RejectedCase(reason: "wrong-game", key: "gameId", value: "another-game"),
    RejectedCase(reason: "invalid-response", key: "scopeVersion", value: nil),
]

@Test(arguments: lengthsWithinCap) func enrollmentLengthsWithinTheCapConnect(days: Double) async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in access(r.clock, days: days) }
    try await client.connect(invitation: invitation)
    let status = await client.status()
    #expect(status.access == .connected)
    #expect(status.enrollmentExpiresAt == r.clock.now() + days * 86400)
    #expect(status.notice == nil && status.noticeReason == nil)
}

@Test(arguments: secondsOverCap) func enrollmentLengthsOverTheCapAreRejected(seconds: Double) async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in reply(r.clock) { $0["refreshExpiresAt"] = iso(r.clock.now() + seconds) } }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    #expect(await client.status().notice == rejectedNotice)
    #expect(await client.status().noticeReason == "invalid-deadline")
    #expect(await client.status().canSubmit == false)
}

@Test func restartWithStored180DayEnrollmentStaysEnrolledAndRefreshKeepsDeadline() async throws {
    let r = Rig(); let first = try r.client(); await first.resume()
    await r.network.add { _ in access(r.clock, days: 180) }
    try await first.connect(invitation: invitation)
    let deadline = r.clock.now() + 180 * 86400
    let ref = try r.enrollment.load(scope: r.config.storageScope).enrollmentRef
    r.clock.advance(40 * 86400)
    let next = try r.client(); await next.resume()
    #expect(await next.status().canSubmit)
    #expect(await next.status().enrollmentExpiresAt == deadline)
    await r.network.add { _ in reply(r.clock) { $0["refreshExpiresAt"] = iso(deadline) } }
    try await next.refreshAccess()
    #expect(await next.status().access == .connected)
    #expect(await next.status().enrollmentExpiresAt == deadline)
    #expect(try r.enrollment.load(scope: r.config.storageScope).enrollmentRef == ref)
    #expect(await r.network.requests.filter { $0.url!.path.hasSuffix("/redeem") }.count == 1)
}

@Test(arguments: rejectedCases) private func received2xxFailingValidationIsDistinguished(item: RejectedCase) async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in reply(r.clock) { $0[item.key] = item.value } }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    let status = await client.status()
    #expect(status.notice == rejectedNotice)
    #expect(status.noticeReason == item.reason)
    #expect(status.access == .disconnected && !status.canSubmit && status.enrollmentExpiresAt == nil)
    let record = try r.enrollment.load(scope: r.config.storageScope)
    #expect(record.refreshToken == nil && record.responseRejection == item.reason)
    let stored = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    for secret in [bearer, refresh, invitation] { #expect(!stored.contains(secret)) }
    #expect(await client.telemetryToken() == nil)
}

@Test func ambiguousFailuresClaimNoRejection() async throws {
    let html = HTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<html>".utf8))
    let garbled = HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data("{".utf8))
    let cases: [(FramebriarError, MockTransport.Handler)] = [
        (.network, { _ in throw URLError(.timedOut) }),
        (.unavailable(retryAfter: 0), { _ in json([:], status: 503) }),
        (.invalidResponse, { _ in html }),
        (.invalidResponse, { _ in garbled }),
        (.invalidResponse, { _ in json(["padding": String(repeating: "x", count: 8192)]) }),
    ]
    for (expected, handler) in cases {
        let r = Rig(); let client = try r.client(); await client.resume()
        await r.network.add(handler)
        await #expect(throws: expected) { try await client.connect(invitation: invitation) }
        #expect(await client.status().notice == nil)
        #expect(await client.status().noticeReason == nil)
    }
}

@Test func rejectedNoticeSurvivesRestartAndANewInvitationClearsIt() async throws {
    let r = Rig(); let first = try r.client(); await first.resume()
    await r.network.add { _ in reply(r.clock) { $0["gameId"] = "another-game" } }
    await #expect(throws: FramebriarError.invalidResponse) { try await first.connect(invitation: invitation) }
    let next = try r.client(); await next.resume()
    #expect(await next.status().notice == rejectedNotice)
    #expect(await next.status().noticeReason == "wrong-game")
    #expect(await r.network.count() == 1)
    await r.network.add { _ in access(r.clock) }
    try await next.connect(invitation: String(repeating: "n", count: 43))
    #expect(await next.status().notice == nil)
    #expect(await next.status().noticeReason == nil)
    #expect(await next.status().access == .connected)
}

@Test func anotherAttemptAndDisconnectClearTheRejectedNotice() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in reply(r.clock) { $0["token"] = "short" } }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    await r.network.add { _ in throw URLError(.timedOut) }
    await #expect(throws: FramebriarError.network) { try await client.connect(invitation: invitation) }
    #expect(await client.status().notice == nil)
    await r.network.add { _ in reply(r.clock) { $0["token"] = "short" } }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    #expect(await client.status().notice == rejectedNotice)
    await r.network.add { _ in json(["v": 1, "disconnected": true]) }
    _ = try await client.disconnect()
    #expect(await client.status().notice == nil)
}

@Test func aFailedReplacementKeepsTheWorkingEnrollmentAndItsNoticeAcrossRefresh() async throws {
    let r = Rig(); let client = try await r.connected()
    let deadline = await client.status().enrollmentExpiresAt
    await r.network.add { _ in reply(r.clock) { $0["gameId"] = "another-game" } }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: String(repeating: "n", count: 43)) }
    #expect(await client.status().notice == rejectedNotice)
    #expect(await client.status().enrollmentExpiresAt == deadline)
    r.clock.advance(3400)
    await r.network.add { _ in reply(r.clock) { $0["refreshExpiresAt"] = iso(deadline!) } }
    try await client.refreshAccess()
    #expect(await client.status().access == .connected)
    #expect(await client.status().notice == rejectedNotice)
}

@Test func aRejectedReplyKeepsTheAttemptForASameInvitationRetry() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    await r.network.add { _ in reply(r.clock) { $0["gameId"] = "another-game" } }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    await r.network.add { _ in access(r.clock, days: 180) }
    try await client.connect(invitation: invitation)
    let requests = await r.network.requests
    #expect(requests.count == 2)
    #expect(try redeemAttempt(requests[0]) == redeemAttempt(requests[1]))
    #expect(await client.status().access == .connected)
    #expect(await client.status().notice == nil)
}

@MainActor @Test func modelCopyDoesNotSuggestRetryingARejectedInvitation() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    let model = FeedbackModel(client: client)
    await r.network.add { _ in reply(r.clock) { $0["gameId"] = "another-game" } }
    await model.connect(invitation)
    #expect(model.message == "This app could not accept the connection response. Ask for a new invitation or update the app.")
    let html = HTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<html>".utf8))
    await r.network.add { _ in html }
    await model.connect(invitation)
    #expect(model.message == "The operation could not be confirmed. Retry the same reviewed report or invitation. If the invitation is refused, ask for a new one.")
}

// The service's reply when its clock reads `server`, however far that is from the client's.
private func issued(at server: Date, days: Double = 30) -> HTTPResponse {
    json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh,
          "expiresAt": iso(server + 3600), "refreshExpiresAt": iso(server + days * 86400)])
}

@Test(arguments: secondsBehindWithinAllowance, [30.0, 180.0]) func aClockBehindWithinTheAllowanceConnects(behind: Double, days: Double) async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    let server = r.clock.now() + behind
    await r.network.add { _ in issued(at: server, days: days) }
    try await client.connect(invitation: invitation)
    #expect(await client.status().access == .connected)
    #expect(await client.status().enrollmentExpiresAt == server + days * 86400)
    // Refresh under the same skew keeps the deadline and stays connected.
    r.clock.advance(3400)
    await r.network.add { _ in json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh,
                                     "expiresAt": iso(r.clock.now() + behind + 3600), "refreshExpiresAt": iso(server + days * 86400)]) }
    try await client.refreshAccess()
    #expect(await client.status().access == .connected)
    #expect(await client.status().enrollmentExpiresAt == server + days * 86400)
}

@Test(arguments: secondsBehindBeyondAllowance) func aClockBehindBeyondTheAllowanceIsRejected(behind: Double) async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    let server = r.clock.now() + behind
    await r.network.add { _ in issued(at: server) }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    #expect(await client.status().noticeReason == "invalid-deadline")
}

@Test func aClockTwoHoursAheadIsRejectedAndRecoversOnceCorrectedInThisProcess() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    let server = r.clock.now()
    r.clock.advance(7200)
    await r.network.add { _ in issued(at: server, days: 180) }
    await #expect(throws: FramebriarError.invalidResponse) { try await client.connect(invitation: invitation) }
    #expect(await client.status().noticeReason == "invalid-deadline")
    r.clock.advance(-7200)
    await r.network.add { _ in issued(at: server, days: 180) }
    try await client.connect(invitation: invitation)
    #expect(await client.status().access == .connected)
    #expect(await client.status().notice == nil)
    let requests = await r.network.requests
    #expect(try redeemAttempt(requests[0]) == redeemAttempt(requests[1]))
}

@Test func aClockAheadAfterRestartHasLostTheAttempt() async throws {
    let r = Rig(); let first = try r.client(); await first.resume()
    let server = r.clock.now()
    r.clock.advance(7200)
    await r.network.add { _ in issued(at: server) }
    await #expect(throws: FramebriarError.invalidResponse) { try await first.connect(invitation: invitation) }
    r.clock.advance(-7200)
    let next = try r.client(); await next.resume()
    await r.network.add { _ in json([:], status: 401) }
    await #expect(throws: FramebriarError.accessRequired) { try await next.connect(invitation: invitation) }
    let requests = await r.network.requests
    #expect(try redeemAttempt(requests[0]) != redeemAttempt(requests[1]))
}
