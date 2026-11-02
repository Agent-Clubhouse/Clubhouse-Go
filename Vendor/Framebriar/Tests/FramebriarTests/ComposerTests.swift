import Foundation
import Testing
@testable import Framebriar
@testable import FramebriarUI

private struct Boom: Error {}
private final class Provider: @unchecked Sendable {
    var calls = 0
    var next: FeedbackDiagnostics?
    var fail = false
}
private let phone = "abcdef01-2345-4678-89ab-cdef01234567"
private let traceID = String(repeating: "a", count: 32), spanID = String(repeating: "b", count: 16)

@MainActor private struct ComposerRig {
    let r = Rig()
    let provider = Provider()
    var reports: [Data] {
        get async {
            let requests: [URLRequest] = await r.network.requests
            return requests.filter { $0.url!.path.hasSuffix("/v1/reports") }.map { $0.httpBody! }
        }
    }

    func entries(_ n: Int = 3) -> FeedbackDiagnostics {
        let at = r.clock.now()
        let list: [FeedbackDiagnostics.Entry] = (0..<n).map { (i: Int) in
            FeedbackDiagnostics.Entry(at: at - Double(i), level: .error, ns: "transport", event: "connect.failed",
                                      attrs: ["failure": "timeout", "traceId": .string(traceID), "spanId": .string(spanID)])
        }
        return FeedbackDiagnostics(windowStart: at - 60, windowEnd: at, entries: list)
    }
    func incident() throws -> FeedbackIncident {
        try FeedbackIncident(capturedAt: r.clock.now(), windowStart: r.clock.now() - 60, availability: .recorded, phoneInstanceId: phone,
                             traces: [.init(traceId: traceID, spanId: spanID)])
    }
    func model(_ client: Client, telemetry: Telemetry? = nil, withProvider: Bool = true, withIncident: Bool = false) throws -> FeedbackModel {
        let provider = provider
        let snapshot: FeedbackIncident? = withIncident ? try incident() : nil
        let clock = r.clock
        let source: (@MainActor () throws -> FeedbackDiagnostics?) = {
            provider.calls += 1
            if provider.fail { throw Boom() }
            return provider.next
        }
        return FeedbackModel(client: client, telemetry: telemetry, incidentProvider: { snapshot },
                             diagnosticsProvider: withProvider ? source : nil, now: { clock.now() })
    }
    func connected(correlation: Bool = false) async throws -> Client {
        let client = try r.client(); await client.resume()
        await r.network.add { [clock = r.clock] _ in
            var body: [String: Any] = ["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh,
                                       "expiresAt": iso(clock.now() + 3600), "refreshExpiresAt": iso(clock.now() + 30 * 86400)]
            if correlation { body["feedbackCorrelationVersion"] = 1 }
            return json(body)
        }
        try await client.connect(invitation: invitation)
        return client
    }
}
private func parsed(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

// MARK: capture states

@MainActor @Test func providerResultsMapToTheFourStates() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client)
    rig.provider.next = rig.entries(2)
    let attached = model.openDraft()
    #expect(attached.capturedDiagnostics.state == .attached && attached.capturedDiagnostics.lines == 2)
    rig.provider.next = nil
    let none = model.openDraft().capturedDiagnostics
    #expect(none.state == .none && none.reason == "empty")
    rig.provider.next = .unavailable(reason: "provider-failed")
    #expect(model.openDraft().capturedDiagnostics.state == .unavailable)
    rig.provider.fail = true
    let failed = model.openDraft().capturedDiagnostics
    #expect(failed.state == .unavailable && failed.reason == "provider-failed")
    #expect(attached.diagnostics(included: false).state == .left_out)
    let plain = try rig.model(client, withProvider: false)
    let noProvider = plain.openDraft().capturedDiagnostics
    #expect(noProvider.state == .none && noProvider.reason == "no-provider")
}

