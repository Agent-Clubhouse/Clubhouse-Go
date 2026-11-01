import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Ports desktop message-routing.test.ts and the sender/fold rules in MessageBlocks.test.tsx.
@Suite struct CompanionMessageRoutingTests {
    /// The real fixtures cover single, burst, Clubhouse and unattributed deliveries. Helper questions, task markers,
    /// footer anchors and malformed input below remain explicit edge cases not present in that fixture corpus.
    @Test func recordedDeliveriesHaveTheSameBodiesInStructuredAndLegacyRouting() throws {
        let cases: [(String, [CompanionRoutedMessagePart])] = [
            ("msg_routed_one", [from("Docs", "The docs are up to date.", id: "durable_docs")]),
            ("msg_routed_burst", [from("Docs", "Started on the guide.", id: "durable_docs"), from("reviewer", "The tests pass.")]),
            ("msg_routed_clubhouse", [.init(fromClubhouse: true, text: "Docs was disposed.")]),
            ("msg_routed_no_sender", [.init(text: "The nightly build finished.")])
        ]
        for (id, expected) in cases {
            var projector = CompanionChatProjector()
            projector.apply(try ContractFixtures.chatEvent(id))
            let message = try #require(projector.items.compactMap { if case .message(let m) = $0 { m } else { nil } }.first)
            #expect(message.routed == expected)
            #expect(display("mcp", message.text, routed: message.routed) == .others(expected))
            // The legacy text contains names, but not the structured sender's stable agent id.
            let legacy = expected.map { part -> CompanionRoutedMessagePart in
                var part = part; part.sender?.agentID = nil; return part
            }
            #expect(CompanionMessageRouting.parseRoutedText(message.text) == legacy)
        }
    }
    private let reply = "\n\n---\nReply to rover via tool \"clubhouse__x__send_message\" with task_id=\"t_1\". Prefix your response with TASK_RESULT:t_1."
    private let mission = "\n\n---\nYou are a helper agent started by boss. Use the message_parent tool to send boss your progress, questions and results."
    private func from(_ name: String, _ text: String, id: String? = nil) -> CompanionRoutedMessagePart {
        .init(sender: .init(agentID: id, name: name), text: text)
    }
    private func display(_ source: String, _ text: String, routed: [CompanionRoutedMessagePart] = []) -> CompanionMessageDisplay {
        CompanionMessageRouting.display(source: source, text: text, routed: routed)
    }

    @Test func readsSendMessageReplyAndOptionalTaskAndProject() {
        #expect(CompanionMessageRouting.parseRoutedText("[TASK:t_1] [FROM:rover@Clubhouse] Hello there.\(reply)") == [from("rover", "Hello there.")])
        #expect(CompanionMessageRouting.parseRoutedText("[TASK:t_1] [FROM:Dispatcher] Hi") == [from("Dispatcher", "Hi")])
        #expect(CompanionMessageRouting.parseRoutedText("[FROM:a@b@project] Hi") == [from("a@b", "Hi")])
    }

    @Test func readsHelperAndQuestionWithID() {
        #expect(CompanionMessageRouting.parseRoutedText("[FROM HELPER:typecheck-leak (durable_1)] All\ngreen.") == [from("typecheck-leak", "All\ngreen.", id: "durable_1")])
        let question = "[QUESTION FROM HELPER:h (durable_2)] h is waiting for your answer. Answer with answer_helper_question, requestId \"hq_1\". If the user should decide, call it with escalate: true instead.\n1. Which one?"
        #expect(CompanionMessageRouting.parseRoutedText(question) == [from("h", "1. Which one?", id: "durable_2")])
    }

    @Test func removesHelperMissionAndFileInstructions() {
        #expect(CompanionMessageRouting.parseRoutedText("[FROM:boss] Do it\(mission)") == [from("boss", "Do it")])
        #expect(CompanionMessageRouting.parseRoutedText("[FROM:boss] Do it\(mission)\n\n[FROM:boss] And this") == [from("boss", "Do it\n\nAnd this")])
        #expect(CompanionMessageRouting.parseRoutedText("[TASK:t_1] [FROM:rover@p] File delivered: /tmp/a.md — read this file for content from rover@p.") == [from("rover", "File delivered: /tmp/a.md")])
    }

    @Test func footerEndAnchorsRequireTheActualEndLikeJavaScript() {
        #expect(CompanionMessageRouting.parseRoutedText("[FROM:rover] Hi\(reply)\n") == [from("rover", "Hi\(reply)\n")])
        let notice = "File delivered: /tmp/a.md — read this file for content from rover.\n"
        #expect(CompanionMessageRouting.parseRoutedText("[FROM:rover] " + notice) == [from("rover", notice)])
    }

