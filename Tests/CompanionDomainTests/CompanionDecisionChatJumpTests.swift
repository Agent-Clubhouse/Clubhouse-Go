import Foundation
import Testing
@testable import CompanionDomain

@Suite struct CompanionDecisionChatJumpTests {
    @Test func aHiddenRequestWaitsForMatchingAdmission() {
        var owner = CompanionDecisionChatJumps()
        let request = CompanionDecisionChatJump(itemID: "approval:first")
        owner.request(request)
        owner.finish(request.id)
        #expect(owner.pending == request, "Cancellation before admission cannot consume a hidden request")
        let admitted1 = owner.begin(UUID())
        #expect(!admitted1)
        #expect(owner.pending == request)
        let admitted2 = owner.begin(request.id)
        #expect(admitted2)
        #expect(owner.pending == request, "Claiming must not change the running task's identity")
    }

    @Test func aClaimCannotReplayDuringRemountOrAfterCompletion() {
        var owner = CompanionDecisionChatJumps()
        let request = CompanionDecisionChatJump(itemID: "approval:first")
        owner.request(request)
        let admitted3 = owner.begin(request.id)
        #expect(admitted3)
        let admitted4 = owner.begin(request.id)
        #expect(!admitted4, "A rapid remount must not admit a second task before the first finishes")
        owner.finish(request.id)
        #expect(owner.pending == nil)
        owner.request(request)
        #expect(owner.pending == nil)
        let admitted5 = owner.begin(request.id)
        #expect(!admitted5)
    }

    @Test func cancelledAdmissionConsumesOnceButANewHumanRequestStillWorks() {
        var owner = CompanionDecisionChatJumps()
        let first = CompanionDecisionChatJump(itemID: "approval:first")
        owner.request(first)
        let admitted6 = owner.begin(first.id)
        #expect(admitted6)
        owner.finish(first.id) // The same finish runs when an admitted restoration is cancelled.
        let next = CompanionDecisionChatJump(itemID: first.itemID)
        #expect(next.id != first.id)
        owner.request(next)
        let admitted7 = owner.begin(next.id)
        #expect(admitted7, "An explicit new action may revisit the same item")
        owner.finish(next.id)
        #expect(owner.pending == nil)
    }

    @Test func anOldCompletionCannotClearANewerUnclaimedRequest() {
        var owner = CompanionDecisionChatJumps()
        let first = CompanionDecisionChatJump(itemID: "approval:first")
        let next = CompanionDecisionChatJump(itemID: "approval:next")
        owner.request(first)
        let admitted8 = owner.begin(first.id)
        #expect(admitted8)
        owner.request(next)
        owner.finish(first.id)
        #expect(owner.pending == next)
        let admitted9 = owner.begin(next.id)
        #expect(admitted9)
        owner.finish(next.id)
        #expect(owner.pending == nil)
    }

    @Test func anOldFinishOrRequeueCannotReplaceANewerAdmittedRequest() {
        var owner = CompanionDecisionChatJumps()
        let first = CompanionDecisionChatJump(itemID: "approval:first")
        let next = CompanionDecisionChatJump(itemID: "approval:next")
        owner.request(first)
        let admitted10 = owner.begin(first.id)
        #expect(admitted10)
        owner.request(next)
        let admitted11 = owner.begin(next.id)
        #expect(admitted11)
        owner.finish(first.id)
        owner.request(first)
        #expect(owner.pending == next)
        owner.finish(next.id)
        owner.request(first)
        #expect(owner.pending == nil, "An older UUID remains consumed after a later request finishes")
    }
}
