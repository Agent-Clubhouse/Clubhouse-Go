import Foundation
import Testing
import ClubhouseTransport
import Framebriar
@testable import ClubhouseGo

@MainActor struct DiagnosticPrivacyTests {
    @Test func legacyLogNeverRetainsRawCategoryOrBody() {
        let log = AppLog.shared
        log.clear()
        let payload = "https://192.0.2.1/users/private?token=secret message contents"
        log.error(payload, payload)
        log.info("API", payload)
        #expect(!log.exportText.contains(payload))
        #expect(!log.exportText.contains("192.0.2.1"))
        #expect(!log.exportText.contains("token"))
        #expect(log.entries.last?.category == "API")
        #expect(log.entries.last?.message == "Details omitted for privacy")
        log.clear()
    }
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