@MainActor @Test func aFailingOrUnusableProviderNeverBlocksSend() async throws {
    for setup in [{ (p: Provider) in p.fail = true },
                  { p in p.next = .leftOut() },
                  { p in p.next = FeedbackDiagnostics(windowStart: Date(), windowEnd: Date(), entries: [.init(at: Date(), level: .info, ns: "bad ns", event: "e")]) }] {
        let rig = ComposerRig(); let client = try await rig.connected()
        let model = try rig.model(client); setup(rig.provider)
        await model.update()
        let draft = model.openDraft()
        await rig.r.network.add { ack($0) }
        #expect(await model.send(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .sent)
        let wire = try parsed(await rig.reports[0])["diagnostics"] as! [String: Any]
        #expect(wire["state"] as? String == "unavailable" && (wire["entries"] as! [Any]).isEmpty)
    }
}

@MainActor @Test func deliveryStateComesFromTheClientAndIsFrozenAtOpen() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); rig.provider.next = rig.entries()
    await model.update()
    #expect(model.openDraft().capturedDiagnostics.delivery == .init(queued: 0, lastResult: "none"))
    let first = model.openDraft()
    #expect(await model.send(first, notes: "first", screenshotPNG: nil, includeDiagnostics: true) == .saved(.offline))
    let second = model.openDraft()
    #expect(second.capturedDiagnostics.delivery == .init(queued: 1, lastResult: "offline"), "A report filed while the connection is down says so")
    #expect(second.capturedDiagnostics.entries.count == 3, "and keeps its failure entries")
}

@MainActor @Test func reentrantCaptureNeverRunsTheProviderTwice() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let clock = rig.r.clock
    var calls = 0, nested: FeedbackDraft?
    var holder: FeedbackModel?
    let entries = rig.entries(1)
    let model = FeedbackModel(client: client, diagnosticsProvider: {
        calls += 1
        nested = holder?.openDraft() // e.g. expiring a span notifies an observer that opens feedback
        return entries
    }, now: { clock.now() })
    holder = model
    let draft = model.openDraft()
    #expect(calls == 1)
    #expect(draft.capturedDiagnostics.state == .attached, "The outer capture is unaffected")
    #expect(nested?.capturedDiagnostics.state == .unavailable && nested?.capturedDiagnostics.entries.isEmpty == true)
    _ = model.openDraft()
    #expect(calls == 2, "The guard resets once the capture ends")
}

@MainActor @Test func theSwitchNeverRecaptures() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); rig.provider.next = rig.entries(3)
    let draft = model.openDraft()
    rig.provider.next = rig.entries(9)
    for include in [false, true, false, true] {
        _ = draft.diagnostics(included: include)
        _ = draft.summary(notes: "n", hasScreenshot: false, includeDiagnostics: include)
    }
    #expect(rig.provider.calls == 1)
    #expect(draft.diagnostics(included: true).entries.count == 3)
}

// MARK: telemetry fallback

@MainActor @Test func withNoProviderTheTelemetryRingIsMappedThroughTheAllowlist() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let t = try Telemetry(client: client, configuration: rig.r.config, commonAttributes: ["app.platform": "ios"], transport: rig.r.network,
                          observeAppLifecycle: false, now: rig.r.clock.now, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }, random: { 0 })
    let model = try rig.model(client, telemetry: t, withProvider: false)
    #expect(model.openDraft().capturedDiagnostics.reason == "empty", "A ring with nothing in it is none/empty")
    t.log(.error, "app.error", ["error.type": "timeout", "attempt": 2, "http.response.status_code": 503, "prompt": "never"])
    let span = t.startSpan("app.flow"); rig.r.clock.advance(1); span.setStatus(.error); span.end()
    await rig.r.network.add { _ in json([:]) }
    await rig.r.network.add { _ in json([:]) }
    _ = await t.flush()
    #expect(t.stats().sent == 2)
    let value = model.openDraft().capturedDiagnostics
    #expect(value.state == .attached && value.lines == 2, "Already-exported events are still in the report's own copy")
    let log = value.entries[0]
    #expect(log.level == .error && log.ns == "app" && log.event == "app.error")
    #expect(log.attrs?["failure"] == .string("timeout") && log.attrs?["statusCode"] == .number(503) && log.attrs?["attempt"] == .number(2))
    #expect(log.attrs?["prompt"] == nil)
    #expect(value.droppedAttrs >= 3, "prompt and app.platform on the log, app.platform on the span")
    let spanEntry = value.entries[1]
    #expect(spanEntry.level == .error && spanEntry.attrs?["traceId"] == .string(span.context.traceID) && spanEntry.attrs?["durationMs"] == .number(1000))
    #expect(t.stats().sent == 2 && t.stats().buffered == 0, "Reading the ring changes nothing")
}

