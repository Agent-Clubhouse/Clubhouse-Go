import Foundation
import Testing
@testable import Framebriar

private let idle: @Sendable (TimeInterval) async -> Void = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }

private func telemetry(_ r: Rig, _ client: Client, mode: Telemetry.Mode = .continuous,
                       sleep: @escaping @Sendable (TimeInterval) async -> Void = idle) throws -> Telemetry {
    try Telemetry(client: client, configuration: r.config, mode: mode, appVersion: "1.2.0", appBuild: "42",
                  commonAttributes: ["app.telemetry.schema_version": 1, "app.platform": "ios"],
                  transport: r.network, observeAppLifecycle: false, now: r.clock.now, sleep: sleep, random: { 0 })
}
private func accepted(_ request: URLRequest) -> HTTPResponse { json([:]) }
private func body(_ request: URLRequest) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
}
private func signal(_ request: URLRequest) -> String { request.url!.lastPathComponent }
private func resource(_ value: [String: Any], _ key: String) -> [String: Any] {
    let blocks = value[key] as! [[String: Any]]
    let attrs = (blocks[0]["resource"] as! [String: Any])["attributes"] as! [[String: Any]]
    return Dictionary(uniqueKeysWithValues: attrs.map { ($0["key"] as! String, ($0["value"] as! [String: Any]).values.first!) })
}
private func items(_ value: [String: Any], _ resourceKey: String, _ scopeKey: String, _ itemKey: String) -> [[String: Any]] {
    let blocks = value[resourceKey] as! [[String: Any]]
    return ((blocks[0][scopeKey] as! [[String: Any]])[0][itemKey] as! [[String: Any]])
}
private func attrs(_ item: [String: Any]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: (item["attributes"] as! [[String: Any]]).map { ($0["key"] as! String, ($0["value"] as! [String: Any]).values.first!) })
}
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 { if await condition() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }
    return false
}
private func telemetryRequests(_ r: Rig) async -> [URLRequest] {
    await r.network.requests.filter { $0.url!.path.contains("/v1/otlp/") }
}

@Test func notEnrolledRecordsAndSendsNothing() async throws {
    let r = Rig(); let client = try r.client(); await client.resume()
    let t = try telemetry(r, client)
    #expect(!t.isEnabled)
    t.log(.info, "app.session.start")
    let span = t.startSpan("app.flow"); span.addEvent("found"); span.end()
    #expect(!span.isRecording && span.context.traceID.isEmpty)
    t.counter("app.actions").add(1)
    #expect(await t.flush() == false)
    #expect(await r.network.count() == 0)
    #expect(t.stats().buffered == 0 && t.stats().ringLogs == 0)
    #expect(await client.telemetryToken() == nil)
}

