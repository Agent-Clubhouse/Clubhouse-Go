import Foundation
import Testing

@testable import ClubhouseTransport
@testable import CompanionDomain

/// Regression coverage for go-icon-cache/frame-over-limit-audit's canvas and omitted-text cases.
/// Incoming payloads are the desktop's canonical fixture; only its documented variable seq is filled.
@MainActor struct AnnexContractFrameLimitTests {
    @Test func omittedInlineIconsKeepCachedAgentAndProjectAvatarsUntilCompleteReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let icons = CompanionIconStore(directory: root)
        let h = try await LiveServiceHarness.start(iconStore: icons)
        defer { h.stop() }
        let data = try CompanionIconStoreTests.png()
        let image = AnnexJSON.string("data:image/png;base64," + data.base64EncodedString())
        let maps: [String: AnnexJSON] = [
            "agentIcons": .object(["agent": image]), "projectIcons": .object(["project": image])
        ]
        await h.transport.emit(h.snapshotEvent(maps))
        try await h.waitUntil { h.host?.projects.first?.agents.first?.icon != nil && h.host?.projects.first?.icon != nil }
        let agent = try #require(h.host?.projects.first?.agents.first?.icon)
        let project = try #require(h.host?.projects.first?.icon)
        #expect(await icons.image(for: agent, points: 32) != nil)
        #expect(await icons.image(for: project, points: 32) != nil)

        let fixture = try #require(ContractFixtures.json("snapshot-truncated.json")["value"])
        var canvasOnly = maps
        canvasOnly["snapshotTruncated"] = fixture["snapshotTruncated"]
        canvasOnly["helperRoutingRevision"] = .string("canvas-only")
        await h.transport.emit(h.snapshotEvent(canvasOnly))
        try await h.waitUntil { h.host?.helperRoutingRevision == "canvas-only" }
        #expect(h.host?.snapshotTruncationNotice == nil)

