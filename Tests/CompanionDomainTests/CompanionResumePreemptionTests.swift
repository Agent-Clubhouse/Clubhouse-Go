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
        let preparationIsHeld = try await wait { await preparation.waiting }
        try #require(preparationIsHeld)
        lifecycle.update(.background)
        let suspendedWhileHeld = try await wait { transitions == [false, true, false] }
        #expect(suspendedWhileHeld, "Background must start before the held foreground preparation returns")
        #expect(!resumed)
        await preparation.release()
        await lifecycle.settle()
        let resumeFinished = try await wait { resumed }
        #expect(resumeFinished)
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
        let preparationIsHeld = try await wait { await preparation.waiting }
        try #require(preparationIsHeld)
        lifecycle.update(.background)
        let disconnectIsHeld = try await wait { await disconnect.waiting }
        try #require(disconnectIsHeld)
        lifecycle.update(.active)
        #expect(foregrounds == 1, "A fresh foreground cannot overtake the held disconnect")
        await disconnect.release()
        let freshForegroundStarted = try await wait { foregrounds == 2 }
        #expect(freshForegroundStarted, "Fresh foreground must not wait for cancelled old preparation")
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
            let preparationIsHeld = try await wait { await preparation.waiting }
            try #require(preparationIsHeld)
            #expect(service.registeredHostIDs.isEmpty, "This regression must start before LiveService owns the host")
            await service.suspend()
            if returnToForeground { await service.resume() }
            await preparation.release()
            await registering.value
            #expect(service.registeredHostIDs == [LiveServiceHarness.hostID], "An uncancelled first registration must not disappear across lifecycle changes")
            if !returnToForeground {
                #expect(await transport.connectCount == 0)
                let registeredOffline = try await wait { store.hosts.first?.connection == .offline }
                #expect(registeredOffline)
                await service.resume()
            }
            let registeredConnected = try await wait { store.hosts.first?.connection == .connected }
            #expect(registeredConnected)
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
            let preparationIsHeld = try await wait { await preparation.waiting }
            try #require(preparationIsHeld)
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
            let preparationIsHeld = try await wait { await preparation.waiting }
            try #require(preparationIsHeld)
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

    @Test func newerRegistrationWinsWhilePreviousAdmissionIsHeld() async throws {
        let h = try await LiveServiceHarness.start()
        let preparation = ResumePreparationGate()
        let stale = await ScriptedAnnexTransport()
        let fresh = await ScriptedAnnexTransport()
        let host = try LiveServiceHarness.trustedHost()
        let old = AnnexTransportRegistry.Registration(host: host, alias: "Stale admission", transport: stale)
        let newer = AnnexTransportRegistry.Registration(host: host, alias: "Newer admission", transport: fresh)
        let registering = Task { await h.service.register(old, beforeIconWork: { await preparation.hold() }) }
        do {
            let admissionIsHeld = try await wait { await preparation.waiting }
            try #require(admissionIsHeld)
            #expect(!h.service.hasRegistration(old), "Hold before the old transport is installed")
            await h.service.register(newer)
            let newerConnected = try await wait { h.host?.connection == .connected && h.host?.name == "Newer admission" }
            try #require(newerConnected)
            #expect(h.service.hasRegistration(newer))
            await preparation.release()
            await registering.value
            #expect(h.service.hasRegistration(newer), "An older held admission must not replace the newer completed registration")
            #expect(!h.service.hasRegistration(old))
            #expect(await stale.connectCount == 0, "The superseded transport must never connect")
            #expect(await stale.subscriptionCount == 0)
            #expect(await fresh.connectCount == 1)
            #expect(await fresh.subscriptionCount == 1)
        } catch {
            registering.cancel()
            await preparation.release()
            await registering.value
            await h.service.shutdown()
            h.stop()
            throw error
        }
        registering.cancel()
        await preparation.release()
        await registering.value
        await h.service.shutdown()
        h.stop()
    }
}
