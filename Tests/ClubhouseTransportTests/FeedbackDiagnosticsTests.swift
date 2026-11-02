import Foundation
import Testing
@testable import ClubhouseTransport

struct FeedbackDiagnosticsTests {
    @Test func connectionFailureAndBackoffProduceFrozenAllowlistedEntriesWithoutExport() throws {
        let source = AnnexTelemetry()
        source.setEnrolledCapture(true) // local Connection diagnostics remains Off
        let attempt = UUID(), connection = UUID()
        let failure = source.begin(.websocket)
        failure.identifier(.connectionID, connection); failure.identifier(.connectionAttemptID, attempt)
        failure.identifier(.peerInstanceID, UUID()) // not in diagnostics v1's closed attrs
        failure.fail(.connection); failure.number(.requestBytes, 40); failure.number(.connectMs, 12)
        failure.number(.dnsMs, 3); failure.end()
        let backoff = source.begin(.backoff)
        backoff.identifier(.connectionAttemptID, attempt); backoff.number(.attempt, 3); backoff.number(.backoffMs, 30_000); backoff.end()
        let frozen = AnnexFeedbackDiagnostics.capture(from: source)
        #expect(frozen.state == .attached && frozen.lines == 2)
        #expect(frozen.entries.map(\.event) == ["websocket", "backoff"])
        #expect(frozen.entries[0].attrs["failure"] == .string("closed"))
        #expect(frozen.entries[0].attrs["connectionId"] == .string(connection.uuidString.lowercased()))
        #expect(frozen.entries[0].attrs["attemptId"] == .string(attempt.uuidString.lowercased()))
        #expect(frozen.entries[0].attrs["connectMs"] == .number(12))
        #expect(frozen.entries[1].attrs["backoffMs"] == .number(30_000))
        #expect(frozen.droppedAttrs == 2)
        let bytes = try frozen.encoded()
        #expect(frozen.bytes == (try JSONEncoder().encode(frozen.entries)).count)
        #expect(bytes.count <= 64 * 1024)
        let restored = try JSONDecoder().decode(AnnexFeedbackDiagnostics.self, from: bytes)
        source.clear(); source.record(.foreground)
        #expect(restored == frozen) // durable snapshot, independent of collector/export and retries
        let leftOut = frozen.leavingOut()
        #expect(leftOut.state == .left_out && leftOut.lines == 0 && leftOut.entries.isEmpty)
        #expect(leftOut.windowStart == frozen.windowStart && leftOut.windowEnd == frozen.windowEnd)
        #expect(frozen.lines == 2) // toggling back can use the original, never recapture
    }

    @Test func everyFailureHasAnExplicitMapping() {
        let expected: [AnnexDiagnosticFailure: AnnexFeedbackDiagnostics.Failure] = [
            .cancelled: .cancelled, .abandoned: .cancelled, .timeout: .timeout, .offline: .offline, .dns: .dns,
            .connection: .closed, .tls: .tls, .trust: .auth, .identity: .auth, .authentication: .auth, .forbidden: .auth,
            .invalidInput: .protocol, .malformed: .protocol, .tooLarge: .oversize, .overflow: .overflow,
            .unsupported: .protocol, .busy: .busy, .conflict: .protocol, .outcomeUnknown: .unknown,
            .storage: .storage, .server: .server, .rejected: .protocol, .unknown: .unknown
        ]
        for failure in AnnexDiagnosticFailure.allCases {
            #expect(AnnexFeedbackDiagnostics.Failure(failure) == expected[failure])
        }
    }

    @Test func boundedByEncodedBytesAndEntryCountKeepingNewest() throws {
        let source = AnnexTelemetry(capacity: 512); source.setEnabled(true)
        for attempt in 0..<512 {
            let span = source.begin(.backoff)
            for key in AnnexDiagnosticIdentifier.allCases { span.identifier(key, UUID()) }
            for number in [AnnexDiagnosticNumber.statusCode, .requestBytes, .responseBytes, .attempt, .backoffMs, .connectMs, .tlsMs, .firstByteMs, .bytes, .dnsMs] { span.number(number, number == .statusCode ? 503 : Double(attempt)) }
            span.fail(.server); span.end()
        }
        let snapshot = AnnexFeedbackDiagnostics.capture(from: source)
        #expect(snapshot.state == .attached && snapshot.lines > 0 && snapshot.lines <= 200)
        #expect(snapshot.bytes == (try JSONEncoder().encode(snapshot.entries)).count)
        #expect((try snapshot.encoded()).count <= 64 * 1024)
        #expect(snapshot.dropped == 512 - snapshot.lines)
        #expect(snapshot.entries.last?.attrs["attempt"] == .number(511))
        #expect(snapshot.entries.allSatisfy { $0.attrs.count <= 32 })
        let tokens = try NSRegularExpression(pattern: "^[A-Za-z0-9_.:+-]{1,64}$")
        for entry in snapshot.entries {
            for token in [entry.ns, entry.event] {
                #expect(tokens.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil)
            }
        }
        // The ring itself also evicts; preserve those losses in addition to report trimming.
        source.record(.foreground)
        #expect(AnnexFeedbackDiagnostics.capture(from: source).dropped >= snapshot.dropped)
    }