        for fields in [["agentIcons"], ["projectIcons"], ["agentIcons", "projectIcons"]] {
            guard case .object(var marker)? = fixture["snapshotTruncated"] else { Issue.record("Missing truncation"); return }
            marker["omitted"] = .array(fields.map(AnnexJSON.string))
            var omitted = maps
            for field in fields { omitted[field] = .object([:]) }
            omitted["snapshotTruncated"] = .object(marker)
            let revision = fields.joined(separator: "-")
            omitted["helperRoutingRevision"] = .string(revision)
            await h.transport.emit(h.snapshotEvent(omitted))
            try await h.waitUntil { h.host?.helperRoutingRevision == revision }
            #expect(h.host?.projects.first?.agents.first?.icon == agent)
            #expect(h.host?.projects.first?.icon == project)
            #expect(h.host?.snapshotTruncationNotice != nil)
            #expect(h.host?.connection == .connected && h.store.canOperate(h.target))
            #expect(await icons.image(for: agent, points: 32) != nil)
            #expect(await icons.image(for: project, points: 32) != nil)
        }
        await h.transport.emit(h.snapshotEvent(["agentIcons": .object([:]), "projectIcons": .object([:])]))
        try await h.waitUntil { h.host?.projects.first?.agents.first?.icon == nil && h.host?.projects.first?.icon == nil }
        #expect(h.host?.snapshotTruncationNotice == nil)
    }

    private func history(final: Bool = false) -> AnnexJSON {
        let events: [AnnexJSON] = [
            LiveServiceHarness.chatEvent(
                "session_fixture", sequence: 2, type: "user_message",
                data: [
                    "messageId": .string("queued"), "delivery": .string("queued"),
                    "content": .array([.object(["type": .string("text"), "text": .string("Queued prompt")])]),
                ]),
            LiveServiceHarness.chatEvent(
                "session_fixture", sequence: 3, type: "permission_request",
                data: [
                    "requestId": .string("permission"), "title": .string("Review this change"), "options": .array([]),
                ]),
            LiveServiceHarness.chatEvent(
                "session_fixture", sequence: 4, type: "question",
                data: [
                    "requestId": .string("question"),
                    "questions": .array([
                        .object(["id": .string("which"), "prompt": .string("Which branch?"), "allowFreeText": .bool(true)])
                    ]),
                ]),
            LiveServiceHarness.chatEvent(
                "session_fixture", sequence: 5, type: "queue_state",
                data: [
                    "queuedMessageIds": .array([.string("queued")])
                ]),
            LiveServiceHarness.chatEvent(
                "session_fixture", sequence: 6, type: "agent_message_chunk",
                data: [
                    "messageId": .string("answer"), "text": .string("Visible prefix"),
                ]),
        ]
        let completed =
            final
            ? [
                LiveServiceHarness.chatEvent(
                    "session_fixture", sequence: 8, type: "agent_message",
                    data: [
                        "messageId": .string("answer"), "text": .string("Complete answer from history"),
                    ])
            ] : []
        return LiveServiceHarness.chatSnapshot(
            session: "session_fixture", events: events + completed,
            fields: [
                "state": .string(final ? "idle" : "running"), "queuedMessageIds": .array([.string("queued")]),
                "queueStateSeq": .integer(5), "queueRemovalSupported": .bool(true),
                "capabilities": .object(["chat": .bool(true), "queue": .string("client")]),
            ])
    }

    @Test func canvasAndOmittedMarkersKeepChatAndCriticalStateUntilHistoryRecoversText() async throws {
        let h = try await LiveServiceHarness.start()
        defer { h.stop() }
        await h.transport.setRead("chat", history())
        await h.store.load(h.target, force: true)
        let before = h.store.conversation(for: h.target)
        #expect(before.lastSequence == 6 && before.error == nil)
        #expect(before.items.contains { if case .approval(let p) = $0 { p.resolution == .pending } else { false } })
        #expect(before.items.contains { if case .question(let q) = $0 { q.resolution == .pending } else { false } })
        #expect(before.items.contains { if case .message(let m) = $0 { m.id == "queued" && m.queueState == .queued } else { false } })

        let fixture = try ContractFixtures.json("frames-over-limit.json")
        for key in ["canvasMarker", "appCanvasMarker", "omitted"] {
            guard case .object(var recorded)? = fixture[key] else {
                Issue.record("Missing \(key)")
                return
            }
            if key == "omitted" { recorded["seq"] = .integer(7) }
            let frame = try JSONDecoder().decode(AnnexEnvelope.self, from: JSONEncoder().encode(AnnexJSON.object(recorded)))
            await h.transport.emit(.message(frame))
        }
        // A known frame is an observable FIFO barrier after the three otherwise ignored messages.
        await h.transport.emit(
            .message(.init(type: "helper_routing:changed", payload: .object(["revision": .string("frame-limit-fixture-done")]))))
        try await h.waitUntil { h.host?.helperRoutingRevision == "frame-limit-fixture-done" }
        #expect(h.store.conversation(for: h.target) == before)
        #expect(h.host?.snapshotTruncationNotice == nil)
        #expect(h.host?.connection == .connected && h.store.canOperate(h.target))

        await h.transport.emit(LiveServiceHarness.chatEvent("session_fixture", sequence: 7, type: "turn_ended", data: [:]).transportEvent)
        try await h.waitUntil { h.store.conversation(for: h.target).lastSequence == 7 }
        let ended = h.store.conversation(for: h.target)
        #expect(
            ended.items.contains {
                if case .message(let m) = $0 { m.id == "answer" && m.text == "Visible prefix" && !m.isStreaming } else { false }
            })
        // The fixture's marker is deliberately not a chat notice or a replacement for missing text.
        #expect(!ended.items.contains { if case .notice = $0 { true } else { false } })
        await h.transport.setRead("chat", history(final: true))
        await h.store.load(h.target, force: true)
        let recovered = h.store.conversation(for: h.target)
        #expect(recovered.items.filter { $0.id == "message:answer" }.count == 1)
        #expect(
            recovered.items.contains {
                if case .message(let m) = $0 {
                    m.id == "answer" && m.text == "Complete answer from history" && !m.isStreaming
                } else {
                    false
                }
            })
        await h.store.load(h.target, force: true)
        #expect(h.store.conversation(for: h.target).items == recovered.items)
    }
}

extension AnnexJSON {
    fileprivate var transportEvent: AnnexTransportEvent {
        .message(.init(type: "chat:event", payload: .object(["agentId": .string("agent"), "event": self])))
    }
}
