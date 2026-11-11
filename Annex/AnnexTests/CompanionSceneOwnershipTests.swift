import XCTest
import SwiftUI
import Framebriar
import FramebriarUI
@testable import ClubhouseTransport
@testable import ClubhouseGo

/// All reports, enrollment, defaults and desktop traffic are synthetic and local to this test.
@MainActor final class CompanionSceneOwnershipTests: XCTestCase {
    func testBuiltManifestRequiresOneScene() throws {
        let manifest = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        XCTAssertFalse(UIApplication.shared.supportsMultipleScenes)
    }

    func testSceneActivationOwnership() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing") else {
            throw XCTSkip("Requires isolated scene test launch argument")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try Configuration(gameID: "scene-fixture")
        let fileStore = try FileFeedbackStore(directory: directory)
        try fileStore.save([
            QueuedFeedback(feedback: ReviewedFeedback(configuration: config, notes: "Queued scene fixture"), nextAttemptAt: Date(timeIntervalSince1970: 4_000_000_000), enrollmentRef: "scene-enrollment"),
            QueuedFeedback(feedback: ReviewedFeedback(configuration: config, notes: "Held scene fixture"), blocked: true, enrollmentRef: "previous-enrollment", heldForEnrollment: true)
        ], scope: config.storageScope)
        let queueFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let originalQueue = try Data(contentsOf: queueFile)
        let enrollment = SceneEnrollment()
        let network = SceneHTTP()
        let source = AnnexTelemetry()
        var runtimes: [CompanionRuntime] = []
        var transports: [SceneTransport] = []
        var registrations: [Task<Void, Never>] = []
        CompanionSceneTestSupport.makeFeedback = {
            let client = try! Client(configuration: config, transport: network, enrollmentStore: enrollment,
                                     feedbackStore: FileFeedbackStore(directory: directory))
            return CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: false)
        }
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "scene.invalid", port: 443), verifiedHostID: Array(repeating: "ab", count: 16).joined(separator: ":"),
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        CompanionSceneTestSupport.didCreateRuntime = { runtime in
            runtimes.append(runtime)
            let transport = SceneTransport(); transports.append(transport)
            registrations.append(Task { await runtime.service.register(.init(host: host, alias: "Synthetic desktop", transport: transport)) })
        }
        defer {
            for runtime in runtimes { runtime.appTelemetry?.stop(); runtime.service.remove(hostID: host.hostID) }
            CompanionSceneTestSupport.makeFeedback = nil
            CompanionSceneTestSupport.didCreateRuntime = nil
            try? FileManager.default.removeItem(at: directory)
        }
        CompanionSceneTestSupport.ready = true
        try await wait { runtimes.count == 1 }
        for task in registrations { await task.value }
        print("SCENE_BEFORE runtimes=\(runtimes.count) clients=\(Set(runtimes.compactMap { $0.feedback.map { ObjectIdentifier($0.client) } }).count) bridges=\(runtimes.compactMap(\.appTelemetry).count) sessions=\(UIApplication.shared.openSessions.count)")
        var activationError: Error?
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) { activationError = $0 }
        let multiple = UIApplication.shared.supportsMultipleScenes
        XCTAssertFalse(multiple)
        try await Task.sleep(for: .seconds(3))
        for task in registrations { await task.value }
        let counts = await transports.asyncCounts()
        let clients = Set(runtimes.compactMap { $0.feedback.map { ObjectIdentifier($0.client) } }).count
        print("SCENE_AFTER supportsMultiple=\(multiple) runtimes=\(runtimes.count) clients=\(clients) bridges=\(runtimes.compactMap(\.appTelemetry).count) transports=\(transports.count) hostConnectCounts=\(counts) sessions=\(UIApplication.shared.openSessions.count) connectedScenes=\(UIApplication.shared.connectedScenes.count) activationError=\(activationError.map { String(describing: $0) } ?? "none")")
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(UIApplication.shared.connectedScenes.filter { $0 is UIWindowScene }.count, 1)
        XCTAssertEqual(clients, runtimes.count)
        XCTAssertEqual(transports.count, runtimes.count)
        XCTAssertEqual(counts, [1])
        XCTAssertNotNil(activationError)
        XCTAssertEqual((activationError as NSError?)?.domain, "UISceneErrorDomain")
        XCTAssertEqual(try Data(contentsOf: queueFile), originalQueue)
        let client = try XCTUnwrap(runtimes.first?.feedback?.client)
        let status = await client.status()
        XCTAssertEqual(status.queued, 2); XCTAssertEqual(status.heldForEnrollment, 1)
        XCTAssertTrue(client.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertEqual(client.enrollmentSignal.enrollmentRef, try enrollment.load(scope: config.storageScope).enrollmentRef)
    }

    func testRootReplacementReusesAppOwnedRuntimeAndFeedback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = try Configuration(gameID: "scene-fixture")
        let enrollment = SceneEnrollment(), network = SceneHTTP(), source = AnnexTelemetry()
        var runtimes: [WeakSceneObject<CompanionRuntime>] = []
        var clients: [WeakSceneObject<Client>] = []
        var bridges: [WeakSceneObject<CompanionTelemetry>] = []
        var transports: [SceneTransport] = []
        var registrationTasks: [Task<Void, Never>] = []
        var activePumps = 0, peakPumps = 0, pumpStarts = 0
        CompanionSceneTestSupport.feedbackPumpChanged = { started in
            activePumps += started ? 1 : -1
            if started { pumpStarts += 1 }
            peakPumps = max(peakPumps, activePumps)
        }
        CompanionSceneTestSupport.makeFeedback = {
            let client = try! Client(configuration: config, transport: network, enrollmentStore: enrollment,
                                     feedbackStore: FileFeedbackStore(directory: directory))
            clients.append(WeakSceneObject(client))
            return CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: false)
        }
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "scene.invalid", port: 443), verifiedHostID: Array(repeating: "ab", count: 16).joined(separator: ":"),
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        CompanionSceneTestSupport.didCreateRuntime = { runtime in
            runtimes.append(WeakSceneObject(runtime))
            if let bridge = runtime.appTelemetry { bridges.append(WeakSceneObject(bridge)) }
            let transport = SceneTransport(); transports.append(transport)
            let service = runtime.service
            registrationTasks.append(Task { await service.register(.init(host: host, alias: "Synthetic desktop", transport: transport)) })
        }
        let isolated = ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing")
        // Normal CI uses a synthetic app owner in its own window. The isolated scene launch
        // additionally exercises the actual ClubhouseGoApp State owner and its first window.
        var owner: CompanionStateLifetime<CompanionRuntime>?
        let window: UIWindow
        if isolated {
            CompanionSceneTestSupport.ready = true
            try await wait { CompanionSceneTestSupport.runtimeLifetime != nil && runtimes.count == 1 }
            owner = CompanionSceneTestSupport.runtimeLifetime
            window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        } else {
            owner = CompanionStateLifetime { CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false) }
            XCTAssertTrue(clients.isEmpty, "A lifetime holder must not eagerly create feedback")
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: CompanionAppRoot(runtimeLifetime: try XCTUnwrap(owner)).environment(\.scenePhase, .active))
            window.makeKeyAndVisible()
        }
        defer {
            window.rootViewController = nil
            for runtime in runtimes { runtime.value?.appTelemetry?.stop(); runtime.value?.service.remove(hostID: host.hostID); runtime.value?.store.stop() }
            CompanionSceneTestSupport.makeFeedback = nil
            CompanionSceneTestSupport.didCreateRuntime = nil
            CompanionSceneTestSupport.feedbackPumpChanged = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try await wait { runtimes.count == 1 && activePumps == 1 }
        for task in registrationTasks { await task.value }
        let first = try XCTUnwrap(runtimes.first?.value)
        let preview = CompanionPreviewService()
        var events = preview.events().makeAsyncIterator()
        let initial = await events.next()
        first.store.apply(try XCTUnwrap(initial))
        let target = try XCTUnwrap(first.store.hosts.first?.projects.first?.agents.first?.id)
        first.store.drafts[target] = "Synthetic lifetime draft 👩🏽‍💻"
        first.store.selection = target
        let presenter = first.feedbackPresenter
        var setPhase: ((ScenePhase) -> Void)?
        for cycle in 1...2 {
            let lifetime = try XCTUnwrap(owner)
            let controller = UIHostingController(rootView: CompanionAppRoot(runtimeLifetime: lifetime).environment(\.scenePhase, .active))
            window.rootViewController = controller
            setPhase = { [weak controller] phase in controller?.rootView = CompanionAppRoot(runtimeLifetime: lifetime).environment(\.scenePhase, phase) }
            window.makeKeyAndVisible()
            try await wait { pumpStarts >= cycle + 1 && activePumps == 1 }
            for task in registrationTasks { await task.value }
            XCTAssertEqual(runtimes.count, 1); XCTAssertEqual(clients.count, 1); XCTAssertEqual(bridges.count, 1)
            XCTAssertTrue(runtimes[0].value === first)
            XCTAssertEqual(clients.filter { $0.value != nil }.count, 1)
            XCTAssertEqual(bridges.filter { $0.value != nil }.count, 1)
            let telemetry = try XCTUnwrap(first.appTelemetry?.telemetry)
            let beforeLogs = telemetry.stats().ringLogs
            source.record(.foreground)
            XCTAssertEqual(telemetry.stats().ringLogs, beforeLogs + 1, "One source record must have one bridge observer")
            XCTAssertTrue(first.feedbackPresenter === presenter)
            XCTAssertEqual(first.store.drafts[target], "Synthetic lifetime draft 👩🏽‍💻")
            // This synthetic desktop is not in the pairing registry. The root intentionally
            // prunes its placeholder selection, while the process-owned draft remains.
            XCTAssertNil(first.store.selection)
            let connectionCounts = await transports.asyncCounts()
            XCTAssertEqual(connectionCounts, [1])
            // Exercise the real root/presenter notification path, not the shake fixture.
            NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
            func promptCount() -> Int {
                window.windowScene?.windows.filter { !$0.isHidden && String(describing: type(of: $0)).contains("PassthroughWindow") }.count ?? 0
            }
            try await wait { promptCount() > 0 }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(promptCount(), 1, "A screenshot after root replacement must produce exactly one prompt")
            print("CLIENT_OWNER_SCREENSHOT cycle=\(cycle) prompts=\(promptCount()) runtimes=\(runtimes.count) clients=\(clients.count)")
            // The process-owned presenter resolves the replacement window at presentation time.
            presenter.sendFeedback(from: window)
            try await wait { window.rootViewController?.presentedViewController?.view.window === window }
            XCTAssertEqual(window.rootViewController?.presentedViewController?.view.window, window)
            window.rootViewController?.dismiss(animated: false)
            try await wait { window.rootViewController?.presentedViewController == nil }
            print("CLIENT_OWNER cycle=\(cycle) runtime=\(runtimes.count) client=\(clients.count) bridge=\(bridges.count) liveClient=\(clients.filter { $0.value != nil }.count) connects=\(await transports.asyncCounts()) activePumps=\(activePumps) peakPumps=\(peakPumps) pumpStarts=\(pumpStarts) draft=true unpairedSelectionCleared=\(first.store.selection == nil) presenter=true actualAppOwner=\(isolated)")
        }
        XCTAssertEqual(activePumps, 1)
        XCTAssertEqual(peakPumps, 1, "Replacement must cancel the old root pump before starting another")
        XCTAssertEqual(transports.count, 1)
        setPhase?(.background)
        try await wait { activePumps == 0 }
        await first.lifecycle.settle()
        let startsBeforeReturn = pumpStarts
        window.rootViewController = UIHostingController(rootView: CompanionAppRoot(runtimeLifetime: try XCTUnwrap(owner)).environment(\.scenePhase, .active))
        try await wait { pumpStarts == startsBeforeReturn + 1 && activePumps == 1 }
        await first.lifecycle.settle()
        let resumedConnections = await transports.asyncCounts()
        XCTAssertEqual(resumedConnections, [2], "A new active root must resume the backgrounded process runtime exactly once")
        XCTAssertEqual(peakPumps, 1)
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(clients.count, 1)
        print("CLIENT_OWNER phase=background-foreground activePumps=\(activePumps) peakPumps=\(peakPumps) starts=\(pumpStarts) connects=\(await transports.asyncCounts())")
        window.rootViewController = nil
        if !isolated { window.isHidden = true }
        try await wait { activePumps == 0 }
        if !isolated {
            addTeardownBlock { @MainActor in
                try await self.wait { runtimes.allSatisfy { $0.value == nil } }
            }
        }
    }

    func testReplacingRootOwnersReleasesEveryPreviousRuntime() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let config = try Configuration(gameID: "scene-fixture")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let network = SceneHTTP(), enrollment = SceneEnrollment(), source = AnnexTelemetry()
        CompanionSceneTestSupport.makeFeedback = {
            let client = try! Client(configuration: config, transport: network, enrollmentStore: enrollment,
                                     feedbackStore: FileFeedbackStore(directory: directory))
            return CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: false)
        }
        var runtimes: [WeakSceneObject<CompanionRuntime>] = []
        var presenters: [WeakSceneObject<CompanionFeedbackPresenter>] = []
        var clients: [WeakSceneObject<Client>] = []
        var bridges: [WeakSceneObject<CompanionTelemetry>] = []
        defer {
            window.rootViewController = nil; window.isHidden = true
            CompanionSceneTestSupport.makeFeedback = nil
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<5 {
            let lifetime = CompanionStateLifetime { CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false) }
            let runtime = lifetime.value
            runtimes.append(WeakSceneObject(runtime))
            presenters.append(WeakSceneObject(runtime.feedbackPresenter))
            clients.append(WeakSceneObject(try XCTUnwrap(runtime.feedback?.client)))
            bridges.append(WeakSceneObject(try XCTUnwrap(runtime.appTelemetry)))
            window.rootViewController = UIHostingController(rootView: CompanionAppRoot(runtimeLifetime: lifetime).environment(\.scenePhase, .active))
            window.makeKeyAndVisible()
            try await wait { runtimes.last?.value?.restoredHostIDs != nil }
            try await wait("Previous runtimes must deallocate") { runtimes.dropLast().allSatisfy { $0.value == nil } }
            try await wait("Previous feedback presenters must deallocate") { presenters.dropLast().allSatisfy { $0.value == nil } }
            try await wait("Previous feedback clients and telemetry bridges must deallocate") {
                clients.dropLast().allSatisfy { $0.value == nil } && bridges.dropLast().allSatisfy { $0.value == nil }
            }
        }
        window.rootViewController = nil
        window.isHidden = true
        try await wait("All runtimes must deallocate after unmounting") { runtimes.allSatisfy { $0.value == nil } }
        try await wait("All feedback presenters must deallocate after unmounting") { presenters.allSatisfy { $0.value == nil } }
        try await wait("All feedback clients and telemetry bridges must deallocate after unmounting") {
            clients.allSatisfy { $0.value == nil } && bridges.allSatisfy { $0.value == nil }
        }
    }

    func testRuntimeReleaseStopsAnActiveTransportLoop() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "teardown.invalid", port: 443),
                                       verifiedHostID: Array(repeating: "cd", count: 16).joined(separator: ":"),
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "cd", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "qa-only"), for: host.hostID)
        let clock = ClubhouseTransport.AnnexManualClock(), io = SceneOfflineIO()
        var transport: AnnexTransport? = AnnexTransport(host: host, credentials: credentials, io: io, clock: clock.clock)
        weak var previousTransport = transport
        var owner: CompanionStateLifetime<CompanionRuntime>? = CompanionStateLifetime {
            CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false)
        }
        weak var previousRuntime = try XCTUnwrap(owner).value
        window.rootViewController = UIHostingController(rootView: CompanionAppRoot(runtimeLifetime: try XCTUnwrap(owner)).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        try await wait { previousRuntime?.restoredHostIDs != nil }
        await previousRuntime?.service.register(.init(host: host, alias: "QA desktop", transport: try XCTUnwrap(transport)))
        try await wait { clock.sleeperCount > 0 }
        transport = nil
        window.rootViewController = nil
        window.isHidden = true
        owner = nil
        try await wait { previousRuntime == nil }
        await CompanionIconStore.shared.remove(host: host.hostID)
        try await Task.sleep(for: .milliseconds(200))
        let pendingBeforeAdvance = clock.sleeperCount
        let requestsBeforeAdvance = await io.count
        clock.advance(by: .seconds(60))
        try await Task.sleep(for: .milliseconds(200))
        let requestsAfterAdvance = await io.count
        print("QA_RUNTIME_TEARDOWN runtimeReleased=\(previousRuntime == nil) transportAlive=\(previousTransport != nil) sleepers=\(pendingBeforeAdvance) requestsBefore=\(requestsBeforeAdvance) requestsAfter=\(requestsAfterAdvance)")
        XCTAssertEqual(pendingBeforeAdvance, 0, "Destroying the runtime must cancel its transport retry loop")
        XCTAssertEqual(requestsAfterAdvance, requestsBeforeAdvance, "An old runtime must not continue network retries")
        XCTAssertNil(previousTransport, "The active transport must not retain itself after its owner ends")
        await previousTransport?.disconnect()
    }

    func testColdRootPhasesRestoreOneConnection() async throws {
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "scene.invalid", port: 443), verifiedHostID: Array(repeating: "ab", count: 16).joined(separator: ":"),
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (initialPhase, preSuspended) in [(ScenePhase.active, false), (.inactive, false), (.background, false), (.active, true)] {
            let transport = SceneTransport()
            var enteredRestore = false, releaseRestore = false, restoreCalls = 0
            CompanionSceneTestSupport.restoreRegistrations = {
                restoreCalls += 1; enteredRestore = true
                while !releaseRestore { try await Task.sleep(for: .milliseconds(5)) }
                return [.init(host: host, alias: "Synthetic restored desktop", transport: transport)]
            }
            let owner = CompanionStateLifetime { CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false) }
            let runtime = owner.value
            if preSuspended { runtime.lifecycle.update(.background); await runtime.lifecycle.settle() }
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView: CompanionAppRoot(runtimeLifetime: owner).environment(\.scenePhase, initialPhase))
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer {
                window.rootViewController = nil; window.isHidden = true
                runtime.store.stop(); runtime.service.remove(hostID: host.hostID)
                CompanionSceneTestSupport.restoreRegistrations = nil
            }
            try await wait { enteredRestore }
            // Hold restoration until the root has applied its initial phase. No transport
            // exists in LiveService yet; an early resume cannot race a restore into two connects.
            await runtime.lifecycle.settle()
            releaseRestore = true
            try await wait { !runtime.isRestoring }
            await runtime.lifecycle.settle()
            let beforeActive = await transport.connectCount
            if initialPhase == .background { XCTAssertEqual(beforeActive, 0) }
            controller.rootView = CompanionAppRoot(runtimeLifetime: owner).environment(\.scenePhase, .active)
            try await Task.sleep(for: .milliseconds(100))
            await runtime.lifecycle.settle()
            for _ in 0..<100 {
                if await transport.connectCount > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let afterActive = await transport.connectCount
            XCTAssertEqual(afterActive, 1, "Cold launch must connect exactly once")
            XCTAssertEqual(restoreCalls, 1)
            XCTAssertEqual(runtime.restoredHostIDs, Set([host.hostID]))
            print("CLIENT_COLD phase=\(initialPhase) preSuspended=\(preSuspended) restoreCalls=\(restoreCalls) beforeActive=\(beforeActive) afterActive=\(afterActive)")
        }
    }

    func testOneClientKeepsQueueAndEnrollmentCoherentAcrossCallers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try Configuration(gameID: "scene-fixture")
        let store = try FileFeedbackStore(directory: directory)
        let enrollment = SceneEnrollment(), network = SceneHTTP()
        let a = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: store)
        let b = a
        let first = try ReviewedFeedback(configuration: config, notes: "Synthetic A")
        let second = try ReviewedFeedback(configuration: config, notes: "Synthetic B")
        try await a.enqueue(first, enrollmentRef: "scene-enrollment")
        try await b.enqueue(second, enrollmentRef: "scene-enrollment")
        XCTAssertEqual(try store.load(scope: config.storageScope).map(\.feedback.id), [first.id, second.id])
        let aStatus = await a.status(), bStatus = await b.status()
        XCTAssertEqual(aStatus.queued, 2); XCTAssertEqual(bStatus.queued, 2)
        await a.resume()
        try await a.flush(); try await b.flush()
        let ids = await network.reportIDs
        XCTAssertEqual(ids, [first.id.uuidString.lowercased(), second.id.uuidString.lowercased()])
        XCTAssertTrue(try store.load(scope: config.storageScope).isEmpty)
        _ = try await a.disconnect()
        XCTAssertFalse(a.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertFalse(b.enrollmentSignal.isEnrolled(at: Date()))
        XCTAssertFalse(try enrollment.load(scope: config.storageScope).enrolled)
    }

    func testUpgradePersistence() async throws {
        let phase = ProcessInfo.processInfo.environment["CLUBHOUSE_SCENE_UPGRADE_PHASE"] ?? "roundtrip"
        let suite = "scene-upgrade-" + UUID().uuidString
        let defaults = phase == "roundtrip" ? try XCTUnwrap(UserDefaults(suiteName: suite)) : .standard
        let root = phase == "roundtrip" ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            : try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        defer {
            if phase == "roundtrip" { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        }
        let directory = root.appendingPathComponent("Framebriar")
        let expected = root.appendingPathComponent("scene-upgrade-expected.json")
        let config = try Configuration(gameID: "scene-fixture")
        let store = try FileFeedbackStore(directory: directory)
        let target = CompanionTarget(hostID: "fixture-host", projectID: "fixture-project", agentID: "fixture-agent")
        let text = "Saved before upgrade: café 👩🏽‍💻 日本語\nsecond line 🏠"
        let drafts = CompanionLocalDrafts(defaults: defaults)
        if phase != "verify" {
            let first = try ReviewedFeedback(configuration: config, notes: "Synthetic queued before upgrade")
            let held = try ReviewedFeedback(configuration: config, notes: "Synthetic held before upgrade")
            try store.save([
                QueuedFeedback(feedback: first, attempts: 3, nextAttemptAt: Date(timeIntervalSince1970: 4_000_000_000), enrollmentRef: "scene-enrollment"),
                QueuedFeedback(feedback: held, attempts: 2, blocked: true, enrollmentRef: "previous-enrollment", heldForEnrollment: true)
            ], scope: config.storageScope)
            drafts.save([target: text])
            defaults.set(true, forKey: CompanionInstallReset.markerKey)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            try Data(contentsOf: file).write(to: expected)
            print("UPGRADE_SEEDED reports=2 held=1 drafts=1 sessions=\(UIApplication.shared.openSessions.count)")
        }
        if phase != "seed" {
            var deletedServices: [String] = []
            XCTAssertFalse(CompanionInstallReset.clearLeftoversIfFreshInstall(defaults: defaults, domain: phase == "roundtrip" ? suite : Bundle.main.bundleIdentifier, delete: { deletedServices.append($0) }))
            XCTAssertTrue(deletedServices.isEmpty)
            let client = try Client(configuration: config, transport: SceneHTTP(), enrollmentStore: SceneEnrollment(), feedbackStore: store)
            let status = await client.status()
            XCTAssertEqual(status.queued, 2); XCTAssertEqual(status.heldForEnrollment, 1)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: expected))
            let restored = CompanionStore(service: CompanionPreviewService(), draftPersistence: drafts)
            XCTAssertEqual(restored.drafts[target], text)
            let items = try store.load(scope: config.storageScope)
            XCTAssertEqual(items.map(\.enrollmentRef), ["scene-enrollment", "previous-enrollment"])
            XCTAssertEqual(items.map(\.attempts), [3, 2])
            print("UPGRADE_VERIFIED byteIdentical=true reports=2 held=1 ids=\(items.map { $0.feedback.id.uuidString }) unicodeDraft=true sessions=\(UIApplication.shared.openSessions.count) connected=\(UIApplication.shared.connectedScenes.count)")
        }
    }

    private func wait(_ message: String = "Scene fixture did not reach expected state", until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
    }
}

