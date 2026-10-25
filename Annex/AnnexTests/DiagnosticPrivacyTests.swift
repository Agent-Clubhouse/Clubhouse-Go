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

}
