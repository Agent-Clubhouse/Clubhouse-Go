import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

private actor ArchiveTransport: AnnexTransporting {
    var responses: [Result<AnnexJSON, AnnexTransportError>]
    var requestedCursors: [Int64?] = []
    init(_ responses: [Result<AnnexJSON, AnnexTransportError>]) { self.responses = responses }
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func connect() {}
    func disconnect() {}
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt { throw AnnexTransportError.unsupportedCapability("test") }
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        guard case .chatHistory(_, let session, let before, _) = route, session == "session" else { throw AnnexTransportError.malformedResponse }
        requestedCursors.append(before)
        return try responses.removeFirst().get()
    }
}

@MainActor struct CompanionArchiveTests {
    let target = CompanionTarget(hostID: "host", projectID: "project", agentID: "agent")
    private func chunk(_ seq: Int64, _ text: String) -> AnnexJSON {
        .object(["sessionId": .string("session"), "seq": .integer(seq), "type": .string("agent_message_chunk"),
                 "data": .object(["messageId": .string("message"), "text": .string(text)])])
    }
    private func page(_ events: [AnnexJSON], next: Int64? = nil, session: String = "session") -> AnnexJSON {
        .object(["sessionId": .string(session), "events": .array(events), "nextBeforeSeq": next.map(AnnexJSON.integer) ?? .null])
    }

    @Test func earlierPagesRebuildChunksWithoutDuplicates() async throws {
        let transport = ArchiveTransport([
            .success(page([chunk(10, "world")], next: 10)),
            .success(page([chunk(9, "Hello "), chunk(10, "world")]))
        ])
        let reader = CompanionArchiveReader(transport: transport, target: target, sessionID: "session")
        let transcript = CompanionArchiveTranscript(reader: reader)
        await transcript.loadEarlier()
        #expect(transcript.nextBeforeSequence == 10)
        await transcript.loadEarlier()
        guard case .message(let message) = transcript.items.first else { Issue.record("Expected message"); return }
        #expect(message.text == "Hello world")
        #expect(transcript.items.count == 1)
        #expect(transcript.nextBeforeSequence == nil)
        await transcript.loadEarlier()
        #expect(await transport.requestedCursors.count == 2)
    }

    @Test func failedPagePreservesTranscriptAndRetryCursor() async {
        let transport = ArchiveTransport([
            .success(page([chunk(10, "world")], next: 10)),
            .failure(.disconnected),
            .success(page([chunk(9, "Hello ")]))
        ])
        let transcript = CompanionArchiveTranscript(reader: CompanionArchiveReader(transport: transport, target: target, sessionID: "session"))
        await transcript.loadEarlier()
        let before = transcript.items
        await transcript.loadEarlier()
        #expect(transcript.items == before)
        #expect(transcript.nextBeforeSequence == 10)
        #expect(transcript.error != nil)
        await transcript.loadEarlier()
        #expect(transcript.error == nil)
        #expect(await transport.requestedCursors == [nil, 10, 10])
    }

    @Test func archiveCannotSwitchSessionSilently() async {
        let transport = ArchiveTransport([.success(page([], session: "replacement"))])
        let transcript = CompanionArchiveTranscript(reader: CompanionArchiveReader(transport: transport, target: target, sessionID: "session"))
        await transcript.loadEarlier()
        #expect(!transcript.isLoaded)
        #expect(transcript.items.isEmpty)
        #expect(transcript.error != nil)
    }
}