    @Test func leavesUntaggedAndMalformedTagsAndBurstsWhole() {
        for text in ["Just text about [FROM:x] tags", "3 updates, oldest first:\n\nnot really", "2 updates, oldest first:\n\n--- 1 of 2 ---\none", "[FROM:x]no space", "[TASK:] [FROM:x] text", " [FROM:x] text", "[FROM:] text", "[FROM:x]\ntext", "[Clubhouse]no space", "[FROM HELPER:h (a)]no space"] {
            #expect(CompanionMessageRouting.parseRoutedText(text) == [.init(text: text)])
        }
    }

    @Test func stripsOnlyLeadingTaskMarkers() {
        for (text, expected) in [("TASK_RESULT:t_1: done", "done"), ("TASK_RESULT:t_1 done", "done"), ("TASK_ACK:t_1: on it", "on it"), ("TASK_ACK:t", ""), ("I printed TASK_RESULT:t_1 above", "I printed TASK_RESULT:t_1 above")] {
            #expect(CompanionMessageRouting.stripTaskMarker(text) == expected)
        }
        #expect(display("mcp", "[TASK:t_2] [FROM:a@p] TASK_RESULT:t_1: done") == .others([from("a", "done")]))
        #expect(display("mcp", "raw", routed: [from("a", "TASK_RESULT:t_1: done")]) == .others([from("a", "done")]))
    }

    @Test func neverParsesUserTextAndPrefersStructuredParts() {
        #expect(display("user", "[FROM:boss] hi") == .you("[FROM:boss] hi"))
        #expect(display("annex", "[Clubhouse] hi", routed: [from("a", "x")]) == .you("[Clubhouse] hi"))
        let parts = [from("real", "[FROM:fake] hi", id: "durable_1")]
        #expect(display("mcp", "[FROM:real] [FROM:fake] hi", routed: parts) == .others(parts))
        #expect(display("system", "raw", routed: parts) == .others(parts))
    }

    @Test func missionAndUntaggedMCPAndSystemAndGroupProject() {
        #expect(display("mission", "Fix it") == .you("Fix it"))
        #expect(display("mission", "[FROM:boss] Fix it\(mission)") == .others([from("boss", "Fix it")]))
        #expect(display("mcp", "hello") == .others([.init(text: "hello")]))
        #expect(display("system", "Continued") == .others([.init(fromClubhouse: true, text: "Continued")]))
        #expect(display("group_project", "[FROM:x] Nudge") == .others([.init(text: "[FROM:x] Nudge")]))
    }

    @Test func shoulderTapsFromAgentAndUserAndMalformed() {
        func tap(_ name: String) -> String { "Group Project notification — shoulder tap from \"\(name)\" in \"Proj\"\nLook here\n\n---\nRESPONSE INSTRUCTIONS:\nProject: \"Proj\" (ID: 1)\nTask ID: tap_1" }
        #expect(display("shoulder_tap", tap("rover@Proj")) == .others([from("rover", "Look here")]))
        #expect(display("shoulder_tap", tap("user")) == .you("Look here"))
        #expect(display("shoulder_tap", "raw") == .others([.init(text: "raw")]))
    }

    @Test func lengthAndLineBoundariesMatchJavaScript() {
        #expect(!CompanionMessageRouting.isLongMessage(String(repeating: "x", count: 800)))
        #expect(CompanionMessageRouting.isLongMessage(String(repeating: "x", count: 801)))
        #expect(!CompanionMessageRouting.isLongMessage(Array(repeating: "y", count: 14).joined(separator: "\n")))
        #expect(CompanionMessageRouting.isLongMessage(Array(repeating: "y", count: 15).joined(separator: "\n")))
        #expect(!CompanionMessageRouting.isLongMessage(Array(repeating: "y", count: 14).joined(separator: "\r\n")))
        #expect(CompanionMessageRouting.isLongMessage(Array(repeating: "y", count: 15).joined(separator: "\r\n")), "JavaScript splits LF even inside CRLF")
        #expect(CompanionMessageRouting.isLongMessage(String(repeating: "\n", count: 14)), "Trailing and empty lines count")
        #expect(!CompanionMessageRouting.isLongMessage(String(repeating: "😀", count: 400)))
        #expect(CompanionMessageRouting.isLongMessage(String(repeating: "😀", count: 401)), "Desktop counts UTF-16 units")
    }

    @Test func cachedDisplayTracksInputChangesAndKeepsCopyRaw() {
        var message = CompanionMessage(id: "m", role: .user, text: "[FROM:old] hi", source: "mcp")
        #expect(message.display == .others([from("old", "hi")]))
        message.text = "[FROM:new] bye"
        #expect(message.display == .others([from("new", "bye")]))
        message.routed = [from("actual", "TASK_ACK:t: Ready")]
        #expect(message.display == .others([from("actual", "Ready")]))
        #expect(message.text == "[FROM:new] bye")
        message.source = "user"
        #expect(message.display == .you(message.text))
    }
}

@Suite struct CompanionSenderTreatmentTests {
    private func agent(_ id: String, name: String, project: String = "p") -> CompanionAgent {
        .init(id: .init(hostID: "h", projectID: project, agentID: id), name: name, subtitle: "", status: .idle, color: "rose", emoji: "🌿", iconData: Data([1, 2]))
    }

