import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Exact source identity, retained even when the visible summary is shortened further for layout.
struct CompanionEventReference: Sendable, Equatable, Identifiable {
    let sessionID: String
    let sequence: Int64
    let truncation: AnnexJSON?
    let event: AnnexJSON
    var reviewLabel: String {
        switch event["type"]?.string {
        case "permission_request": "Review full request"
        case "tool_call": "Review full input"
        case "tool_call_update": "Review full output"
        default: "Review full payload"
        }
    }
    var id: String { "\(sessionID):\(sequence)" }
    init?(event: AnnexJSON) {
        guard let session = event["sessionId"]?.string, let seq = event["seq"]?.integer, seq > 0 else { return nil }
        sessionID = session; sequence = seq; self.event = event
        truncation = event["data"]?["truncated"] ?? event["truncated"]
    }
}

struct CompanionFullReview: Sendable {
    let reference: CompanionEventReference
    let digest: String
    static func reason(_ error: Error) -> String {
        switch error {
        case let error as URLError where error.code == .timedOut:
            "The full-event download timed out. Try again on a faster connection, or review and approve it on the desktop."
        case AnnexTransportError.responseTooLarge, AnnexTransportError.rejected(413, _, _):
            "This event exceeds the 32 MiB phone review limit. Review and approve it on the desktop, or deny it here."
        case AnnexTransportError.unauthorized, AnnexTransportError.forbidden, AnnexTransportError.rejected(401, _, _), AnnexTransportError.rejected(403, _, _):
            "Access was revoked. Pair with the desktop again, then fetch and review this request again."
        case AnnexTransportError.rejected(404, _, _):
            "This event is no longer available. Refresh the conversation, or review it on the desktop."
        default: error.localizedDescription
        }
    }
}
