import Testing
@testable import CompanionDomain

struct CompanionComposerReturnKeyTests {
    @Test func returnSubmitsOnceUntilReleased() {
        var key = CompanionComposerReturnKey()
        let first = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let repeated = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let forwardsRelease = key.ended()
        let next = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        #expect(first == .submit)
        #expect(repeated == .consume)
        #expect(!forwardsRelease)
        #expect(next == .submit)
    }

    @Test func shiftReturnEditsEvenWhenSendingIsDisabled() {
        var key = CompanionComposerReturnKey()
        let action = key.began(shift: true, otherModifiers: false, markedText: false, canSubmit: false)
        #expect(action == .newline)
    }

    @Test func compositionStaysWithUIKitEvenIfItCommitsBeforeKeyRepeat() {
        var key = CompanionComposerReturnKey()
        let composing = key.began(shift: false, otherModifiers: false, markedText: true, canSubmit: true)
        let repeated = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let forwardsRelease = key.ended()
        let shifted = key.began(shift: true, otherModifiers: false, markedText: true, canSubmit: true)
        #expect(composing == .system)
        #expect(repeated == .system)
        #expect(forwardsRelease)
        #expect(shifted == .system)
    }

    @Test func disabledSendConsumesTheEntirePress() {
        var key = CompanionComposerReturnKey()
        let disabled = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: false)
        let repeated = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let forwardsRelease = key.ended()
        #expect(disabled == .consume)
        #expect(repeated == .consume)
        #expect(!forwardsRelease)
    }

    @Test func otherShortcutsStayWithTheSystem() {
        var key = CompanionComposerReturnKey()
        let action = key.began(shift: false, otherModifiers: true, markedText: false, canSubmit: true)
        let forwardsRelease = key.ended()
        #expect(action == .system)
        #expect(forwardsRelease)
    }

    @Test func overlappingReturnKeysStayHeldUntilTheirOwnRelease() {
        var key = CompanionComposerReturnKey()
        let first = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let overlapping = key.began(key: .keypadEnter, shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let keypadRelease = key.ended(key: .keypadEnter)
        let repeated = key.began(shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let returnRelease = key.ended()
        let next = key.began(key: .keypadEnter, shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let unrelatedRelease = key.ended()
        let keypadRepeat = key.began(key: .keypadEnter, shift: false, otherModifiers: false, markedText: false, canSubmit: true)
        let finalRelease = key.ended(key: .keypadEnter)
        #expect(first == .submit)
        #expect(overlapping == .consume)
        #expect(!keypadRelease)
        #expect(repeated == .consume)
        #expect(!returnRelease)
        #expect(next == .submit)
        #expect(unrelatedRelease)
        #expect(keypadRepeat == .consume)
        #expect(!finalRelease)
    }
}
