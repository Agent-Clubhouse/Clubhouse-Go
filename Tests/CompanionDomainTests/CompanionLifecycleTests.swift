import Testing
@testable import CompanionDomain

@MainActor struct CompanionLifecycleTests {
    @Test func foregroundThroughInactiveResumesOnce() async {
        var transitions: [Bool] = []
        let lifecycle = CompanionLifecycle { transitions.append($0) }
        lifecycle.update(.active)
        lifecycle.update(.inactive)
        lifecycle.update(.active)
        await lifecycle.settle()
        #expect(transitions.isEmpty)
        lifecycle.update(.background)
        lifecycle.update(.inactive)
        lifecycle.update(.active)
        lifecycle.update(.active)
        await lifecycle.settle()
        #expect(transitions == [false, true])
    }

    @Test func rapidForegroundWaitsForDisconnectCompletion() async {
        var transitions: [String] = []
        var disconnect: CheckedContinuation<Void, Never>?
        let lifecycle = CompanionLifecycle { active in
            if active { transitions.append("connected") }
            else {
                transitions.append("disconnecting")
                await withCheckedContinuation { disconnect = $0 }
                transitions.append("disconnected")
            }
        }
        lifecycle.update(.background)
        while disconnect == nil { await Task.yield() }
        lifecycle.update(.inactive)
        lifecycle.update(.active)
        #expect(transitions == ["disconnecting"])
        disconnect?.resume()
        await lifecycle.settle()
        #expect(transitions == ["disconnecting", "disconnected", "connected"])
    }
}
