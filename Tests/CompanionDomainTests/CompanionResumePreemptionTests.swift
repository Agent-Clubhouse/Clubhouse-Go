import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// A suspension point that deliberately ignores cancellation, like an already-dispatched I/O callback.
private actor ResumePreparationGate {
    private var released = false
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !released else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        waiting = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor @Suite(.serialized) struct CompanionResumePreemptionTests {
    private func wait(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func backgroundStartsBeforeUncooperativeResumePreparationReturns() async throws {
        let preparation = ResumePreparationGate()
        defer { Task { await preparation.release() } }
        var transitions: [Bool] = []
        var resumed = false
        var sawCancellation = false
        let lifecycle = CompanionLifecycle { active in
            transitions.append(active)
            if active {
                await preparation.hold()
                sawCancellation = Task.isCancelled
                resumed = true
            }
        }
        lifecycle.update(.background)
        await lifecycle.settle()
        lifecycle.update(.active)
        try #require(try await wait { await preparation.waiting })
        lifecycle.update(.background)
        let suspendedWhileHeld = try await wait { transitions == [false, true, false] }
        #expect(suspendedWhileHeld, "Background must start before the held foreground preparation returns")
        #expect(!resumed)
        await preparation.release()
        await lifecycle.settle()
        #expect(try await wait { resumed })
        #expect(sawCancellation)
    }

    @Test func freshForegroundWaitsForSuspendButNotForCancelledPreparation() async throws {
        let preparation = ResumePreparationGate(), disconnect = ResumePreparationGate()
        defer { Task { await preparation.release(); await disconnect.release() } }
        var backgrounds = 0, foregrounds = 0
        let lifecycle = CompanionLifecycle { active in
            if active {
                foregrounds += 1
                if foregrounds == 1 { await preparation.hold() }
            } else {
                backgrounds += 1
                if backgrounds == 2 { await disconnect.hold() }
            }
        }
        lifecycle.update(.background)
        await lifecycle.settle()
        lifecycle.update(.active)
        try #require(try await wait { await preparation.waiting })
        lifecycle.update(.background)
        try #require(try await wait { await disconnect.waiting })
        lifecycle.update(.active)
        #expect(foregrounds == 1, "A fresh foreground cannot overtake the held disconnect")
        await disconnect.release()
        #expect(try await wait { foregrounds == 2 }, "Fresh foreground must not wait for cancelled old preparation")
        await lifecycle.settle()
        #expect(await preparation.waiting)
        await preparation.release()
    }

    /// Always quiesce the old task before removing its service fixture, including failed barriers.
    private func withHeldResume(_ h: LiveServiceHarness, preparation: ResumePreparationGate,
                                body: @MainActor (Task<Void, Never>) async throws -> Void) async throws {
        let oldResume = Task { await h.service.resume() }
        do { try await body(oldResume) }
        catch {
            oldResume.cancel()
            await preparation.release()
            await oldResume.value
            h.service.prepareResume = nil
            h.stop()
            throw error
        }
        oldResume.cancel()
        await preparation.release()
        await oldResume.value
        h.service.prepareResume = nil
        h.stop()
    }

    @Test(arguments: [false, true])
    func firstRegistrationSurvivesPhaseChangesDuringIconPreparation(returnToForeground: Bool) async throws {
        let preparation = ResumePreparationGate()
        let transport = await ScriptedAnnexTransport()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resume-registration-\(UUID().uuidString)")
        let service = CompanionLiveService(iconStore: CompanionIconStore(directory: directory))
        let store = CompanionStore(service: service)
        store.start()
        let registration = AnnexTransportRegistry.Registration(host: try LiveServiceHarness.trustedHost(), alias: "First registration", transport: transport)
        let registering = Task { await service.register(registration, beforeIconWork: { await preparation.hold() }) }
        do {
            try #require(try await wait { await preparation.waiting })
            #expect(service.registeredHostIDs.isEmpty, "This regression must start before LiveService owns the host")
            await service.suspend()
            if returnToForeground { await service.resume() }
            await preparation.release()
            await registering.value
            #expect(service.registeredHostIDs == [LiveServiceHarness.hostID], "An uncancelled first registration must not disappear across lifecycle changes")
            if !returnToForeground {
                #expect(await transport.connectCount == 0)
                #expect(try await wait { store.hosts.first?.connection == .offline })
                await service.resume()
            }
            #expect(try await wait { store.hosts.first?.connection == .connected })
            #expect(await transport.connectCount == 1)
        } catch {
            registering.cancel()
            await preparation.release()
            await registering.value
            await service.shutdown()
            store.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        registering.cancel()
        await preparation.release()
        await registering.value
        await service.shutdown()
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func cancelledLateRegistrationCannotReplaceFreshForegroundTransport() async throws {
        let h = try await LiveServiceHarness.start()
        let preparation = ResumePreparationGate()
        await h.service.suspend()
        let stale = await ScriptedAnnexTransport()
        h.service.prepareResume = {
            await preparation.hold()
            await h.service.register(.init(host: try! LiveServiceHarness.trustedHost(), alias: "Stale resume", transport: stale))
            return [LiveServiceHarness.hostID]
        }
        try await withHeldResume(h, preparation: preparation) { oldResume in
            try #require(try await wait { await preparation.waiting })
            oldResume.cancel()
            await h.service.suspend()
            h.service.prepareResume = nil
            await h.service.resume()
            try await h.waitUntil { h.host?.connection == .connected }
            let connects = await h.transport.connectCount
            await preparation.release()
            await oldResume.value
            #expect(await stale.connectCount == 0, "Cancelled preparation must not reopen a replacement socket after fresh foreground")
            #expect(await stale.subscriptionCount == 0)
            #expect(await h.transport.connectCount == connects)
            #expect(h.host?.name == "Fixture")
            #expect(h.host?.connection == .connected)
        }
    }

    @Test func supersededUncancelledResumeCannotReconnectAfterNewForeground() async throws {
        let h = try await LiveServiceHarness.start()
        let preparation = ResumePreparationGate()
        await h.service.suspend()
        h.service.prepareResume = { await preparation.hold(); return [] }
        try await withHeldResume(h, preparation: preparation) { oldResume in
            try #require(try await wait { await preparation.waiting })
            // Even a caller that does not propagate cancellation cannot revive an old lifecycle generation.
            await h.service.suspend()
            h.service.prepareResume = nil
            await h.service.resume()
            try await h.waitUntil { h.host?.connection == .connected }
            let connects = await h.transport.connectCount
            let subscriptions = await h.transport.subscriptionCount
            await preparation.release()
            await oldResume.value
            #expect(await h.transport.connectCount == connects)
            #expect(await h.transport.subscriptionCount == subscriptions)
            #expect(h.host?.connection == .connected)
        }
    }
}