// MARK: wire-byte proofs across offline retries and relaunch

/// Open, choose the switch, Send offline, fail once more after a relaunch, then succeed after another.
/// Returns every report POST's exact bytes. Uses the real file store, so the round trip is real.
@MainActor private func offlineRelaunchRun(include: Bool, png: Data? = nil) async throws -> (bodies: [Data], rig: ComposerRig, frozen: FeedbackDiagnostics) {
    let rig = ComposerRig(); let r = rig.r
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framebriar-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deadline = r.clock.now() + 30 * 86400
    let reply: @Sendable (URLRequest) async throws -> HTTPResponse = { [clock = r.clock] _ in
        json(["v": 1, "scopeVersion": 2, "gameId": "test-app", "token": bearer, "refreshToken": refresh, "feedbackCorrelationVersion": 1,
              "expiresAt": iso(clock.now() + 3600), "refreshExpiresAt": iso(deadline)])
    }
    func client() throws -> Client {
        try Client(configuration: r.config, transport: r.network, enrollmentStore: r.enrollment,
                   feedbackStore: FileFeedbackStore(directory: directory), now: r.clock.now)
    }
    let first = try client(); await first.resume()
    await r.network.add(reply); try await first.connect(invitation: invitation)

    let model = try rig.model(first, withIncident: true)
    rig.provider.next = rig.entries(3)
    await model.update()
    let draft = model.openDraft()
    #expect(await model.send(draft, notes: "It broke", screenshotPNG: png, includeDiagnostics: include) == .saved(.offline))

    // The provider would answer differently now. Nothing may ask it.
    rig.provider.next = rig.entries(9)
    r.clock.advance(1000)
    let second = try client(); await second.resume()
    await r.network.add(reply)
    await r.network.add { _ in throw FramebriarError.network }
    try await second.flush()
    #expect(await second.status().queued == 1)

    r.clock.advance(1000)
    let third = try client(); await third.resume()
    await r.network.add(reply)
    await r.network.add { ack($0, status: "ready") }
    try await third.flush()
    #expect(await third.status().queued == 0)
    #expect(await third.status().lastReceivedID == draft.id)
    #expect(rig.provider.calls == 1, "Captured once, at open")
    return (await rig.reports, rig, draft.capturedDiagnostics)
}

@MainActor @Test func switchedOffBytesCarryLeftOutAndNothingElseAtEveryRetry() async throws {
    let (bodies, _, _) = try await offlineRelaunchRun(include: false)
    #expect(bodies.count == 3, "The first attempt and two retries after relaunches")
    #expect(bodies.allSatisfy { $0 == bodies[0] }, "Byte-identical across retries")
    for body in bodies {
        let raw = text(body)
        #expect(raw.contains("\"state\":\"left_out\""))
        #expect(!raw.contains("\"incident\"") && !raw.contains("traceId") && !raw.contains("spanId") && !raw.contains("connect.failed"))
        #expect(!raw.contains("\"delivery\""))
        let report = try parsed(body)
        let diagnostics = report["diagnostics"] as! [String: Any]
        #expect((diagnostics["entries"] as! [Any]).isEmpty && diagnostics["lines"] as? Int == 0)
        #expect(diagnostics["reason"] == nil, "Never a failure state")
        #expect(report["notes"] as? String == "It broke" && report["gameId"] as? String == "test-app" && report["buildSha"] as? String == "abcdef0")
        #expect(report["sessionId"] as? String == FramebriarSession.id)
    }
}