    @Test func resolvesByIDThenUniqueExactNameWithoutGuessing() {
        let a = agent("a", name: "Renamed")
        let b = agent("b", name: "Unique", project: "other")
        let resolver = CompanionSenderResolver(agents: [a, b, agent("c", name: "Duplicate"), agent("d", name: "Duplicate")])
        #expect(resolver.resolve(.init(agentID: "a", name: "Old")) == CompanionSenderIdentity(agent: a))
        #expect(resolver.resolve(.init(name: "Unique")) == CompanionSenderIdentity(agent: b))
        #expect(resolver.resolve(.init(name: "unique")) == nil)
        #expect(resolver.resolve(.init(name: "Duplicate")) == nil)
        #expect(resolver.resolve(.init(agentID: "gone", name: "Unique")) == nil, "A gone ID must not fall back to another agent's name")
        #expect(resolver.resolve(nil) == nil)
        let gone = resolver.avatarIdentity(for: .init(agentID: "gone", name: "old-helper"))
        #expect(gone?.name == "old-helper" && gone?.color == nil && gone?.emoji == nil && gone?.iconData == nil)
        #expect(resolver.avatarIdentity(for: nil) == nil, "Clubhouse and unnamed parts have no avatar")
    }

    @Test func resolverEqualityIgnoresRuntimeStateAndInputOrder() {
        let first = agent("a", name: "A")
        let second = agent("b", name: "B")
        var updated = first
        updated.status = .working; updated.subtitle = "Streaming a reply"; updated.model = "New model"
        updated.capabilities = [.chat, .steer]; updated.lastActivity = Date(); updated.isQuick = true
        #expect(CompanionSenderResolver(agents: [first, second]) == CompanionSenderResolver(agents: [second, updated]))
    }

    @Test func resolverEqualityTracksEveryVisibleIdentityFieldAndNameAmbiguity() {
        let original = agent("a", name: "Original")
        let resolver = CompanionSenderResolver(agents: [original])
        var changed = original
        changed.name = "Renamed"
        #expect(resolver != CompanionSenderResolver(agents: [changed]))
        changed = original; changed.color = "cyan"
        #expect(resolver != CompanionSenderResolver(agents: [changed]))
        changed = original; changed.emoji = "✨"
        #expect(resolver != CompanionSenderResolver(agents: [changed]))
        changed = original; changed.iconData = Data([3])
        #expect(resolver != CompanionSenderResolver(agents: [changed]))
        changed = original; changed.id.agentID = "different"
        #expect(resolver != CompanionSenderResolver(agents: [changed]))
        #expect(resolver != CompanionSenderResolver(agents: [original, agent("b", name: original.name)]))
    }

    @MainActor @Test func resolverUsesAllHostProjectsAndDispatcherAndCurrentIdentity() {
        var host = CompanionPreviewService.hosts(now: Date(), dispatcher: true)[0]
        let dispatcher = host.dispatcher!.liveAgent!
        var sender = host.projects[0].agents[0]
        let oldName = sender.name
        let sent = CompanionRoutedMessagePart.Sender(agentID: sender.id.agentID, name: oldName)
        sender.name = "Renamed"; sender.color = "emerald"; sender.emoji = "✨"; sender.iconData = Data([3])
        host.projects[0].agents[0] = sender
        let resolver = CompanionSenderResolver(agents: host.allAgents)
        #expect(resolver.resolve(sent) == CompanionSenderIdentity(agent: sender))
        #expect(resolver.resolve(.init(name: dispatcher.name)) == CompanionSenderIdentity(agent: dispatcher))
    }

    @MainActor @Test func foldsIndependentlyAndSurvivesSnapshotCatalogAndNavigation() async throws {
        let service = CompanionPreviewService()
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.hosts(now: Date())[0].projects[0].agents[0].id
        await store.load(target)
        let expansion = store.transcriptExpansion(for: target)
        let first = expansion.part(messageID: "m", index: 0)
        let second = expansion.part(messageID: "m", index: 1)
        let long = String(repeating: "x", count: 801)
        #expect(!first.isOpen(for: long) && !second.isOpen(for: long))
        #expect(first.isOpen(for: "short"))
        first.open = true
        await store.load(target, force: true)
        store.hosts = CompanionPreviewService.hosts(now: Date(), dispatcher: true)
        #expect(store.transcriptExpansion(for: target).part(messageID: "m", index: 0) === first)
        #expect(first.isOpen(for: long) && !second.isOpen(for: long))
        first.open = false
        #expect(!store.transcriptExpansion(for: target).part(messageID: "m", index: 0).isOpen(for: long))
        #expect(store.transcriptExpansion(for: target, sessionID: "archive").part(messageID: "m", index: 0) !== first)
        #expect(store.transcriptExpansion(for: .init(hostID: "other", projectID: target.projectID, agentID: target.agentID)).part(messageID: "m", index: 0) !== first)
    }
}