@Test func encodesOTLPJSONForEachSignalWithResourceAndEvents() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.warn, "app.error", ["app.error.class": "timeout", "attempt": 2])
    let parent = t.startSpan("app.flow", attributes: ["app.flow.name": "pair"], kind: .client)
    let child = t.startSpan("connect", parent: parent.context)
    child.addEvent("firstToken", ["latency_ms": 120]).setStatus(.ok).end()
    parent.end()
    t.counter("app.reconnects", unit: "{reconnect}").add(2, ["reason": "network"])
    t.histogram("app.first_token", unit: "ms").record(120)
    t.gauge("app.queue_depth").record(3)
    for _ in 0..<3 { await r.network.add(accepted) }
    #expect(await t.flush())
    let sent = await telemetryRequests(r)
    #expect(sent.map(signal) == ["traces", "logs", "metrics"])
    for request in sent {
        #expect(request.url!.absoluteString.hasPrefix("https://framebriar-masra91-poc.azurewebsites.net/api/v1/otlp/v1/"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(bearer)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
    let traces = body(sent[0])
    let res = resource(traces, "resourceSpans")
    #expect(res["service.version"] as? String == "1.2.0+42")
    #expect(res["session.id"] as? String == t.sessionID && t.sessionID == FramebriarSession.id)
    #expect(res["telemetry.sdk.language"] as? String == "swift" && res["service.name"] as? String == "test-app")
    let spans = items(traces, "resourceSpans", "scopeSpans", "spans")
    #expect(spans.count == 2)
    let c = spans[0], p = spans[1]
    #expect(c["traceId"] as? String == p["traceId"] as? String && c["parentSpanId"] as? String == p["spanId"] as? String)
    #expect((c["traceId"] as! String).count == 32 && (c["spanId"] as! String).count == 16)
    #expect(((c["events"] as! [[String: Any]])[0]["name"] as? String) == "firstToken")
    #expect((c["status"] as! [String: Any])["code"] as? Int == 1)
    #expect(p["kind"] as? Int == 3 && p["events"] == nil)
    #expect(attrs(p)["app.telemetry.schema_version"] as? String == "1" && attrs(p)["app.flow.name"] as? String == "pair")
    #expect(BigInt(c["endTimeUnixNano"]) >= BigInt(c["startTimeUnixNano"]))
    let log = items(body(sent[1]), "resourceLogs", "scopeLogs", "logRecords")[0]
    #expect(log["severityNumber"] as? Int == 13 && log["severityText"] as? String == "WARN")
    #expect((log["body"] as! [String: Any])["stringValue"] as? String == "app.error")
    #expect(attrs(log)["attempt"] as? String == "2" && attrs(log)["app.platform"] as? String == "ios")
    let metrics = Dictionary(uniqueKeysWithValues: items(body(sent[2]), "resourceMetrics", "scopeMetrics", "metrics").map { ($0["name"] as! String, $0) })
    let sum = metrics["app.reconnects"]!["sum"] as! [String: Any]
    #expect(sum["aggregationTemporality"] as? Int == 1 && sum["isMonotonic"] as? Bool == true)
    #expect(((sum["dataPoints"] as! [[String: Any]])[0]["asDouble"] as? Double) == 2)
    let hist = metrics["app.first_token"]!["exponentialHistogram"] as! [String: Any]
    let point = (hist["dataPoints"] as! [[String: Any]])[0]
    #expect(hist["aggregationTemporality"] as? Int == 1 && point["count"] as? String == "1" && point["scale"] as? Int == 8)
    #expect(metrics["app.queue_depth"]!["gauge"] != nil)
    #expect(t.stats().sent == 6 && t.stats().buffered == 0)
}
private func BigInt(_ value: Any?) -> UInt64 { UInt64(value as! String)! }

@Test func scrubsValuesAndDropsSecretKeys() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action", ["where": "/Users/someone/repo/file.swift", "who": "a@b.example", "auth_token": "x", "framebriar.app.id": "spoof",
                                "firstTokenMs": 120, "tokens.count": 9, "access_token_ms": 1, "refresh.token": "y"])
    await r.network.add(accepted)
    await t.flush()
    let a = attrs(items(body(await telemetryRequests(r)[0]), "resourceLogs", "scopeLogs", "logRecords")[0])
    #expect(a["where"] as? String == "[path]" && a["who"] as? String == "[email]")
    #expect(a["auth_token"] == nil && a["framebriar.app.id"] == nil && a["access_token_ms"] == nil && a["refresh.token"] == nil)
    #expect(a["firstTokenMs"] as? String == "120" && a["tokens.count"] as? String == "9")
}

@Test func batchesOnTimerAndAtItemThreshold() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.session.start")
    #expect(t.stats().nextFlushAt == r.clock.now().addingTimeInterval(60))
    #expect(await r.network.count() == 1) // redeem only: nothing sent before the window closes
    await r.network.add(accepted)
    for _ in 0..<199 { t.log(.info, "app.action") }
    #expect(await eventually { await telemetryRequests(r).count == 1 })
    let logs = items(body(await telemetryRequests(r)[0]), "resourceLogs", "scopeLogs", "logRecords")
    #expect(logs.count == 200)
}

@Test func timerFlushesWithoutHostCalls() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client, sleep: { _ in await Task.yield() })
    await r.network.add(accepted)
    t.log(.info, "app.session.start")
    #expect(await eventually { await telemetryRequests(r).count == 1 })
}

@Test func unauthorizedRefreshesOnceThenRetries() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action")
    await r.network.add { _ in json(["error": "Unauthorized"], status: 401) }
    await r.network.add { request in
        #expect(request.url!.path.hasSuffix("/v1/access/refresh"))
        return access(r.clock)
    }
    await r.network.add(accepted)
    #expect(await t.flush())
    #expect(await telemetryRequests(r).count == 2 && t.stats().sent == 1)
}

