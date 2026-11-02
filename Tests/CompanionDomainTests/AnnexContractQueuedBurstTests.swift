import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Only the committed desktop fixture is used; never regenerate it during a test run.
@Suite @MainActor struct AnnexContractQueuedBurstTests {
    // The desktop's failedSend scenario is named `failed` in this committed fixture.
    @Test(arguments: ["burst", "missingJoinTarget", "failed", "nativeQueue"])
    func committedBurstsMatchLiveSnapshotsAndPagedHistory(shape: String) async throws {
        let fixture = try #require(try ContractFixtures.json("queued-bursts.json")[shape])
        let events = fixture["events"].arrayValue
        let firstEvent = try #require(events.first)
        let sessionID = try #require(firstEvent["sessionId"]?.string)
        let agentID = try #require(firstEvent["agentId"]?.string)
        let native = shape == "nativeQueue"
        #expect(!events.isEmpty)
        if native {
            #expect(events.last?["type"]?.string == "turn_started", "A fixture missing its final native turn is incomplete")
            #expect(events.last?["data"]?["trigger"]?.string != "system")
        }
        let harness = try await LiveServiceHarness.start { transport in
            await transport.setCapability("events", .object(["queueState": .string("queue_state")]))
            await transport.setAgents(.array([.object(["id": .string(agentID), "name": .string("Fixture agent"), "status": .string("idle")])]))
        }
        defer { harness.stop() }
        let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "project", agentID: agentID)
        let caps: AnnexJSON = .object(["queue": .string(native ? "native" : "client")])
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: sessionID, fields: ["events": .array([]), "capabilities": caps]))
        _ = try await harness.service.history(for: target)
        var projector = CompanionChatProjector()
        projector.sessionID = sessionID; projector.queueStateEventsSupported = true; projector.updateCapabilities(caps)
        for event in events {
            // Read through the actual wire decoder before reducing or publishing the event.
            let frame: AnnexJSON = .object(["type": .string("chat:event"), "payload": .object(["agentId": .string(agentID), "event": event])])
            let envelope = try frame.decode(AnnexEnvelope.self)
            projector.apply(try #require(envelope.payload?["event"]))
            await harness.transport.emit(.message(envelope))
        }
        try await harness.waitUntil { harness.store.conversation(for: target).items == projector.items }
        let messages = projector.items.compactMap { if case .message(let m) = $0 { m } else { nil } }
        #expect(projector.queuedMessageIDs.isEmpty)
        let expectedCount = ["burst", "missingJoinTarget"].contains(shape) ? 2 : 1
        #expect(messages.count == expectedCount, "\(shape)")
        if let rowID = fixture["rowId"]?.string {
            let row = try #require(messages.first { $0.id == rowID })
            let expectedParts: [CompanionRoutedMessagePart] = try fixture["routed"].arrayValue.map { part in
                .init(sender: .init(agentID: part["sender"]?["agentId"]?.string, name: try #require(part["sender"]?["name"]?.string)),
                      text: try #require(part["text"]?.string))
            }
            #expect(row.routed == expectedParts && row.display == .others(expectedParts))
            #expect(row.queueState == .delivered)
            #expect(messages.first { $0.source == "annex" }?.id != rowID, "The user's own submission stays separate")
            if shape == "burst" {
                #expect(row.text == "2 updates, oldest first:\n\n--- 1 of 2 ---\n[FROM HELPER:Docs (durable_docs)] One.\n\n--- 2 of 2 ---\n[FROM:brave-otter@App] Two.")
            } else { #expect(row.text == "[FROM:brave-otter@App] Two.") }
        } else {
            let row = try #require(messages.first)
            #expect(row.queueState == (native ? nil : .failed))
            #expect(row.text == (native ? "Held by the CLI." : "Never sent."))
        }
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: sessionID, fields: ["events": .array(events), "capabilities": caps]))
        #expect(try await harness.service.history(for: target).items == projector.items)

        // Dead snapshots carry no current session capabilities. Replay their own events, not today's host gate.
        await harness.transport.setRead("chat", LiveServiceHarness.chatSnapshot(session: sessionID, fields: [
            "events": .array(events), "capabilities": .null, "readOnly": .bool(true), "state": .string("sleeping"),
            "queueStateSeq": .integer(0), "queuedMessageIds": .array([]), "queueRemovalSupported": .bool(false)]))
        #expect(try await harness.service.history(for: target).items == projector.items)

        // Load one event at a time backwards, including an overlapping event, as real archive pages do.
        let reader = CompanionArchiveReader(transport: harness.transport, target: target, sessionID: sessionID)
        var page: CompanionArchivePage?
        for index in events.indices.reversed() {
            let overlapEnd = min(index + 2, events.count)
            var snapshot: [String: AnnexJSON] = ["sessionId": .string(sessionID), "events": .array(Array(events[index..<overlapEnd]))]
            if index > 0 { snapshot["nextBeforeSeq"] = events[index]["seq"] }
            await harness.transport.setRead("chatHistory", .object(snapshot))
            page = try await reader.load(before: page?.nextBeforeSequence)
        }
        #expect(page?.items == projector.items && page?.nextBeforeSequence == nil)
    }
}
