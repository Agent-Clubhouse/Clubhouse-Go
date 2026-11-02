import Foundation
import Testing
@testable import Framebriar

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let end = start + 300
private func entry(_ n: Double = 0, ns: String = "transport", event: String = "connect.failed", attrs: [String: FeedbackDiagnostics.Value] = [:]) -> FeedbackDiagnostics.Entry {
    .init(at: start + n, level: .warn, ns: ns, event: event, attrs: attrs)
}
private func diagnostics(_ entries: [FeedbackDiagnostics.Entry], dropped: Int = 0) -> FeedbackDiagnostics {
    FeedbackDiagnostics(windowStart: start, windowEnd: end, entries: entries, dropped: dropped)
}
private func object(_ value: FeedbackDiagnostics) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

@Test func attachedCarriesTheContractFieldsAndCounts() throws {
    let value = diagnostics([entry(attrs: ["attempt": 2, "failure": "timeout"]), entry(1)])
    #expect(value.state == .attached && value.reason == nil)
    #expect(value.lines == 2 && value.dropped == 0 && value.droppedAttrs == 0)
    #expect(value.windowStart == "2027-01-15T08:00:00.000Z" && value.windowEnd == "2027-01-15T08:05:00.000Z")
    let body = try object(value)
    #expect(Set(body.keys) == ["v", "state", "windowStart", "windowEnd", "lines", "bytes", "dropped", "droppedAttrs", "entries"])
    let first = (body["entries"] as! [[String: Any]])[0]
    #expect(first["at"] as? String == "2027-01-15T08:00:00.000Z" && first["level"] as? String == "warn" && first["ns"] as? String == "transport")
    let second = (body["entries"] as! [[String: Any]])[1]
    #expect(second["attrs"] == nil, "An entry with no attrs omits the field")
    try value.validate()
}

@Test func bytesIsTheLengthOfTheEntriesJSONAndWholeNumbersHaveNoFraction() throws {
    let value = diagnostics([entry(attrs: ["attempt": 2, "backoffMs": 1500.5, "statusCode": 503])])
    let encoded = try JSONEncoder().encode(value.entries)
    #expect(value.bytes == encoded.count)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(text.contains("\"attempt\":2") && !text.contains("2.0"))
    #expect(text.contains("\"statusCode\":503") && text.contains("\"backoffMs\":1500.5"))
}

@Test func emptyAndUnusableAndFailureStatesHaveNoEntries() throws {
    let empty = diagnostics([])
    #expect(empty.state == .none && empty.reason == "empty" && empty.entries.isEmpty && empty.lines == 0 && empty.bytes == 0)
    let unusable = diagnostics([entry(ns: "has space"), entry(event: "")])
    #expect(unusable.state == .unavailable && unusable.reason == "invalid" && unusable.dropped == 2)
    #expect(FeedbackDiagnostics.none(reason: "no-provider").reason == "no-provider")
    #expect(FeedbackDiagnostics.none(reason: "whatever").reason == "empty")
    #expect(FeedbackDiagnostics.unavailable(reason: "storage-failed").reason == "provider-failed", "storage-failed is server-only")
    let out = FeedbackDiagnostics.leftOut(at: start)
    #expect(out.state == .left_out && out.reason == nil && out.entries.isEmpty && out.dropped == 0 && out.delivery == nil)
    for value in [empty, unusable, out] { try value.validate() }
}

@Test func secretLookingTokensAreRedactedOnTheDevice() throws {
    let value = diagnostics([entry(ns: "ghp_abcdef", event: "sk-abcdef", attrs: ["operation": "token:abc123"])])
    #expect(value.entries[0].ns == "redacted" && value.entries[0].event == "redacted" && value.entries[0].attrs?["operation"] == .string("redacted"))
    #expect(value.droppedAttrs == 0)
    try value.validate()
}

@Test func aBadWindowIsInvalid() throws {
    let backwards = FeedbackDiagnostics(windowStart: end, windowEnd: start, entries: [entry()])
    #expect(backwards.state == .unavailable && backwards.reason == "invalid")
    let nan = FeedbackDiagnostics(windowStart: Date(timeIntervalSince1970: .nan), windowEnd: end, entries: [entry()])
    #expect(nan.state == .unavailable && nan.reason == "invalid")
}

