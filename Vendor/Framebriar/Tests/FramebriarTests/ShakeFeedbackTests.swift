import Testing
import FramebriarUI

@Test func shakeOpensOnceAndDebouncesRepeatedMotion() {
    var gate = ShakeFeedbackGate()
    func event(_ time: Double) -> Bool {
        gate.shouldOpen(at: time, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false)
    }
    #expect(event(100))
    #expect(!event(100.1))
    #expect(!event(102)) // Cooldown starts at most recent motion, not first motion.
    #expect(event(104))
}

@Test func shakeNeverOpensWhenDisabledUnenrolledInactiveOrEditing() {
    var gate = ShakeFeedbackGate()
    #expect({ !gate.shouldOpen(at: 1, enabled: false, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ !gate.shouldOpen(at: 2, enabled: true, canSubmit: false, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ !gate.shouldOpen(at: 3, enabled: true, canSubmit: true, isActive: false, isPresenting: false, isEditing: false) }())
    #expect({ !gate.shouldOpen(at: 4, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: true) }())
    #expect({ !gate.shouldOpen(at: 5, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ gate.shouldOpen(at: 7, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
}

@Test func presentationSuppressesShakeIncludingImmediatelyAfterDismissal() {
    var gate = ShakeFeedbackGate()
    #expect({ !gate.shouldOpen(at: 10, enabled: true, canSubmit: true, isActive: true, isPresenting: true, isEditing: false) }())
    #expect({ !gate.shouldOpen(at: 11, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ gate.shouldOpen(at: 13, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ !gate.shouldOpen(at: 16, enabled: true, canSubmit: true, isActive: true, isPresenting: true, isEditing: false) }())
}

@Test func invalidOrRegressingMotionClockFailsClosed() {
    var gate = ShakeFeedbackGate()
    for time in [Double.nan, .infinity, -1] {
        #expect({ !gate.shouldOpen(at: time, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    }
    #expect({ gate.shouldOpen(at: 100, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ !gate.shouldOpen(at: 50, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
    #expect({ gate.shouldOpen(at: 52, enabled: true, canSubmit: true, isActive: true, isPresenting: false, isEditing: false) }())
}