@Test func forbiddenStopsUntilReenrollment() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action")
    await r.network.add { _ in json(["error": "off"], status: 403) }
    #expect(await t.flush() == false)
    #expect(t.stats().forbidden && !t.isEnabled && t.stats().buffered == 0)
    t.log(.info, "app.action")
    #expect(await t.flush() == false && t.stats().buffered == 0)
    #expect(await telemetryRequests(r).count == 1)
    // Disconnect and a fresh invitation lift the stop.
    await r.network.add { _ in json(["v": 1, "disconnected": true]) }
    _ = try await client.disconnect()
    await r.network.add { _ in access(r.clock) }
    try await client.connect(invitation: invitation)
    #expect(t.isEnabled)
}

@Test func tooLargeSplitsTheBatch() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    for _ in 0..<4 { t.log(.info, "app.action") }
    await r.network.add { _ in json([:], status: 413) }
    await r.network.add(accepted); await r.network.add(accepted)
    #expect(await t.flush() == false)
    #expect(t.stats().buffered == 4)
    #expect(await t.flush())
    #expect(t.stats().buffered == 2)
    #expect(await t.flush())
    let sizes = await telemetryRequests(r).map { items(body($0), "resourceLogs", "scopeLogs", "logRecords").count }
    #expect(sizes == [4, 2, 2])
}

@Test func tooManyRequestsHonorsRetryAfterAndKeepsData() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action")
    await r.network.add { _ in json(["error": "Quota reached"], status: 429, headers: ["content-type": "application/json", "retry-after": "120"]) }
    #expect(await t.flush() == false)
    #expect(t.stats().blockedUntil == r.clock.now().addingTimeInterval(120) && t.stats().buffered == 1)
    #expect(await t.flush() == false)
    #expect(await telemetryRequests(r).count == 1)
    r.clock.advance(121); await r.network.add(accepted)
    #expect(await t.flush())
    #expect(t.stats().buffered == 0)
}

@Test func unavailableBacksOffAndBadRequestDrops() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action")
    await r.network.add { _ in json([:], status: 503) }
    #expect(await t.flush() == false)
    #expect(t.stats().blockedUntil == r.clock.now().addingTimeInterval(5) && t.stats().buffered == 1)
    r.clock.advance(6)
    await r.network.add { _ in json([:], status: 400) }
    #expect(await t.flush())
    #expect(t.stats().buffered == 0 && t.stats().dropped == 1)
}

@Test func disconnectClearsQueueRingAndStopsSending() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action"); t.counter("app.actions").add(1)
    #expect(t.stats().buffered == 1 && t.stats().series == 1 && t.stats().ringLogs == 1)
    await r.network.add { _ in json(["v": 1, "disconnected": true]) }
    #expect(try await client.disconnect())
    #expect(!t.isEnabled && t.stats().buffered == 0 && t.stats().series == 0 && t.stats().ringLogs == 0)
    t.log(.info, "app.action")
    #expect(await t.flush() == false)
    #expect(await telemetryRequests(r).isEmpty)
}

@Test func revokedRefreshStopsTelemetry() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    r.clock.advance(3400) // access token inside its final five minutes
    t.log(.info, "app.action")
    await r.network.add { _ in json(["error": "revoked"], status: 401) }
    #expect(await t.flush() == false)
    #expect(!t.isEnabled && t.stats().buffered == 0)
    #expect(await telemetryRequests(r).isEmpty)
}

@Test func backgroundFlushUsesCachedTokenWhilePaused() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.session.start")
    await r.network.add(accepted)
    #expect(await t.flush())
    t.log(.info, "app.session.end")
    await client.pause()
    #expect(await t.flush() == false) // a normal pass gets no token from a paused client
    await r.network.add(accepted)
    #expect(await t.flushForBackground())
    let sent = await telemetryRequests(r)
    #expect(sent.count == 2 && sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(bearer)")
}

