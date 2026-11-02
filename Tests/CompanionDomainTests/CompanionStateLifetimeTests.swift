import Testing
@testable import CompanionDomain

@MainActor struct CompanionStateLifetimeTests {
    @Test func unusedStateInitialValuesHaveNoSideEffects() {
        var sinkOwner = 0
        let retained = CompanionStateLifetime { sinkOwner += 1; return sinkOwner }
        #expect(sinkOwner == 0)
        #expect(retained.value == 1)
        _ = CompanionStateLifetime { sinkOwner += 1; return sinkOwner }
        #expect(retained.value == 1)
        #expect(sinkOwner == 1)
    }
}