nonisolated private final class SceneEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord(refreshToken: String(repeating: "r", count: 43), expiresAt: SceneFixtureValues.expiry, enrolled: true, notice: .connected, enrollmentRef: "scene-enrollment")
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
private actor SceneHTTP: HTTPTransport {
    private(set) var reportIDs: [String] = []
    func send(_ request: URLRequest) throws -> HTTPResponse {
        let path = request.url!.path
        let object: [String: Any]
        if path.hasSuffix("/reports") {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            reportIDs.append(body["id"] as! String)
            object = ["id": body["id"]!, "status": "ready", "gameId": "scene-fixture"]
        } else if path.hasSuffix("access/refresh") {
            object = ["v": 1, "scopeVersion": 2, "gameId": "scene-fixture", "token": String(repeating: "b", count: 43), "refreshToken": String(repeating: "r", count: 43), "expiresAt": Date().addingTimeInterval(3600).ISO8601Format(), "refreshExpiresAt": SceneFixtureValues.expiry.ISO8601Format()]
        } else if path.hasSuffix("access/disconnect") { object = ["v": 1, "disconnected": true] }
        else if path.contains("/otlp/") { object = [:] }
        else { throw FramebriarError.network }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}
private actor SceneOfflineIO: AnnexIO {
    private(set) var count = 0
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        count += 1
        throw URLError(.notConnectedToInternet)
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket {
        throw URLError(.notConnectedToInternet)
    }
}

private actor SceneTransport: AnnexTransporting {
    private(set) var connectCount = 0
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> { AsyncThrowingStream { _ in } }
    func connect() { connectCount += 1 }
    func disconnect() {}
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON { throw AnnexTransportError.disconnected }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt { throw AnnexTransportError.disconnected }
}
private extension Array where Element == SceneTransport {
    func asyncCounts() async -> [Int] {
        var counts: [Int] = []
        for transport in self { counts.append(await transport.connectCount) }
        return counts
    }
}

nonisolated private enum SceneFixtureValues { static let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86400) }

@MainActor private final class WeakSceneObject<Value: AnyObject> {
    nonisolated deinit {}
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}