@MainActor @Test func switchedOffKeepsTheImage() async throws {
    let png = Data([137,80,78,71,13,10,26,10,0,1,2,3])
    let (bodies, _, _) = try await offlineRelaunchRun(include: false, png: png)
    #expect((try parsed(bodies[0])["media"] as? [String: Any])?["sha256"] as? String == digest(png))
    #expect(text(bodies[0]).contains("\"state\":\"left_out\""))
}

@MainActor @Test func switchedOnBytesStayFrozenWhenTheProviderWouldNowDiffer() async throws {
    let (bodies, _, frozen) = try await offlineRelaunchRun(include: true)
    #expect(bodies.count == 3)
    #expect(bodies.allSatisfy { $0 == bodies[0] }, "Byte-identical across retries")
    let report = try parsed(bodies.last!)
    let diagnostics = report["diagnostics"] as! [String: Any]
    #expect(diagnostics["state"] as? String == "attached" && (diagnostics["entries"] as! [Any]).count == 3, "The original three, not the nine now on offer")
    #expect(diagnostics["windowEnd"] as? String == frozen.windowEnd)
    #expect(report["traceId"] as? String == traceID && report["spanId"] as? String == spanID && report["incident"] != nil)
}

// MARK: summary truth

@MainActor @Test func summaryMatchesWhatGoesOnTheWire() async throws {
    let png = Data([137,80,78,71,13,10,26,10,0,1,2,3])
    let cases: [(notes: String, image: Data?, include: Bool, incident: Bool, expected: String)] = [
        ("n", png, true, true, "Included: note · screenshot · recent diagnostics (3 events) · incident references"),
        ("n", nil, true, true, "Included: note · recent diagnostics (3 events) · incident references"),
        ("", png, true, false, "Included: screenshot · recent diagnostics (3 events)"),
        ("n", png, false, true, "Included: note · screenshot · diagnostics left out"),
        ("n", nil, false, false, "Included: note · diagnostics left out")
    ]
    for item in cases {
        let rig = ComposerRig(); let client = try await rig.connected(correlation: true)
        let model = try rig.model(client, withIncident: item.incident); rig.provider.next = rig.entries(3)
        let draft = model.openDraft()
        let summary = draft.summary(notes: item.notes, hasScreenshot: item.image != nil, includeDiagnostics: item.include)
        #expect(summary == item.expected)
        let report = try draft.report(configuration: rig.r.config, notes: item.notes, screenshotPNG: item.image, includeDiagnostics: item.include)
        let wire = try parsed(try report.wire())
        let diagnostics = wire["diagnostics"] as! [String: Any]
        #expect(summary.contains("(\((diagnostics["entries"] as! [Any]).count) events)") == (diagnostics["state"] as? String == "attached"))
        #expect(summary.contains("left out") == (diagnostics["state"] as? String == "left_out"))
        #expect(summary.contains("incident references") == (wire["incident"] != nil))
        #expect(summary.contains("screenshot") == !(wire["media"] is NSNull))
    }
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); rig.provider.next = rig.entries(1)
    #expect(model.openDraft().summary(notes: "", hasScreenshot: true, includeDiagnostics: true) == "Included: screenshot · recent diagnostics (1 event)")
    rig.provider.next = nil
    #expect(model.openDraft().summary(notes: "n", hasScreenshot: false, includeDiagnostics: true) == "Included: note · no diagnostics recorded")
    rig.provider.fail = true
    #expect(model.openDraft().summary(notes: "n", hasScreenshot: false, includeDiagnostics: true) == "Included: note · diagnostics unavailable")
}

