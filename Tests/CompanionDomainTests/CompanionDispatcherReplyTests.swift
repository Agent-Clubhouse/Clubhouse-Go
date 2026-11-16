import Testing
@testable import CompanionDomain

struct CompanionDispatcherReplyTests {
    private func checkpoint(_ id: String?, host: String = "a", session: String = "session") -> CompanionDispatcherReplyCheckpoint {
        let target = CompanionTarget(hostID: host, projectID: "__dispatcher__", agentID: "dispatcher")
        var conversation = CompanionConversation()
        conversation.sessionID = session
        if let id { conversation.items = [.message(.init(id: id, role: .assistant, text: "Reply"))] }
        return .init(target: target, conversation: conversation)
    }
    @Test func initialHistoryIsBaselineAndCachedNewRepliesBadgeUntilReadAtLatest() {
        var replies = CompanionDispatcherReplies()
        replies.update(["a": checkpoint("old")], visibleHostID: nil, followsLatest: true)
        #expect(replies.unreadHostIDs.isEmpty)
        replies.update(["a": checkpoint("new")], visibleHostID: nil, followsLatest: true)
        #expect(replies.unreadHostIDs == ["a"])
        replies.update(["a": checkpoint("new")], visibleHostID: "a", followsLatest: false)
        #expect(replies.unreadHostIDs == ["a"], "Reading earlier messages doesn't claim to have seen the reply")
        replies.update(["a": checkpoint("new")], visibleHostID: "a", followsLatest: true)
        #expect(replies.unreadHostIDs.isEmpty)
        replies.update(["a": checkpoint("live")], visibleHostID: "a", followsLatest: true)
        #expect(replies.unreadHostIDs.isEmpty, "A visible, following chat is already reading its reply")
    }
    @Test func sessionReplacementAndForgottenHostsDiscardLaunchMarkers() {
        var replies = CompanionDispatcherReplies()
        replies.update(["a": checkpoint(nil)], visibleHostID: nil, followsLatest: true)
        replies.update(["a": checkpoint("first")], visibleHostID: nil, followsLatest: true)
        #expect(replies.unreadHostIDs == ["a"])
        replies.update(["a": checkpoint("different", session: "replacement")], visibleHostID: nil, followsLatest: true)
        #expect(replies.unreadHostIDs.isEmpty)
        replies.update(["a": checkpoint("later", session: "replacement")], visibleHostID: nil, followsLatest: true)
        #expect(replies.unreadHostIDs == ["a"])
        replies.update([:], visibleHostID: nil, followsLatest: true)
        #expect(replies.unreadHostIDs.isEmpty)
    }
    @Test func userToolsAndStreamingDeltasDoNotInventAdditionalAssistantReplies() {
        let target = CompanionTarget(hostID: "a", projectID: "__dispatcher__", agentID: "dispatcher")
        var conversation = CompanionConversation()
        conversation.items = [.message(.init(id: "reply", role: .assistant, text: "First", isStreaming: true))]
        let first = CompanionDispatcherReplyCheckpoint(target: target, conversation: conversation)
        conversation.items += [.message(.init(id: "user", role: .user, text: "Follow up")), .notice(id: "tool", text: "Tool finished")]
        let second = CompanionDispatcherReplyCheckpoint(target: target, conversation: conversation)
        #expect(first == second)
        conversation.items[0] = .message(.init(id: "reply", role: .assistant, text: "First continued", isStreaming: false))
        #expect(CompanionDispatcherReplyCheckpoint(target: target, conversation: conversation) == first)
    }
}
