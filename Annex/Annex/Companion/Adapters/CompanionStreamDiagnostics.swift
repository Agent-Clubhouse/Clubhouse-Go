import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Identifiers are transient dictionary keys only, never span attributes. Historical
/// reads do not enter this observer. Cursors survive reconnect to suppress replays.
@MainActor final class CompanionStreamDiagnostics {
    private struct Cursor { var session: String; var sequence: Int64; var turn: AnnexStreamDiagnostic? }
    private var cursors: [CompanionTarget: Cursor] = [:]
    private let telemetry: AnnexTelemetry
    init(telemetry: AnnexTelemetry = .shared) { self.telemetry = telemetry }
    func receive(_ event: AnnexJSON, target: CompanionTarget) {
        guard let session = event["sessionId"]?.string, session.utf8.count <= 256,
              let sequence = event["seq"]?.integer, sequence >= 0,
              let type = event["type"]?.string else { return }
        var cursor = cursors[target] ?? Cursor(session: session, sequence: -1)
        if cursor.session != session {
            cursor.turn?.finish(.abandoned); cursor = Cursor(session: session, sequence: -1)
        }
        guard sequence > cursor.sequence else { return }
        cursor.sequence = sequence
        let data = event["data"]
        switch type {
        case "turn_started":
            cursor.turn?.finish(.abandoned); cursor.turn = AnnexStreamDiagnostic(telemetry: telemetry)
        case "agent_message_chunk": cursor.turn?.chunk(byteCount: data?["text"]?.string?.utf8.count ?? 0)
        case "turn_ended", "session_ended":
            let reason = data?["stopReason"]?.string ?? data?["reason"]?.string
            let failure: AnnexDiagnosticFailure = reason == "cancelled" ? .cancelled : reason == "error" ? .server : .none
            cursor.turn?.finish(failure); cursor.turn = nil
        default: break
        }
        if cursors[target] == nil && cursors.count >= 32, let oldest = cursors.keys.first {
            cursors.removeValue(forKey: oldest)?.turn?.finish(.overflow)
        }
        cursors[target] = cursor
    }
    func disconnect(hostID: String) {
        for target in Array(cursors.keys) where target.hostID == hostID {
            cursors[target]?.turn?.finish(.connection); cursors[target]?.turn = nil
        }
    }
    func remove(hostID: String) {
        disconnect(hostID: hostID)
        cursors = cursors.filter { $0.key.hostID != hostID }
    }
}