@Test func telemetryNoteOnlyPromisesWhatTheSwitchDoes() {
    #expect(FeedbackDisclosure.telemetryNote(enabled: false, excerptOnly: false, includeDiagnostics: true) == nil)
    #expect(FeedbackDisclosure.telemetryNote(enabled: true, excerptOnly: false, includeDiagnostics: false)!.contains("doesn't stop the regular telemetry"))
    #expect(!FeedbackDisclosure.telemetryNote(enabled: true, excerptOnly: true, includeDiagnostics: false)!.contains("regular telemetry"))
}

@MainActor @Test func switchedOffSendsNoTelemetryExcerpt() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let t = try Telemetry(client: client, configuration: rig.r.config, mode: .excerptOnly, transport: rig.r.network, observeAppLifecycle: false,
                          now: rig.r.clock.now, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }, random: { 0 })
    t.log(.error, "app.error")
    let model = try rig.model(client, telemetry: t); rig.provider.next = rig.entries(1)
    await model.update()
    await rig.r.network.add { ack($0) }
    await rig.r.network.add { _ in json([:]) }
    #expect(await model.send(model.openDraft(), notes: "n", screenshotPNG: nil, includeDiagnostics: false) == .sent)
    var logs: [URLRequest] = []
    for _ in 0..<500 where logs.isEmpty {
        try? await Task.sleep(nanoseconds: 2_000_000)
        let requests: [URLRequest] = await rig.r.network.requests
        logs = requests.filter { $0.url!.lastPathComponent == "logs" }
    }
    let raw = text(try #require(logs.first?.httpBody))
    #expect(raw.contains("feedback.submitted") && !raw.contains("app.error"), "Only the marker")
}

// MARK: outcomes

@MainActor private func outcome(correlation: Bool = false, withIncident: Bool = false, _ arrange: (ComposerRig, Client) async throws -> Void) async throws -> (FeedbackDeliveryOutcome, ComposerRig, Client) {
    let rig = ComposerRig(); let client = try await rig.connected(correlation: correlation)
    let model = try rig.model(client, withIncident: withIncident)
    try await arrange(rig, client)
    await model.update()
    return (await model.send(model.openDraft(), notes: "n", screenshotPNG: nil, includeDiagnostics: true), rig, client)
}

@MainActor @Test func sentMeansTheServiceConfirmed() async throws {
    let (result, _, client) = try await outcome { rig, _ in await rig.r.network.add { ack($0) } }
    #expect(result == .sent && FeedbackDisclosure.title(result) == "Sent")
    #expect(await client.status().queued == 0)
    #expect(await client.status().lastDeliveryResult == "ok")
}

@MainActor @Test func sentCoversTheImageUpload() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); await model.update()
    await rig.r.network.add { ack($0, status: "pending") }
    let draft = model.openDraft()
    await rig.r.network.add { [id = draft.id] _ in json(["id": id.uuidString.lowercased(), "status": "ready", "gameId": "test-app"]) }
    #expect(await model.send(draft, notes: "", screenshotPNG: Data([137,80,78,71,13,10,26,10,0,1,2,3]), includeDiagnostics: true) == .sent)
}

@MainActor @Test func offlineIsSavedAndKept() async throws {
    let (result, _, client) = try await outcome { _, _ in }
    #expect(result == .saved(.offline) && FeedbackDisclosure.title(result) == "Saved, will send when online")
    #expect(await client.status().queued == 1)
    #expect(await client.status().lastDeliveryResult == "offline")
}

@MainActor @Test func serverTroubleIsSavedForRetry() async throws {
    let (result, _, client) = try await outcome { rig, _ in await rig.r.network.add { _ in json([:], status: 503) } }
    #expect(result == .saved(.serviceBusy))
    #expect(await client.status().queued == 1)
}