@Test func backgroundFlushKeepsDataWhenTokenIsRejected() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    t.log(.info, "app.action")
    await r.network.add(accepted)
    await t.flush()
    t.log(.info, "app.session.end")
    await client.pause()
    await r.network.add { _ in json([:], status: 401) }
    #expect(await t.flushForBackground() == false)
    #expect(t.stats().buffered == 1)
}

@Test func feedbackSubmittedTagsExcerptAndMarksTheReport() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    let span = t.startSpan("app.flow"); span.end()
    t.log(.info, "app.action")
    await r.network.add(accepted); await r.network.add(accepted)
    #expect(await t.flush())
    t.log(.error, "app.error", ["app.error.class": "timeout"]) // queued, not yet sent
    let report = try r.review()
    #expect(report.sessionID == t.sessionID)
    try await client.enqueue(report)
    let trace = t.recentTraces().first!
    #expect(trace.traceId == span.context.traceID)
    await r.network.add(accepted)
    #expect(await t.feedbackSubmitted(reportID: report.id, trace: trace))
    let sent = await telemetryRequests(r)
    #expect(sent.count == 3 && signal(sent[2]) == "logs")
    let logs = items(body(sent[2]), "resourceLogs", "scopeLogs", "logRecords")
    // Already-sent items are not re-sent; the queued one is replaced by its tagged copy.
    #expect(logs.count == 2)
    let id = report.id.uuidString.lowercased()
    #expect(attrs(logs[0])["feedback.report.id"] as? String == id && attrs(logs[0])["feedback.excerpt"] as? Bool == true)
    #expect((logs[1]["body"] as! [String: Any])["stringValue"] as? String == "feedback.submitted")
    #expect(attrs(logs[1])["feedback.report.id"] as? String == id)
    #expect(logs[1]["traceId"] as? String == trace.traceId && logs[1]["spanId"] as? String == trace.spanId)
}

@Test func excerptOnlySendsNothingUntilSubmit() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client, mode: .excerptOnly)
    t.log(.info, "app.action"); t.counter("app.actions").add(1)
    #expect(await t.flush() && t.stats().ringLogs == 1)
    #expect(await telemetryRequests(r).isEmpty)
    await r.network.add(accepted)
    #expect(await t.feedbackSubmitted(reportID: UUID(), includeDiagnostics: false))
    let logs = items(body(await telemetryRequests(r)[0]), "resourceLogs", "scopeLogs", "logRecords")
    #expect(logs.count == 1 && (logs[0]["body"] as! [String: Any])["stringValue"] as? String == "feedback.submitted")
}

@Test func recordedSpansExportWithTheirEvents() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    let start = r.clock.now().addingTimeInterval(-2)
    let context = try TelemetrySpanContext(traceID: String(repeating: "a", count: 32), spanID: String(repeating: "b", count: 16))
    t.record(try RecordedSpan(context: context, name: "stream", kind: .client, start: start, end: r.clock.now(),
                              attributes: ["chunks": 4], events: [.init(name: "gap", time: start.addingTimeInterval(1), attributes: ["gap_ms": 900])],
                              status: .error))
    #expect(throws: FramebriarError.invalidInput) { try TelemetrySpanContext(traceID: "nothex", spanID: "b") }
    await r.network.add(accepted)
    await t.flush()
    let span = items(body(await telemetryRequests(r)[0]), "resourceSpans", "scopeSpans", "spans")[0]
    #expect(span["traceId"] as? String == context.traceID && span["kind"] as? Int == 3)
    #expect(((span["events"] as! [[String: Any]])[0]["name"] as? String) == "gap")
    #expect((span["status"] as! [String: Any])["code"] as? Int == 2)
}

@Test func withSpanParentsNestedWorkAndRecordsErrorType() async throws {
    struct Failure: Error {}
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    await #expect(throws: Failure.self) {
        try await t.withSpan("app.flow") { outer in
            t.log(.info, "app.flow.step")
            #expect(t.startSpan("inner").context.traceID == outer.context.traceID)
            throw Failure()
        }
    }
    await r.network.add(accepted); await r.network.add(accepted)
    await t.flush()
    let sent = await telemetryRequests(r)
    let span = items(body(sent[0]), "resourceSpans", "scopeSpans", "spans")[0]
    #expect((span["status"] as! [String: Any])["code"] as? Int == 2)
    #expect(attrs((span["events"] as! [[String: Any]])[0])["exception.type"] as? String == "Failure")
    let log = items(body(sent[1]), "resourceLogs", "scopeLogs", "logRecords")[0]
    #expect(log["traceId"] as? String == span["traceId"] as? String && log["spanId"] as? String == span["spanId"] as? String)
}

