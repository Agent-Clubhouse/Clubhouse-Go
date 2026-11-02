import Foundation
import Testing
import ClubhouseTransport
import Framebriar
@testable import ClubhouseGo

@MainActor struct DiagnosticPrivacyTests {
    @Test func feedbackSnapshotIsBoundedImmutableAndUsesOnlyDiagnosticIdentity() throws {
        let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
        let peer = UUID(), connection = UUID(), backend = UUID()
        for _ in 0..<12 {
            let span = telemetry.begin(.http)
            span.identifier(.peerInstanceID, peer); span.identifier(.connectionID, connection); span.end()
        }
        let snapshot = try #require(CompanionFeedback.snapshotIncident(telemetry: telemetry, now: Date(), backend: backend))
        #expect(snapshot.traces.count == 8)
        #expect(snapshot.availability == .recorded)
        #expect(snapshot.phoneInstanceId == telemetry.instanceID.uuidString.lowercased())
        #expect(snapshot.hostInstanceIds == [peer.uuidString.lowercased()])
        #expect(snapshot.connectionIds == [connection.uuidString.lowercased()])
        #expect(snapshot.backendRef == backend.uuidString.lowercased())
        let restored = try JSONDecoder().decode(FeedbackIncident.self, from: JSONEncoder().encode(snapshot))
        telemetry.clear(); telemetry.record(.wake)
        #expect(snapshot == restored)
        telemetry.setEnabled(false)
        let off = try #require(CompanionFeedback.snapshotIncident(telemetry: telemetry, backend: nil))
        #expect(off.availability == .collection_off); #expect(off.traces.isEmpty)
        #expect(off.hostInstanceIds.isEmpty); #expect(off.backendRef == nil)
    }

    @Test func incidentReferencesOnlyFinishedSpansAtCapture() throws {
        let source = AnnexTelemetry(); source.setEnabled(true)
        let parent = source.begin(.connection)
        let child = source.begin(.http, parent: parent)
        child.end()
        let before = try #require(CompanionFeedback.snapshotIncident(telemetry: source))
        #expect(before.traces.count == 1)
        #expect(source.snapshot().records.map(\.operation) == [.http])
        parent.end()
        let after = try #require(CompanionFeedback.snapshotIncident(telemetry: source))
        #expect(after.traces.count == 2)
        #expect(before.traces.count == 1) // opening capture remains immutable
    }

}