@MainActor @Test func pausedIsSavedWithoutARequest() async throws {
    let (result, rig, client) = try await outcome { _, client in await client.pause() }
    #expect(result == .saved(.paused))
    #expect(await client.status().queued == 1)
    #expect(await rig.reports.isEmpty)
}

@MainActor @Test func incidentHeldForCapabilityIsSavedNotSent() async throws {
    let (result, rig, client) = try await outcome(correlation: false, withIncident: true) { _, _ in }
    #expect(result == .saved(.waitingForService))
    #expect(await client.status().queued == 1)
    #expect(await rig.reports.isEmpty)
}

@MainActor @Test func rejectionNeedsAttentionAndKeepsTheReport() async throws {
    let (result, _, client) = try await outcome { rig, _ in await rig.r.network.add { _ in json([:], status: 400) } }
    #expect(result == .needsAttention(.rejected) && FeedbackDisclosure.title(result) == "Needs attention")
    #expect(await client.status().queued == 1)
    #expect(await client.status().blocked == 1)
    #expect(await client.status().lastDeliveryResult == "protocol")
}

@MainActor @Test func revokedAccessNeedsAttentionAndKeepsTheReport() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); await model.update()
    rig.r.clock.advance(3500) // past the renewal point, so sending refreshes
    await rig.r.network.add { _ in json([:], status: 401) }
    #expect(await model.send(model.openDraft(), notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .needsAttention(.accessRequired))
    #expect(await client.status().queued == 1)
}

@MainActor @Test func aFailedLocalSaveKeepsTheDraftSendableWithTheSameID() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); await model.update()
    let draft = model.openDraft()
    rig.r.queue.fail = true
    #expect(await model.send(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .needsAttention(.storageUnavailable))
    #expect(await rig.reports.isEmpty, "Never sends what isn't saved")
    rig.r.queue.fail = false
    await rig.r.network.add { ack($0) }
    #expect(await model.send(draft, notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .sent)
    #expect(await client.status().lastReceivedID == draft.id)
}

@MainActor @Test func aFullQueueRefusesWithoutEvicting() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); await client.pause()
    for _ in 0..<ClientStatus.maxItems { #expect(await model.send(model.openDraft(), notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .saved(.paused)) }
    #expect(await model.send(model.openDraft(), notes: "n", screenshotPNG: nil, includeDiagnostics: true) == .needsAttention(.storageFull))
    #expect(await client.status().queued == ClientStatus.maxItems)
    #expect(FeedbackSendBlock.evaluate(status: await client.status(), notes: "n", hasScreenshot: false, preparingImage: false, saving: false) == .queueFull)
}

@MainActor @Test func deliverOnlyAttemptsTheNewReport() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); await model.update()
    #expect(await model.send(model.openDraft(), notes: "older", screenshotPNG: nil, includeDiagnostics: true) == .saved(.offline))
    await rig.r.network.add { ack($0) }
    #expect(await model.send(model.openDraft(), notes: "newer", screenshotPNG: nil, includeDiagnostics: true) == .sent)
    let sent = await rig.reports
    #expect(sent.count == 2)
    #expect(try parsed(sent[1])["notes"] as? String == "newer")
    #expect(await client.status().queued == 1, "The older one waits for the next foreground flush")
}

@MainActor @Test func deliverWaitsOutAConcurrentPass() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client); await model.update()
    await rig.r.network.add { request in try? await Task.sleep(nanoseconds: 150_000_000); return ack(request) }
    let older = try rig.r.review("older")
    try await client.enqueue(older)
    let flush = Task { try await client.flush() }
    try await Task.sleep(nanoseconds: 30_000_000)
    await rig.r.network.add { ack($0) }
    let result = await model.send(model.openDraft(), notes: "newer", screenshotPNG: nil, includeDiagnostics: true)
    try await flush.value
    #expect(result == .sent)
}