@Test func bufferIsBoundedAndDropsOldest() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try telemetry(r, client)
    let filler = String(repeating: "x", count: 1000)
    await r.network.add { _ in json([:], status: 503) } // the threshold flush backs off, keeping data
    for i in 0..<1200 { t.log(.info, "app.action", ["i": .int(i), "pad": .string(filler)]) }
    #expect(await eventually { t.stats().bufferedBytes > 0 && t.stats().blockedUntil > r.clock.now() })
    #expect(t.stats().bufferedBytes <= TelemetryLimits.bufferBytes && t.stats().dropped > 0)
}

@Test func exponentialHistogramMatchesOTelBuckets() {
    #expect(ExponentialHistogram.index(1, scale: 0) == -1)
    #expect(ExponentialHistogram.index(2, scale: 0) == 0)
    #expect(ExponentialHistogram.index(3, scale: 0) == 1)
    #expect(ExponentialHistogram.index(4, scale: 1) == 3)
    #expect(ExponentialHistogram.index(5, scale: -1) == 1)
    var h = ExponentialHistogram()
    for v in [0.001, 1, 1000, 1_000_000] { h.record(v) }
    let p = h.point(attributes: [], start: "1", time: "2")
    #expect(p.count == "4" && (p.positive?.bucketCounts.count ?? 0) <= TelemetryLimits.histogramBuckets && p.scale < 8)
}

/// Deterministic bodies shared with tests/swift-telemetry-contract.test.mjs, which runs them through
/// the gateway's own sanitizer. Regenerate with FRAMEBRIAR_WRITE_FIXTURES=1 swift test.
@Test func otlpBodiesMatchFixturesCheckedByGatewaySanitizer() async throws {
    let r = Rig(); let client = try await r.connected()
    let t = try Telemetry(client: client, configuration: r.config, appVersion: "1.2.0", appBuild: "42", environment: "dev",
                          commonAttributes: ["app.telemetry.schema_version": 1], sessionID: "s-fixture",
                          transport: r.network, observeAppLifecycle: false, now: r.clock.now, sleep: idle)
    let start = r.clock.now().addingTimeInterval(-2)
    t.record(try RecordedSpan(context: TelemetrySpanContext(traceID: "0af7651916cd43dd8448eb211c80319c", spanID: "b7ad6b7169203331"),
                              parentSpanID: "00f067aa0ba902b7", name: "stream", kind: .client, start: start, end: r.clock.now(),
                              attributes: ["chunks": 4, "app.outcome": "ok"],
                              events: [.init(name: "firstToken", time: start.addingTimeInterval(0.5), attributes: ["latency_ms": 500])], status: .ok))
    t.log(.warn, "app.error", ["app.error.class": "timeout", "attempt": 2, "ratio": 0.5, "retried": true])
    t.counter("app.reconnects", unit: "{reconnect}").add(2, ["reason": "network"])
    t.gauge("app.connections").record(1)
    let h = t.histogram("app.first_token.duration", unit: "ms"); h.record(120); h.record(0); h.record(3.5)
    r.clock.advance(1)
    for _ in 0..<3 { await r.network.add(accepted) }
    #expect(await t.flush())
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    for request in await telemetryRequests(r) {
        var value = body(request)
        // host.arch depends on the build machine; the fixture leaves it out.
        let key = value.keys.first!
        var blocks = value[key] as! [[String: Any]], res = blocks[0]["resource"] as! [String: Any]
        res["attributes"] = (res["attributes"] as! [[String: Any]]).filter { $0["key"] as? String != "host.arch" }
        blocks[0]["resource"] = res; value[key] = blocks
        let file = fixtures.appendingPathComponent("otlp-\(signal(request)).json")
        if ProcessInfo.processInfo.environment["FRAMEBRIAR_WRITE_FIXTURES"] == "1" {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! NSDictionary
        #expect(NSDictionary(dictionary: value) == expected, "otlp-\(signal(request)).json")
    }
}