@Test func allowlistDropsAndCountsUnknownKeysAndBadValues() throws {
    let value = diagnostics([entry(attrs: [
        "attempt": 1, "backoffMs": 2.5, "snapshotBytes": 3, "webSocketMessageLimitBytes": 4, "transportFrameLimitBytes": 5,
        "statusCode": 200, "closeCode": 1006, "durationMs": 6, "count": 7, "bytes": 8, "responseBytes": 9, "requestBytes": 10,
        "connectMs": 11, "tlsMs": 12, "firstByteMs": 13, "failure": "timeout", "operation": "pair.start",
        "connectionId": "ABCDEF01-2345-4678-89AB-CDEF01234567", "attemptId": "abcdef01-2345-4678-89ab-cdef01234567",
        "traceId": "0123456789ABCDEF0123456789ABCDEF", "spanId": "0123456789abcdef",
        "secret": "x", "prompt": "free text"
    ])])
    let attrs = value.entries[0].attrs!
    #expect(attrs.count == 21 && value.droppedAttrs == 2)
    #expect(attrs["connectionId"] == .string("abcdef01-2345-4678-89ab-cdef01234567"), "Lowercased for the wire")
    #expect(attrs["traceId"] == .string("0123456789abcdef0123456789abcdef"))
    #expect(attrs["prompt"] == nil && attrs["secret"] == nil)
    try value.validate()
}

@Test(arguments: [
    ("attempt", FeedbackDiagnostics.Value.number(-1)), ("attempt", .number(.nan)), ("attempt", .number(.infinity)), ("attempt", .string("1")),
    ("connectMs", .number(-1)), ("tlsMs", .string("9")), ("firstByteMs", .number(-0.5)), ("requestBytes", .string("x")), ("responseBytes", .number(-3)),
    ("statusCode", .number(99)), ("statusCode", .number(600)), ("statusCode", .number(200.5)), ("statusCode", .string("200")),
    ("closeCode", .number(999)), ("closeCode", .number(5000)), ("closeCode", .number(1006.5)), ("closeCode", .string("1006")),
    ("operation", .string("has space")), ("operation", .string(String(repeating: "a", count: 65))), ("operation", .number(1)),
    ("connectionId", .string("not-a-uuid")), ("attemptId", .number(1)), ("traceId", .string("abc")), ("spanId", .string("0123456789abcdeg"))
] as [(String, FeedbackDiagnostics.Value)])
func outOfContractValuesAreDroppedAndCounted(key: String, value: FeedbackDiagnostics.Value) throws {
    let result = diagnostics([entry(attrs: [key: value])])
    #expect(result.entries[0].attrs == nil)
    #expect(result.droppedAttrs == 1)
}