@Test func everyNotSavedErrorHasItsOwnHonestMessage() {
    #expect(FeedbackModel.notSaved(FramebriarError.busy) == .busy)
    #expect(FeedbackModel.notSaved(FramebriarError.capacity) == .storageFull)
    #expect(FeedbackModel.notSaved(FramebriarError.storage) == .storageUnavailable)
    #expect(FeedbackModel.notSaved(FramebriarError.expired) == .notEnrolled)
    #expect(FeedbackModel.notSaved(FramebriarError.invalidInput) == .invalidReport)
    for reason: FeedbackDeliveryOutcome.AttentionReason in [.busy, .storageFull, .storageUnavailable, .notEnrolled, .invalidReport] {
        #expect(FeedbackDisclosure.detail(.needsAttention(reason)).hasPrefix("Not saved:"))
    }
}

@Test func diagnosticsCopyDoesNotPromiseWhatTheSDKCannotGuarantee() {
    #expect(FeedbackDisclosure.diagnosticsMeaning.contains("not free text, and are designed not to include your messages or file paths."))
    for hasTelemetry in [true, false] {
        let text = FeedbackDisclosure.enrollment(hasTelemetry: hasTelemetry, sendsDiagnostics: true)
        #expect(text.contains("designed not to include"))
        #expect(!text.contains("never") && !text.contains("No prompts"))
    }
}

@Test func queuedCopyIsHonestThatDeliveryNeedsTheAppOpen() {
    #expect(FeedbackDisclosure.detail(.saved(.offline)) == "Saved. It will send when the app is open and online.")
    for reason: FeedbackDeliveryOutcome.SavedReason in [.offline, .paused, .serviceBusy, .waitingForService] {
        #expect(FeedbackDisclosure.detail(.saved(reason)).contains("app is open"))
    }
    #expect(FeedbackDisclosure.sendingDetail.contains("app is open"))
}

@Test func sendBlockReasonsAreVisibleAndOrdered() {
    let ok = ClientStatus(access: .connected, canSubmit: true, enrollmentExpiresAt: nil, queued: 0, queuedBytes: 0, blocked: 0, lastReceivedID: nil)
    let no = ClientStatus(access: .disconnected, canSubmit: false, enrollmentExpiresAt: nil, queued: 0, queuedBytes: 0, blocked: 0, lastReceivedID: nil)
    func block(_ status: ClientStatus?, _ notes: String = "n", image: Bool = false, preparing: Bool = false, saving: Bool = false) -> FeedbackSendBlock? {
        FeedbackSendBlock.evaluate(status: status, notes: notes, hasScreenshot: image, preparingImage: preparing, saving: saving)
    }
    #expect(block(ok) == nil)
    #expect(block(ok, "", image: true) == nil)
    #expect(block(ok, " \n") == .empty)
    #expect(block(nil) == .checkingAccess)
    #expect(block(no) == .notEnrolled)
    #expect(block(ok, String(repeating: "x", count: 2001)) == .notesTooLong)
    #expect(block(ok, preparing: true) == .preparingImage)
    #expect(block(ok, saving: true) == .saving)
    for reason in [FeedbackSendBlock.checkingAccess, .notEnrolled, .empty, .notesTooLong, .queueFull, .preparingImage, .saving] {
        #expect(!FeedbackDisclosure.sendBlocked(reason).isEmpty)
    }
}

// MARK: deprecated API stays source-compatible

@available(*, deprecated)
@MainActor @Test func oldSubmitStillWorks() async throws {
    let rig = ComposerRig(); let client = try await rig.connected()
    let model = try rig.model(client)
    #expect(await model.submit(try rig.r.review()))
    #expect(await client.status().queued == 1)
    #expect(model.message == "Saved on this device. Delivery is confirmed separately.")
}
