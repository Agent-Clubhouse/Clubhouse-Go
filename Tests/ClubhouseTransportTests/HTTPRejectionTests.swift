import Foundation
import Testing
@testable import ClubhouseTransport

private let httpRejectionCases: [(String, String?, String?)] = [
    (#"{"error":"pending_overflow","message":"Review on desktop."}"#, "pending_overflow", "Review on desktop."),
    (#"{"error":"pending_overflow","message":"  \n  "}"#, "pending_overflow", nil),
    (#"{"error":"unsafe code: text","message":"Desktop explanation"}"#, nil, "Desktop explanation"),
    (#"{"error":"pending_overflow","message":12}"#, "pending_overflow", nil),
    (#"{"error":"pending_overflow","message":"pending_overflow"}"#, "pending_overflow", nil),
    (#"{"error":"pending_overflow","message":"  pending_overflow \n"}"#, "pending_overflow", nil),
]

@Test(arguments: httpRejectionCases)
func rejectedHTTPKeepsPlainMessageWithoutChangingDiagnosticClassification(body: String, code: String?, message: String?) {
    let error = AnnexHTTPValidation.error(.init(status: 503, data: Data(body.utf8)))
    #expect(error == .rejected(status: 503, code: code, message: message))
    #expect(AnnexDiagnosticFailure.classify(error) == .server)
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let span = telemetry.begin(.http); span.fail(error); span.end()
    #expect(telemetry.snapshot().records.last?.failure == .server)
    if let message { #expect(!telemetry.snapshot().records.description.contains(message)) }
}

@Test func rejectedHTTPStoresAtMost500CharactersOfDesktopMessage() throws {
    let text = String(repeating: "👩🏽‍💻", count: 501)
    let data = try JSONEncoder().encode(AnnexJSON.object(["error": .string("pending_overflow"), "message": .string(text)]))
    let error = AnnexHTTPValidation.error(.init(status: 503, data: data))
    #expect(error == .rejected(status: 503, code: "pending_overflow", message: String(text.prefix(500))))
}