@Test func refsExitCodeLinkAndShortTokens() throws {
    let value = diagnostics([entry(attrs: ["peerRef": "0123456789abcdef", "agentRef": "fedcba9876543210", "exitCode": 255, "link": "mtls",
                                           "fromState": "connecting", "toState": "up.2", "reason": "idle-timeout", "provider": "a_b", "driver": "0"])])
    #expect(value.entries[0].attrs?.count == 9 && value.droppedAttrs == 0)
    try value.validate()
    #expect(diagnostics([entry(attrs: ["exitCode": 0])]).droppedAttrs == 0)
    #expect(diagnostics([entry(attrs: ["link": "wifi"])]).entries[0].attrs?["link"] == .string("unknown"))
    #expect(diagnostics([entry(attrs: ["link": 1])]).entries[0].attrs?["link"] == .string("unknown"))
    let invalid: [(String, String)] = [("peerRef", "0123456789ABCDEF"), ("agentRef", "0123"), ("fromState", "Upper"), ("toState", "-leading"), ("reason", "has space"),
                                       ("provider", String(repeating: "a", count: 33)), ("driver", "a:b")]
    for (key, bad) in invalid {
        let result = diagnostics([entry(attrs: [key: .string(bad)])])
        #expect(result.entries[0].attrs == nil && result.droppedAttrs == 1, "\(key)")
    }
    for bad: FeedbackDiagnostics.Value in [256, -1, 1.5, "1"] { #expect(diagnostics([entry(attrs: ["exitCode": bad])]).droppedAttrs == 1) }
}

@Test func closeCodeAndStatusCodeAreSeparateRanges() {
    #expect(diagnostics([entry(attrs: ["closeCode": 1000])]).droppedAttrs == 0)
    #expect(diagnostics([entry(attrs: ["closeCode": 4999])]).droppedAttrs == 0)
    #expect(diagnostics([entry(attrs: ["closeCode": 503])]).droppedAttrs == 1, "An HTTP status is not a close code")
    #expect(diagnostics([entry(attrs: ["statusCode": 1006])]).droppedAttrs == 1, "A close code is not an HTTP status")
    #expect(diagnostics([entry(attrs: ["statusCode": 100])]).droppedAttrs == 0)
    #expect(diagnostics([entry(attrs: ["statusCode": 599])]).droppedAttrs == 0)
}

@Test func failureEnumIsClosedAndUnknownValuesNormalize() {
    for name in ["timeout", "tls", "dns", "refused", "closed", "oversize", "overflow", "busy", "storage", "auth", "protocol", "cancelled", "server", "offline", "unknown"] {
        #expect(diagnostics([entry(attrs: ["failure": .string(name)])]).entries[0].attrs?["failure"] == .string(name))
    }
    for raw: FeedbackDiagnostics.Value in ["connection", "TIMEOUT", "a free text message", 42] {
        let value = diagnostics([entry(attrs: ["failure": raw])])
        #expect(value.entries[0].attrs?["failure"] == .string("unknown"))
        #expect(value.droppedAttrs == 0, "Normalized, not dropped")
    }
}

@Test func badEntriesAreDroppedAndGoodOnesKept() {
    let value = diagnostics([entry(0), entry(1, ns: "bad ns"), entry(2, event: "line\nbreak"), entry(3, event: String(repeating: "e", count: 65)), entry(4)], dropped: 7)
    #expect(value.state == .attached && value.lines == 2 && value.dropped == 10, "Three bad plus the seven the provider reported")
}

@Test func trimsOldestToTheEntryLimit() throws {
    let value = diagnostics((0..<600).map { entry(Double($0)) })
    #expect(value.lines == 500 && value.dropped == 100)
    #expect(value.entries.first?.at == isoMillis(start + 100) && value.entries.last?.at == isoMillis(start + 599), "Newest kept, in time order")
    try value.validate()
}

@Test func trimsOldestToSixtyFourKiBAndStaysWithinIt() throws {
    let long = String(repeating: "n", count: 64)
    let attrs: [String: FeedbackDiagnostics.Value] = ["operation": .string(long), "connectionId": "abcdef01-2345-4678-89ab-cdef01234567", "attemptId": "abcdef01-2345-4678-89ab-cdef01234567",
                                                      "traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef", "webSocketMessageLimitBytes": 1234567, "transportFrameLimitBytes": 1234567]
    let value = diagnostics((0..<500).map { entry(Double($0), ns: long, event: long, attrs: attrs) })
    let size = try JSONEncoder().encode(value).count
    #expect(size <= FeedbackDiagnostics.Limits.totalBytes)
    #expect(size > FeedbackDiagnostics.Limits.totalBytes - 2000, "Trims no more than it has to")
    #expect(value.dropped == 500 - value.lines && value.lines > 0)
    #expect(value.entries.last?.at == isoMillis(start + 499), "The newest survives")
    let entriesBytes = try JSONEncoder().encode(value.entries).count
    #expect(value.bytes == entriesBytes)
    try value.validate()
}

@Test func unsortedEntriesTrimByTimeNotPosition() {
    let value = diagnostics((0..<501).reversed().map { entry(Double($0)) })
    #expect(value.entries.first?.at == isoMillis(start + 1))
}

@Test func normalizingTwiceChangesNothing() throws {
    let once = diagnostics([entry(attrs: ["attempt": 1, "nope": 2]), entry(1, ns: "bad ns")])
    #expect(once.normalized(at: end) == once)
    let decoded = try JSONDecoder().decode(FeedbackDiagnostics.self, from: JSONEncoder().encode(once))
    #expect(decoded == once)
}

@Test func validateRejectsForgedValues() throws {
    func forged(_ edit: (inout [String: Any]) -> Void) throws -> FeedbackDiagnostics {
        var body = try object(diagnostics([entry(attrs: ["attempt": 1])]))
        edit(&body)
        return try JSONDecoder().decode(FeedbackDiagnostics.self, from: JSONSerialization.data(withJSONObject: body))
    }
    #expect(throws: FramebriarError.invalidInput) { try forged { $0["lines"] = 9 }.validate() }
    #expect(throws: FramebriarError.invalidInput) { try forged { $0["state"] = "left_out" }.validate() }
    #expect(throws: FramebriarError.invalidInput) { try forged { var e = $0["entries"] as! [[String: Any]]; e[0]["ns"] = "sk-abc"; $0["entries"] = e }.validate() }
    #expect(throws: FramebriarError.invalidInput) { try forged { $0["bytes"] = 1 }.validate() }
    #expect(throws: FramebriarError.invalidInput) { try forged { var e = $0["entries"] as! [[String: Any]]; e[0]["attrs"] = ["secret": "x"]; $0["entries"] = e; $0["bytes"] = 1 }.validate() }
}

@Test func reportWireCarriesDiagnosticsAndKeepsSeparateLimits() async throws {
    let r = Rig()
    let long = String(repeating: "n", count: 64)
    let big = diagnostics((0..<500).map { entry(Double($0), ns: long, event: long, attrs: ["operation": .string(long)]) })
    #expect(big.bytes > 16 * 1024, "Larger than the 16 KiB metadata limit")
    let report = try ReviewedFeedback(configuration: r.config, notes: "note", diagnostics: big)
    let wire = try report.wire()
    let body = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
    #expect((body["diagnostics"] as? [String: Any])?["state"] as? String == "attached")
    #expect(wire.count <= 16 * 1024 + FeedbackDiagnostics.Limits.totalBytes)
    let plain = try ReviewedFeedback(configuration: r.config, notes: "note")
    let plainBody = try JSONSerialization.jsonObject(with: plain.wire()) as! [String: Any]
    #expect(plainBody["diagnostics"] == nil, "Existing callers keep their exact wire form")
}

@Test func queueSavedByAnOlderBuildStillLoads() throws {
    let r = Rig()
    let report = try ReviewedFeedback(configuration: r.config, notes: "note")
    var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
    stored["diagnostics"] = nil
    let decoded = try JSONDecoder().decode(ReviewedFeedback.self, from: JSONSerialization.data(withJSONObject: stored))
    #expect(decoded.diagnostics == nil && decoded == report)
    try decoded.validate(for: r.config)
}

@Test func sanitizingAFullProviderIsCheap() {
    let records = (0..<512).map { entry(Double($0), attrs: ["attempt": 1, "durationMs": 20, "failure": "timeout", "operation": "connect",
                                                             "connectionId": "abcdef01-2345-4678-89ab-cdef01234567", "traceId": "0123456789abcdef0123456789abcdef"]) }
    let begin = ProcessInfo.processInfo.systemUptime
    let value = diagnostics(records)
    let elapsed = ProcessInfo.processInfo.systemUptime - begin
    #expect(value.lines > 0)
    // Generous for a debug build on a loaded CI machine; this guards against an accidental quadratic.
    #expect(elapsed < 0.5, "Took \(elapsed) s")
}

@Test func deliveryIsNotCarriedWhenLeftOut() throws {
    var attached = diagnostics([entry()])
    attached.setDelivery(.init(queued: 2, lastResult: "offline"))
    #expect(attached.delivery == .init(queued: 2, lastResult: "offline"))
    try attached.validate()
    attached.setDelivery(.init(queued: 2, lastResult: "password:hunter2"))
    #expect(attached.normalized(at: end).delivery == .init(queued: 2, lastResult: "unknown"), "Closed set: kept, as unknown")
    attached.setDelivery(.init(queued: -1, lastResult: "ok"))
    #expect(attached.normalized(at: end).delivery == nil, "A bad count drops delivery only")
    #expect(attached.normalized(at: end).state == .attached)
    var out = FeedbackDiagnostics.leftOut(at: start)
    out.setDelivery(.init(queued: 2, lastResult: "offline"))
    #expect(out.delivery == nil)
}

// MARK: shared fixture (tests/fixtures/report-diagnostics-v1.json, kept byte-identical by tests/swift-wire-contract.test.mjs)

private func fixture() throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "report-diagnostics-v1", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
/// Builds the raw value a host could hand over from loosely typed JSON. Shapes Swift's types can't
/// express (an unknown level or a non-number attribute) stay unusable, so they're dropped as the server does.
private func rawDiagnostics(_ input: [String: Any]) -> FeedbackDiagnostics? {
    guard input["v"] as? Int == 1, let state = (input["state"] as? String).flatMap(FeedbackDiagnostics.State.init), input["entries"] == nil || input["entries"] is [Any] else { return nil }
    let entries = (input["entries"] as? [[String: Any]] ?? []).map { raw -> FeedbackDiagnostics.Entry in
        let level = (raw["level"] as? String).flatMap(FeedbackDiagnostics.Level.init)
        let attrs = (raw["attrs"] as? [String: Any]).map { $0.mapValues { value -> FeedbackDiagnostics.Value in
            if let text = value as? String { return .string(text) }
            return .number((value as? NSNumber)?.doubleValue ?? .nan)
        } }
        return .init(at: level == nil ? "" : raw["at"] as? String ?? "", level: level ?? .info, ns: raw["ns"] as? String ?? "", event: raw["event"] as? String ?? "", attrs: attrs)
    }
    var value = FeedbackDiagnostics(state: state, reason: input["reason"] as? String, windowStart: input["windowStart"] as? String ?? "", windowEnd: input["windowEnd"] as? String ?? "",
                                    dropped: input["dropped"] as? Int ?? 0, droppedAttrs: input["droppedAttrs"] as? Int ?? 0, entries: entries)
    if let delivery = input["delivery"] as? [String: Any] {
        let queued = delivery["queued"] as? NSNumber
        let whole = queued.map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == $0.doubleValue.rounded() } ?? false
        value.setDelivery(.init(queued: whole ? queued!.intValue : -1, lastResult: delivery["lastResult"] as? String ?? ""))
    }
    return value
}