    @Test func arbitrarySnapshotStringsAndInvalidClosedFieldsNeverEnterTheExcerpt() throws {
        let source = AnnexTelemetry(); source.setEnabled(true); source.record(.http)
        let valid = try #require(source.snapshot().records.first)
        let raw = AnnexDiagnosticRecord(serviceName: "private/path", serviceInstanceID: "person@example.test",
            identifiers: ["annex.connection.id": "person@example.test", "peer.service.instance.id": UUID().uuidString.lowercased(), "name": "secret prompt"],
            traceID: valid.traceID, id: valid.id, parentID: nil, operation: .http, startedAt: valid.startedAt,
            durationMs: valid.durationMs, spanKind: 3, failure: .malformed,
            measurements: ["statusCode": 999, "attempt": -1, "bytes": .nan], events: ["secret prompt"], eventOffsetsMs: [])
        let snapshot = AnnexDiagnosticSnapshot(schemaVersion: 1, enabled: true, remoteExportEnabled: false, dropped: 0, records: [raw])
        let result = AnnexFeedbackDiagnostics.make(snapshot: snapshot, now: Date().addingTimeInterval(1))
        #expect(result.state == .attached && result.droppedAttrs == 6)
        #expect(result.entries.first?.attrs["failure"] == .string("protocol"))
        let encoded = String(decoding: try result.encoded(), as: UTF8.self)
        #expect(!encoded.contains("private/path") && !encoded.contains("person@example.test") && !encoded.contains("secret prompt"))
    }

    @Test func offEmptyNoProviderInvalidAndExpiredAreExplicit() throws {
        let source = AnnexTelemetry()
        #expect(AnnexFeedbackDiagnostics.capture(from: source).reason == .collection_off)
        source.setEnabled(true)
        #expect(AnnexFeedbackDiagnostics.capture(from: source).reason == .empty)
        #expect(AnnexFeedbackDiagnostics.noProvider().state == .none)
        #expect(AnnexFeedbackDiagnostics.unavailable().state == .unavailable)
        source.record(.foreground)
        let future = Date().addingTimeInterval(301)
        #expect(AnnexFeedbackDiagnostics.capture(from: source, now: future).state == .none)
        let record = try #require(source.snapshot().records.first)
        let invalid = AnnexDiagnosticRecord(serviceName: "private/path", serviceInstanceID: "person@example.test", identifiers: [:],
            traceID: "invalid", id: record.id, parentID: nil, operation: .websocket, startedAt: record.startedAt,
            durationMs: 1, spanKind: 3, failure: .unknown, measurements: [:], events: [], eventOffsetsMs: [])
        let snapshot = AnnexDiagnosticSnapshot(schemaVersion: 1, enabled: true, remoteExportEnabled: false, dropped: 0, records: [invalid])
        #expect(AnnexFeedbackDiagnostics.make(snapshot: snapshot, now: Date().addingTimeInterval(1)).state == .unavailable)
    }
}

@Test func recordObserversAndCaptureOwnersCannotClobberEachOther() {
    let source = AnnexTelemetry()
    let older = UUID(), newer = UUID()
    let oldRecords = ObserverRecords(), newRecords = ObserverRecords(), debugRecords = ObserverRecords()
    let oldToken = source.observeRecords { oldRecords.add($0) }
    source.setEnrolledCapture(true, owner: older)
    let newToken = source.observeRecords { newRecords.add($0) }
    source.setEnrolledCapture(true, owner: newer)
    source.setRecordSink { debugRecords.add($0) }
    source.record(.background)
    source.removeRecordObserver(oldToken); source.setEnrolledCapture(false, owner: older)
    source.record(.foreground)
    source.setEnabled(false) // local preference change must not remove observers
    source.record(.backoff)
    #expect(source.isEnabled)
    #expect(oldRecords.count == 1 && newRecords.count == 3 && debugRecords.count == 3)
    source.removeRecordObserver(newToken); source.setEnrolledCapture(false, owner: newer)
    #expect(!source.isEnabled)
}

private final class ObserverRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AnnexDiagnosticRecord] = []
    func add(_ value: AnnexDiagnosticRecord) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}
