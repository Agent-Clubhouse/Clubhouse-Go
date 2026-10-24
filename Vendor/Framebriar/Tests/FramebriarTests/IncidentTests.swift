import Foundation
import Testing
@testable import Framebriar

func incident(_ date: Date) throws -> FeedbackIncident {
    try .init(capturedAt: date, windowStart: date - 60, availability: .recorded,
        phoneInstanceId: "11111111-1111-4111-8111-111111111111",
        hostInstanceIds: ["22222222-2222-4222-8222-222222222222"],
        connectionIds: ["33333333-3333-4333-8333-333333333333"],
        traces: [.init(traceId: String(repeating: "a", count: 32), spanId: String(repeating: "b", count: 16))],
        backendRef: "44444444-4444-4444-8444-444444444444")
}
@Test func incidentSurvivesQueueRoundTripAndMirrorsLegacyReferences() throws {
    let r = Rig(), context = try incident(Date(timeIntervalSince1970: 1_800_000_000))
    let report = try ReviewedFeedback(configuration: r.config, notes: "Button issue", capturedAt: r.clock.now(), incident: context)
    let data = try JSONEncoder().encode(QueuedFeedback(feedback: report))
    let restored = try JSONDecoder().decode(QueuedFeedback.self, from: data)
    #expect(restored.feedback == report)
    #expect(restored.feedback.incident?.id != report.id.uuidString.lowercased())
    try restored.feedback.validate(for: r.config)
    let value = try JSONSerialization.jsonObject(with: report.wire()) as! [String: Any]
    #expect(value["traceId"] as? String == context.traces[0].traceId)
    #expect(value["spanId"] as? String == context.traces[0].spanId)
    #expect((value["incident"] as? [String: Any])?["backendRef"] as? String == context.backendRef)
}
@Test func oldFeedbackQueueDecodesWithoutIncident() throws {
    let r = Rig(), report = try r.review()
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
    value.removeValue(forKey: "incident")
    let restored = try JSONDecoder().decode(ReviewedFeedback.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(restored.incident == nil)
    try restored.validate(for: r.config)
}
@Test func incidentRejectsUnboundedPrivateAndInvalidIdentifiers() throws {
    let context = try incident(Date())
    let mutations: [(String, Any)] = [("phoneInstanceId", "192.168.1.4"), ("backendRef", "https://collector/?secret=x"), ("hostInstanceIds", Array(repeating: context.phoneInstanceId, count: 5)), ("traces", [["traceId": String(repeating: "0", count: 32), "spanId": String(repeating: "b", count: 16)]]), ("windowStart", "2000-01-01T00:00:00Z"), ("version", 2)]
    for (key, value) in mutations {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as! [String: Any]
        object[key] = value
        let decoded = try JSONDecoder().decode(FeedbackIncident.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: FramebriarError.invalidInput) { try decoded.validate() }
    }
}
@Test func oldServiceHoldsCorrelationWithoutBlockingOrdinaryReports() async throws {
    let r = Rig(), client = try await r.connected()
    let report = try ReviewedFeedback(configuration: r.config, notes: "Issue", incident: incident(r.clock.now()))
    try await client.enqueue(report); try await client.enqueue(r.review())
    await r.network.add { ack($0) }
    try await client.flush()
    #expect(await client.status().queued == 1)
    #expect(await client.status().correlationWaiting == 1)
    #expect(await r.network.count() == 2) // redeem + ordinary report, no incident upload
    #expect(try r.queue.load(scope: r.config.storageScope)[0].feedback == report)
    await client.pause(); await client.resume()
    await r.network.add { _ in
        var payload = try JSONSerialization.jsonObject(with: access(r.clock).body) as! [String: Any]
        payload["feedbackCorrelationVersion"] = 1
        return json(payload)
    }
    await r.network.add { request in
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect((payload["incident"] as? [String: Any])?["id"] as? String == report.incident?.id)
        return ack(request)
    }
    try await client.flush()
    #expect(await client.status().queued == 0)
}

@Test func serviceCanonicalIncidentFixtureMatchesSDKWire() throws {
    let url = try #require(Bundle.module.url(forResource: "incident-report-v1", withExtension: "json", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: url)
    let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let context = try JSONDecoder().decode(FeedbackIncident.self, from: JSONSerialization.data(withJSONObject: value["incident"]!))
    try context.validate()
    let report = try ReviewedFeedback(configuration: Configuration(gameID: "clubhouse"), notes: "Connection stopped responding",
        id: UUID(uuidString: value["id"] as! String)!, capturedAt: parseDate(value["capturedAt"] as! String)!, incident: context)
    let wire = try JSONSerialization.jsonObject(with: report.wire()) as! [String: Any]
    #expect(NSDictionary(dictionary: wire["incident"] as! [String: Any]).isEqual(to: value["incident"] as! [AnyHashable: Any]))
    #expect(wire["traceId"] as? String == value["traceId"] as? String)
    #expect(wire["spanId"] as? String == value["spanId"] as? String)
    #expect(throws: FramebriarError.invalidInput) {
        try ReviewedFeedback(configuration: Configuration(gameID: "clubhouse"), notes: "Issue", id: UUID(uuidString: context.id)!, incident: context)
    }
}