@Test func theMirroredContractMatchesTheSharedFixture() throws {
    let contract = try fixture()["contract"] as! [String: Any]
    let limits = contract["limits"] as! [String: Int]
    #expect(limits["totalBytes"] == FeedbackDiagnostics.Limits.totalBytes && limits["entries"] == FeedbackDiagnostics.Limits.entries)
    #expect(limits["stringBytes"] == FeedbackDiagnostics.Limits.stringBytes && limits["attrsPerEntry"] == FeedbackDiagnostics.Limits.attrsPerEntry)
    let attrs = contract["attrs"] as! [String: Any]
    #expect(Set(attrs["numbers"] as! [String]) == FeedbackDiagnosticsAttrs.numbers)
    #expect(Set(contract["deliveryResults"] as! [String]) == FeedbackDiagnosticsAttrs.deliveryResults)
    #expect(Set((attrs["enums"] as! [String: [String]])["link"]!) == FeedbackDiagnosticsAttrs.links)
    #expect(Set(attrs["shortTokens"] as! [String]) == ["fromState", "toState", "reason", "provider", "driver"])
    #expect(Set(attrs["refs"] as! [String]) == ["peerRef", "agentRef"])
    #expect(Set((attrs["integerRanges"] as! [String: [Int]]).keys) == ["statusCode", "closeCode", "exitCode"])
    #expect(Set((attrs["enums"] as! [String: [String]])["failure"]!) == FeedbackDiagnosticsAttrs.failures)
    let reasons = contract["reasons"] as! [String: [String]]
    #expect(reasons["none"] == [FeedbackDiagnostics.Reason.empty, FeedbackDiagnostics.Reason.noProvider])
    #expect(reasons["unavailable"] == [FeedbackDiagnostics.Reason.providerFailed, FeedbackDiagnostics.Reason.invalid])
}

@Test func everySharedFixtureCaseNormalizesAsTheServerDoes() throws {
    let cases = try fixture()["cases"] as! [[String: Any]]
    #expect(cases.count >= 25)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for item in cases {
        let name = item["name"] as! String
        let expected = item["expected"] as! [String: Any]
        let value = rawDiagnostics(item["input"] as! [String: Any])?.normalized(at: now) ?? .unavailable(reason: "invalid", at: now)
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        if expected["windowStart"] == nil {
            // With no valid window the server omits it. The SDK fills in the capture time, which the server accepts.
            #expect(encoded["windowStart"] != nil, "\(name)")
            encoded["windowStart"] = nil; encoded["windowEnd"] = nil
        }
        #expect(NSDictionary(dictionary: encoded).isEqual(to: expected), "\(name): \(encoded)")
    }
}

@Test func theFixtureLeftOutReportHasTheShapeSwiftSends() throws {
    let report = try fixture()["leftOutReport"] as! [String: Any]
    let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FeedbackDiagnostics.leftOut(at: start))) as! [String: Any]
    #expect(Set(wire.keys) == Set((report["diagnostics"] as! [String: Any]).keys))
}
