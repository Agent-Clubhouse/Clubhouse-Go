import Testing
import Foundation
@testable import ClubhouseGo
import ClubhouseTransport
import Framebriar
import FramebriarUI
import SwiftUI

/// Framebriar telemetry with mocks only: nothing reaches the live service.
@MainActor @Suite(.serialized) struct CompanionTelemetryTests {
    private let config = try! Configuration(gameID: "phone-ui-fixture", buildSHA: "6c32b12")

    private func compose(_ network: TelemetryMockTransport, source: AnnexTelemetry = AnnexTelemetry(), enrollment: TelemetryMemoryEnrollment = TelemetryMemoryEnrollment(), now: @escaping @Sendable () -> Date = { Date() }) throws -> (Client, FeedbackModel, CompanionTelemetry, AnnexTelemetry) {
        let client = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: TelemetryMemoryQueue(), now: now)
        let parts = CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: false)
        return (client, parts.model, try #require(parts.telemetry), source)
    }

    @Test func oneSessionIDForFeedbackTelemetryAndIncidents() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        let id = source.instanceID.uuidString.lowercased()
        #expect(FramebriarSession.id == id)
        #expect(bridge.telemetry.sessionID == id)
        #expect(model.telemetry === bridge.telemetry)
        #expect(try ReviewedFeedback(configuration: config, notes: "fixture").sessionID == id)
        #expect(CompanionFeedback.snapshotIncident(telemetry: source)?.phoneInstanceId == id)
    }

    @Test func nothingIsRecordedOrSentBeforeEnrollmentOrAfterDisconnect() async throws {
        let network = TelemetryMockTransport()
        let (client, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        bridge.start(metricKit: false)
        await model.setActive(true)
        // Not enrolled: the diagnostics aren't even captured, and the emitter is a no-op.
        #expect(!source.isEnabled && !bridge.telemetry.isEnabled)
        source.record(.pairing)
        #expect(source.snapshot().records.isEmpty)
        #expect(await bridge.telemetry.flush() == false)
        #expect(await network.telemetryPaths.isEmpty)

        await model.connect(String(repeating: "i", count: 43))
        #expect(source.isEnabled && bridge.telemetry.isEnabled)
        let pairing = source.begin(.pairing)
        pairing.identifier(.peerInstanceID, UUID()); pairing.event(.found); pairing.end()
        await source.measureRoutine(.ping, slowMs: 1000) {}
        bridge.tick(force: true)
        #expect(await bridge.telemetry.flush())
        let traces = try #require(await network.bodies(for: "traces").first)
        let span = try #require(spans(traces).first { $0["name"] as? String == "app.flow" })
        #expect(span["spanId"] as? String == source.snapshot().records.first?.id)
        #expect((span["events"] as? [[String: Any]])?.first?["name"] as? String == "found")
        #expect(attributes(span)["app.flow.name"] as? String == "pair")
        #expect(attributes(span)["app.telemetry.schema_version"] as? String == "1")
        #expect(attributes(span)["app.platform"] as? String == "ios")
        #expect(attributes(span)["app.build.sha"] as? String == "6c32b12")
        #expect(!spans(traces).contains { $0["name"] as? String == "ping" }) // counted, not a span
        let logs = try #require(await network.bodies(for: "logs").first)
        #expect(logBodies(logs).contains("app.session.start") && logBodies(logs).contains("app.performance.summary"))

        // Disconnect: capture stops, the buffer is forgotten and nothing more is sent.
        await model.disconnect()
        try await waitUntil { !source.isEnabled }
        #expect(!bridge.telemetry.isEnabled && source.snapshot().records.isEmpty)
        let sent = await network.telemetryPaths.count
        source.record(.reconnect)
        bridge.telemetry.log(.info, "app.lifecycle")
        #expect(await bridge.telemetry.flush() == false)
        #expect(await network.telemetryPaths.count == sent)
        #expect(await client.telemetryToken() == nil)
    }

    @Test func submittedFeedbackEmitsAMarkerWithTheReportID() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, _) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        let reviewed = try ReviewedFeedback(configuration: config, notes: "Reviewed fixture note")
        #expect(await model.submit(reviewed, includeDiagnostics: false))
        try await waitUntil { await network.bodies(for: "logs").contains { logBodies($0).contains("feedback.submitted") } }
        let marker = try #require(await network.bodies(for: "logs").flatMap(logRecords).first { ($0["body"] as? [String: Any])?["stringValue"] as? String == "feedback.submitted" })
        #expect(attributes(marker)["feedback.report.id"] as? String == reviewed.id.uuidString.lowercased())
        // The notes are the report's, never telemetry's.
        for body in await network.bodies(for: "logs") + network.bodies(for: "traces") {
            #expect(!String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains("Reviewed fixture note"))
        }
    }

    /// Reproduces the old eager State(initialValue: CompanionRuntime()) side effect. The
    /// discarded runtime replaces the only sink with telemetry backed by a forever-paused client.
    @Test func discardedEagerRuntimeStealsSinkFromForegroundedFeedbackModel() async throws {
        let network = TelemetryMockTransport(), enrollment = TelemetryMemoryEnrollment()
        let source = AnnexTelemetry()
        let retainedClient = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: TelemetryMemoryQueue())
        let retained = try Telemetry(client: retainedClient, configuration: config, transport: network, observeAppLifecycle: false)
        let model = FeedbackModel(client: retainedClient, telemetry: retained)
        defer { retained.dispose(); source.setRecordSink(nil) }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        source.setEnrolledCapture(true)
        source.setRecordSink { CompanionTelemetryForwarder.forward(AnnexAppTelemetry.signals(for: $0), to: retained) }
        let discardedClient = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: TelemetryMemoryQueue())
        let discarded = try Telemetry(client: discardedClient, configuration: config, transport: network, observeAppLifecycle: false)
        defer { discarded.dispose() }
        source.setRecordSink { CompanionTelemetryForwarder.forward(AnnexAppTelemetry.signals(for: $0), to: discarded) }
        await model.setActive(false)
        await model.setActive(true)
        recordRetry(on: source)
        source.record(.foreground)
        #expect(source.snapshot().records.count == 4)
        #expect(await retained.flush())
        #expect(await discarded.flush() == false) // no token: new Client is paused
        #expect(await network.bodies(for: "traces").isEmpty)
        let report = try ReviewedFeedback(configuration: config, notes: "fixture")
        #expect(await model.submit(report))
        try await waitUntil { await network.bodies(for: "logs").flatMap(logBodies).contains("feedback.submitted") }
        #expect(!(await network.bodies(for: "logs").flatMap(logBodies)).contains("app.lifecycle"))
        #expect(await network.bodies(for: "traces").isEmpty)
    }

    @Test func lazyStateLifetimeKeepsRetryAndForegroundRecordsFlowingAfterResume() async throws {
        let network = TelemetryMockTransport(), enrollment = TelemetryMemoryEnrollment()
        let source = AnnexTelemetry()
        var constructions = 0
        func make() -> (Client, FeedbackModel, CompanionTelemetry, AnnexTelemetry) {
            constructions += 1
            return try! compose(network, source: source, enrollment: enrollment)
        }
        let state = CompanionStateLifetime { make() }
        let (_, model, bridge, _) = state.value
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        _ = CompanionStateLifetime { make() } // SwiftUI evaluates and discards an initial value
        #expect(constructions == 1)
        #expect(state.value.2 === bridge)
        for _ in 0..<20 {
            _ = CompanionStateLifetime { make() }
            await model.setActive(false)
            source.record(.background)
            await model.setActive(true)
            source.record(.foreground)
            recordRetry(on: source)
            #expect(await bridge.telemetry.flush())
        }
        #expect(constructions == 1)
        let actual = await network.bodies(for: "traces").flatMap(spans)
        #expect(actual.count == 60)
        #expect(actual.contains { attributes($0)["annex.operation"] as? String == "connection" && attributes($0)["error.type"] as? String == "connection" })
        #expect(actual.contains { $0["name"] as? String == "websocket" && attributes($0)["error.type"] as? String == "offline" })
        #expect(actual.contains { $0["name"] as? String == "backoff" && attributes($0)["annex.backoffMs"] as? Double == 30_000 })
        let logs = await network.bodies(for: "logs").flatMap(logRecords)
        #expect(logs.contains { attributes($0)["app.lifecycle.state"] as? String == "foreground" })
        #expect(logs.filter { ($0["body"] as? [String: Any])?["stringValue"] as? String == "app.error" }.count == 40)
    }

    @Test func periodicFlushExcludesSentEntriesFromExcerptButKeepsTheirSessionAndTrace() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        recordRetry(on: source)
        #expect(await bridge.telemetry.flush())
        let first = await network.bodies(for: "traces")
        let incident = try #require(CompanionFeedback.snapshotIncident(telemetry: source))
        let report = try ReviewedFeedback(configuration: config, notes: "fixture", incident: incident)
        #expect(await model.submit(report))
        try await waitUntil { await network.bodies(for: "logs").flatMap(logBodies).contains("feedback.submitted") }
        #expect(await network.bodies(for: "traces").count == first.count)
        #expect(Set(first.flatMap(spans).compactMap { $0["traceId"] as? String }).isSuperset(of: incident.traces.map(\.traceId)))
        let resources = first.compactMap { ($0["resourceSpans"] as? [[String: Any]])?.first?["resource"] as? [String: Any] }
        #expect(resources.allSatisfy { attributes($0)["session.id"] as? String == source.instanceID.uuidString.lowercased() })
    }

    @Test func feedbackCaptureCheckpointsOnceWithoutRefreshingReviewedDraft() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        source.recordPerformance(.scrollGeometry, durationMs: 2, messageCount: 128)
        let draft = model.openDraft(reportDiagnostics: .on)
        #expect(source.drainSummaries().isEmpty)
        try await waitUntil {
            await network.bodies(for: "logs").flatMap(logBodies).contains("app.performance.summary")
        }
        let summaries = await network.bodies(for: "logs").flatMap(logRecords).filter {
            ($0["body"] as? [String: Any])?["stringValue"] as? String == "app.performance.summary"
        }
        #expect(summaries.count == 1, "Both capture providers must drain the interval only once")
        #expect(attributes(summaries[0])["count"] as? String == "1")
        #expect(attributes(summaries[0])["windowEndUnixMs"] as? Double != nil)
        // A successful checkpoint flush is ordinary telemetry. Send must not re-tag/re-send it.
        let markerID = UUID()
        #expect(await bridge.telemetry.feedbackSubmitted(reportID: markerID, includeDiagnostics: true))
        let afterMarker = await network.bodies(for: "logs").flatMap(logRecords)
        let emittedSummaries = afterMarker.filter {
            ($0["body"] as? [String: Any])?["stringValue"] as? String == "app.performance.summary"
        }
        #expect(emittedSummaries.count == 1)
        #expect(attributes(emittedSummaries[0])["feedback.report.id"] == nil)
        #expect(afterMarker.contains { attributes($0)["feedback.report.id"] as? String == markerID.uuidString.lowercased() })
        let frozen = try draft.report(configuration: config, notes: "fixture", screenshotPNG: nil, includeDiagnostics: true)
        source.recordPerformance(.scrollGeometry, durationMs: 3, messageCount: 129)
        let reviewed = try draft.report(configuration: config, notes: "fixture", screenshotPNG: nil, includeDiagnostics: true)
        #expect(reviewed == frozen && reviewed.incident == draft.incident)
        #expect(reviewed.diagnostics == draft.capturedDiagnostics)
        #expect(bridge.tick(force: true))
        #expect(!bridge.tick(force: true), "Empty checkpoints cannot duplicate samples")
        #expect(await bridge.telemetry.flush())
        let all = await network.bodies(for: "logs").flatMap(logRecords).filter {
            ($0["body"] as? [String: Any])?["stringValue"] as? String == "app.performance.summary"
        }
        #expect(all.count == 2 && all.allSatisfy { attributes($0)["count"] as? String == "1" })
        #expect(all.reduce(0.0) { $0 + (attributes($1)["durationMs"] as? Double ?? 0) } == 5)
    }

    @Test func lifecycleCheckpointPrecedesSDKBackgroundAndTerminationFlush() async throws {
        let network = TelemetryMockTransport(), source = AnnexTelemetry()
        let client = try Client(configuration: config, transport: network, enrollmentStore: TelemetryMemoryEnrollment(), feedbackStore: TelemetryMemoryQueue())
        let parts = CompanionFeedback.compose(client: client, source: source, telemetryTransport: network, observeAppLifecycle: true)
        let bridge = try #require(parts.telemetry)
        defer { bridge.stop() }
        await parts.model.setActive(true)
        await parts.model.connect(String(repeating: "i", count: 43))
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            source.recordPerformance(.readingPreference, durationMs: 4, messageCount: 140)
            NotificationCenter.default.post(name: name, object: nil)
            #expect(source.drainSummaries().isEmpty, "Checkpoint must be synchronous, with no lifecycle await")
        }
        try await waitUntil {
            await network.bodies(for: "logs").flatMap(logRecords).filter {
                ($0["body"] as? [String: Any])?["stringValue"] as? String == "app.performance.summary"
            }.count == 2
        }
        let records = await network.bodies(for: "logs").flatMap(logRecords).filter {
            ($0["body"] as? [String: Any])?["stringValue"] as? String == "app.performance.summary"
        }
        let counts = records.compactMap { record -> Int? in
            (attributes(record)["count"] as? String).flatMap(Int.init)
        }
        #expect(counts == [1, 1])
    }

    private func recordRetry(on source: AnnexTelemetry) {
        let connection = source.begin(.connection)
        connection.identifier(.connectionAttemptID, UUID()); connection.fail(.connection); connection.end()
        let socket = source.begin(.websocket)
        socket.fail(.offline); socket.end()
        let backoff = source.begin(.backoff)
        backoff.number(.attempt, 4); backoff.number(.backoffMs, 30_000); backoff.end()
    }

    @Test func diagnosticsReleaseGateKeepsFieldOutOfOutgoingReports() async throws {
        #expect(!CompanionFeedback.reportDiagnosticsSendingEnabled)
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        recordRetry(on: source)
        let local = AnnexFeedbackDiagnostics.capture(from: source)
        #expect(local.state == .attached && local.lines == 3)
        let report = try ReviewedFeedback(configuration: config, notes: "fixture")
        #expect(await model.submit(report))
        await model.tick()
        let bodies = await network.reportBodies
        #expect(bodies.count == 1)
        #expect(bodies.allSatisfy { $0["diagnostics"] == nil })
    }

    @Test func olderBridgeCleanupPreservesNewerBridgeAndDebugObserver() async throws {
        let network = TelemetryMockTransport(), source = AnnexTelemetry(), enrollment = TelemetryMemoryEnrollment()
        let (_, model, older, _) = try compose(network, source: source, enrollment: enrollment)
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        let (_, newModel, newer, _) = try compose(network, source: source, enrollment: enrollment)
        defer { newer.stop() }
        await newModel.setActive(true)
        let debug = TelemetryRecordCounter()
        let token = source.observeRecords { _ in debug.increment() }
        defer { source.removeRecordObserver(token) }
        older.stop()
        #expect(source.isEnabled)
        recordRetry(on: source)
        source.record(.foreground)
        #expect(await newer.telemetry.flush())
        #expect(await network.bodies(for: "traces").flatMap(spans).count == 3)
        #expect(debug.count == 4)
    }

    @Test func restoredEnrollmentCanResolvePendingTriggerStatusWithoutNetwork() async throws {
        let network = TelemetryMockTransport(), enrollment = TelemetryMemoryEnrollment()
        let (_, original, bridge, _) = try compose(network, enrollment: enrollment)
        defer { bridge.stop() }
        await original.setActive(true)
        await original.connect(String(repeating: "i", count: 43))
        let client = try Client(configuration: config, transport: network, enrollmentStore: enrollment, feedbackStore: TelemetryMemoryQueue())
        let cold = FeedbackModel(client: client)
        #expect(cold.status == nil)
        #expect(CompanionScreenshotFeedback.decide(enabled: true, configured: true, canSubmit: cold.status?.canSubmit,
            secureFieldActive: false, explainedThisSession: false, busy: false) == .waitForStatus)
        let requests = await network.requests.count
        await cold.update()
        #expect(cold.status?.canSubmit == true)
        #expect(await network.requests.count == requests)
    }

    @Test func incidentDoesNotReferenceLocalOnlyNavigationOrLifecycleSpans() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        source.record(.http)
        for operation in [AnnexDiagnosticOperation.navigation, .settings, .foreground, .background, .navigation, .settings, .appLaunch] {
            source.record(operation)
        }
        #expect(source.snapshot().records.count == 8)
        let incident = try #require(CompanionFeedback.snapshotIncident(telemetry: source))
        #expect(incident.traces.count == 1)
        #expect(await bridge.telemetry.flush())
        let exported = Set(await network.bodies(for: "traces").flatMap(spans).compactMap { $0["traceId"] as? String })
        #expect(incident.traces.allSatisfy { exported.contains($0.traceId) })
    }

    @Test func newlyQueuedReportWakesDeliveryWithoutWaitingForThePeriodicTick() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, _) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        let first = try ReviewedFeedback(configuration: config, notes: "fixture")
        #expect(await model.submit(first))
        #expect(await network.reportBodies.isEmpty) // SDK submit flushes telemetry, not reports
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: false)
        #expect(await network.reportBodies.count == 1)
        await model.setActive(false)
        let next = try ReviewedFeedback(configuration: config, notes: "fixture")
        #expect(await model.submit(next))
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: true)
        #expect(await network.reportBodies.count == 1)
        #expect(model.status?.queued == 1)
        await model.setActive(true)
        await model.tick()
        #expect(await network.reportBodies.count == 2)
    }

    @Test func deliveryAttemptsAreImmediateAfterCommitRespectBackgroundAndKeepBackoffWithoutDuplicates() async throws {
        let clock = TelemetryFixtureClock()
        let network = TelemetryMockTransport(now: { clock.now })
        let (_, model, bridge, _) = try compose(network, now: { clock.now })
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        let first = try ReviewedFeedback(configuration: config, notes: "fixture", capturedAt: clock.now)
        #expect(await model.submit(first))
        let committedAt = clock.now
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: false)
        #expect(await network.reportAttemptTimes == [committedAt])
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: false)
        #expect(await network.reportAttemptTimes.count == 1)
        await model.setActive(false)
        let second = try ReviewedFeedback(configuration: config, notes: "fixture", capturedAt: clock.now)
        #expect(await model.submit(second))
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: true)
        clock.advance(270)
        #expect(await network.reportAttemptTimes.count == 1)
        await model.setActive(true)
        await model.tick()
        #expect(await network.reportAttemptTimes == [committedAt, clock.now])
        await model.tick()
        #expect(await network.reportAttemptTimes.count == 2)

        await network.setReportStatus(503)
        let third = try ReviewedFeedback(configuration: config, notes: "fixture", capturedAt: clock.now)
        #expect(await model.submit(third))
        let failedAt = clock.now
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: false)
        #expect(await network.reportAttemptTimes.last == failedAt)
        #expect(await network.reportAttemptTimes.count == 3)
        clock.advance(59)
        await model.tick()
        #expect(await network.reportAttemptTimes.count == 3)
        await network.setReportStatus(200)
        clock.advance(1)
        await model.tick()
        #expect(await network.reportAttemptTimes == [committedAt, committedAt.addingTimeInterval(270), failedAt, failedAt.addingTimeInterval(60)])
        await model.tick()
        let ids = await network.reportBodies.compactMap { $0["id"] as? String }
        #expect(ids == [first.id, second.id, third.id, third.id].map { $0.uuidString.lowercased() })
        #expect(model.status?.queued == 0)
    }

    @Test func outgoingReportCarriesBuildSessionAndOnlyExportableIncidentReferences() async throws {
        let network = TelemetryMockTransport()
        let (_, model, bridge, source) = try compose(network)
        defer { bridge.stop() }
        await model.setActive(true)
        await model.connect(String(repeating: "i", count: 43))
        let span = source.begin(.connection)
        let host = UUID(), connection = UUID(), attempt = UUID()
        span.identifier(.peerInstanceID, host); span.identifier(.connectionID, connection); span.identifier(.connectionAttemptID, attempt)
        span.fail(.timeout); span.end()
        let incident = try #require(CompanionFeedback.snapshotIncident(telemetry: source))
        let reviewed = try ReviewedFeedback(configuration: config, notes: "fixture", incident: incident)
        #expect(await model.submit(reviewed))
        await CompanionFeedback.deliverNewlyQueued(model: model, previous: 0, current: 1, isBackground: false)
        let body = try #require(await network.reportBodies.last)
        #expect(body["gameId"] as? String == "phone-ui-fixture")
        #expect(body["buildSha"] as? String == "6c32b12")
        #expect(body["sessionId"] as? String == source.instanceID.uuidString.lowercased())
        #expect(body["diagnostics"] == nil)
        let sentIncident = try #require(body["incident"] as? [String: Any])
        #expect(sentIncident["phoneInstanceId"] as? String == source.instanceID.uuidString.lowercased())
        #expect(sentIncident["hostInstanceIds"] as? [String] == [host.uuidString.lowercased()])
        #expect(sentIncident["connectionIds"] as? [String] == [connection.uuidString.lowercased()])
        #expect(sentIncident["windowEnd"] as? String == incident.capturedAt)
        #expect(await bridge.telemetry.flush())
        let exported = try #require(await network.bodies(for: "traces").flatMap(spans).first)
        #expect(exported["traceId"] as? String == incident.traces.first?.traceId)
        #expect(attributes(exported)["annex.connection.attempt.id"] as? String == attempt.uuidString.lowercased())
    }

    @Test func hostingViewRecreationDoesNotConstructAnotherRuntimeDependency() async throws {
        var made = 0
        func make() -> Int { made += 1; return made }
        let host = UIHostingController(rootView: TelemetryLifetimeProbe(make: make))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; originalKey?.makeKey() }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(made == 1)
        for _ in 0..<3 {
            host.rootView = TelemetryLifetimeProbe(make: make)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(made == 1)
    }

    @Test func settingsDiscloseTelemetryNextToEnrollment() {
        let text = CompanionFeedbackSettings.telemetryDisclosure
        #expect(text.contains("Enrolling in developer feedback also sends usage and diagnostic telemetry to the developer"))
        #expect(text.contains("Automated telemetry excludes prompts"))
        #expect(text.contains("Notes and images you choose to submit can contain private information"))
        #expect(text.contains("saved feedback stays on this device"))
    }

    @Test(arguments: [false, true])
    func scopedSnapshotIsDurableThroughPauseBackoffAndKeepsFailuresWithoutAnExcerptCopy(holdRefresh: Bool) async throws {
        // An offset catches wall-time mock expiries: the SDK rejects tokens over an hour ahead.
        let clock = TelemetryFixtureClock(now: Date().addingTimeInterval(-60))
        let network = TelemetryMockTransport(now: { clock.now })
        // This test advances both retry clocks. The ordinary compose helper deliberately exercises
        // Go's production factory, whose telemetry clock is wall time; advancing only Client's clock
        // leaves a paused marker's telemetry backoff pending in real time.
        let source = AnnexTelemetry()
        let client = try Client(configuration: config, transport: network, enrollmentStore: TelemetryMemoryEnrollment(),
                                feedbackStore: TelemetryMemoryQueue(), now: { clock.now })
        CompanionFeedback.adoptSession(of: source)
        let bridge = try CompanionTelemetry(client: client, configuration: config, source: source,
                                            transport: network, observeAppLifecycle: false, now: { clock.now })
        let model = FeedbackModel(client: client, telemetry: bridge.telemetry,
                                  incidentProvider: { CompanionFeedback.snapshotIncident(telemetry: source) },
                                  diagnosticsProvider: { CompanionFeedback.diagnosticsSnapshot(from: source) },
                                  reportDiagnostics: .off)
        defer { bridge.stop() }
        await model.setActive(true); await model.connect(String(repeating: "i", count: 43))
        recordRetry(on: source)
        #expect(model.reportDiagnostics == .off)
        #expect(model.openDraft().capturedDiagnostics == nil)
        let draft = model.openDraft(reportDiagnostics: .on)
        let frozen = try #require(draft.capturedDiagnostics)
        #expect(frozen.entries.count == 3)
        #expect(frozen.entries.contains { $0.attrs?["failure"] == .string("closed") })
        #expect(frozen.entries.contains { $0.attrs?["failure"] == .string("offline") })
        #expect(frozen.entries.contains { $0.attrs?["backoffMs"] == .number(30_000) })
        await model.setActive(false)
        let report = try await model.save(draft, notes: "Diagnostics test durable fixture", screenshotPNG: nil, includeDiagnostics: true)
        #expect(report.diagnostics == frozen)
        #expect(await model.deliver(report, includeDiagnostics: true) == .saved(.paused))
        #expect(await network.reportBodies.isEmpty)
        // Force the same busy-client interleaving as the unstructured marker's token refresh.
        // A slow access response must not be mistaken for a completed report pump pass.
        if holdRefresh { await network.holdNextRefresh() }
        await model.setActive(true); await network.setReportStatus(503)
        var refresh: Task<String?, Never>?
        if holdRefresh {
            refresh = Task { await client.telemetryToken() }
            try await waitUntil { await network.refreshIsHeld }
        }
        await model.tick(); await model.tick()
        if holdRefresh {
            #expect(await network.reportBodies.isEmpty)
            await network.releaseRefresh()
            _ = await refresh?.value
        }
        // tick may return while the marker owns access refresh. Model the foreground pump's
        // later passes until an attempt actually completes, without advancing the retry clock.
        try await waitUntil {
            await model.tick()
            return await network.reportBodies.count >= 1
        }
        await model.tick()
        #expect(await network.reportBodies.count == 1)
        #expect(model.status?.lastDeliveryResult == "server")
        clock.advance(59); await model.tick()
        #expect(await network.reportBodies.count == 1, "Foreground passes do not bypass the report backoff")
        clock.advance(2); await network.setReportStatus(200)
        try await waitUntil {
            await model.tick()
            return await network.reportBodies.count >= 2 && model.status?.queued == 0
        }
        let sent = await network.requests.filter { $0.url!.path.hasSuffix("/reports") }.compactMap(\.httpBody)
        #expect(sent.count == 2 && sent[0] == sent[1], "Retry sends the frozen body, not a new capture")
        #expect(model.status?.queued == 0)
        // deliver schedules this marker in a separate Task. flush() alone need not have seen it.
        try await waitUntil {
            _ = await bridge.telemetry.flush()
            return await network.bodies(for: "logs").flatMap(logRecords).contains {
                attributes($0)["feedback.report.id"] as? String == report.id.uuidString.lowercased()
            }
        }
        let records = await network.bodies(for: "logs").flatMap(logRecords) + network.bodies(for: "traces").flatMap(spans)
        let tagged = records.filter { attributes($0)["feedback.report.id"] as? String == report.id.uuidString.lowercased() }
        #expect(tagged.count == 1)
        #expect((tagged.first?["body"] as? [String: Any])?["stringValue"] as? String == "feedback.submitted")
    }

    @Test func boundedProviderMatchesTaggedFixtureAndHasAReasonWhenCaptureIsOff() throws {
        let off = CompanionFeedback.diagnosticsSnapshot(from: AnnexTelemetry())
        #expect(off.state == .none && off.reason == "empty")
        let source = AnnexTelemetry(); source.setEnrolledCapture(true)
        defer { source.setEnrolledCapture(false) }
        for _ in 0..<220 { recordRetry(on: source) }
        let started = ContinuousClock.now
        let result = CompanionFeedback.diagnosticsSnapshot(from: source)
        let duration = started.duration(to: .now)
        print("Feedback diagnostics snapshot: \(duration), \(result.lines) entries, \(result.dropped) dropped")
        try result.validate()
        let bundle = try #require(Bundle.allBundles.first { $0.bundleURL.lastPathComponent == "ClubhouseGoTests.xctest" })
        let url = try #require(bundle.url(forResource: "report-diagnostics-v1", withExtension: "json"))
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let contract = try #require(fixture["contract"] as? [String: Any]), limits = try #require(contract["limits"] as? [String: Int])
        #expect(result.lines == AnnexFeedbackDiagnostics.maximumEntries && result.lines <= limits["entries"]!)
        #expect(try JSONEncoder().encode(result).count <= limits["totalBytes"]!)
        #expect(result.dropped > 0)
        let attrs = try #require(contract["attrs"] as? [String: Any]), enums = try #require(attrs["enums"] as? [String: [String]])
        for entry in result.entries {
            if case .string(let failure) = entry.attrs?["failure"] { #expect(enums["failure"]!.contains(failure)) }
        }
    }

    @Test func buildSHAReachesTheConfiguration() throws {
        // The key is always in the built Info.plist; local and CI builds expand it to empty, so no buildSha.
        let raw = try #require(Bundle.main.object(forInfoDictionaryKey: CompanionBuildInfo.buildSHAKey) as? String)
        #expect(CompanionBuildInfo.buildSHA(raw) == (raw.isEmpty ? nil : raw.lowercased()))
        #expect(!raw.contains("$("))
        let sha = "4905102899ee20db0c436716f4783f6ba9827c5d"
        #expect(try Configuration(gameID: "clubhouse-annex", buildSHA: CompanionBuildInfo.buildSHA(sha)).buildSHA == sha)
        #expect(try Configuration(gameID: "clubhouse-annex", buildSHA: CompanionBuildInfo.buildSHA("")).buildSHA == nil)
    }
}

private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(4)) }
    Issue.record("condition not met")
}
private func attributes(_ item: [String: Any]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: ((item["attributes"] as? [[String: Any]]) ?? []).compactMap { entry in
        (entry["key"] as? String).flatMap { key in (entry["value"] as? [String: Any])?.values.first.map { (key, $0) } }
    })
}
private func spans(_ body: [String: Any]) -> [[String: Any]] {
    ((body["resourceSpans"] as? [[String: Any]]) ?? []).flatMap { ($0["scopeSpans"] as? [[String: Any]]) ?? [] }.flatMap { ($0["spans"] as? [[String: Any]]) ?? [] }
}
private func logRecords(_ body: [String: Any]) -> [[String: Any]] {
    ((body["resourceLogs"] as? [[String: Any]]) ?? []).flatMap { ($0["scopeLogs"] as? [[String: Any]]) ?? [] }.flatMap { ($0["logRecords"] as? [[String: Any]]) ?? [] }
}
private func logBodies(_ body: [String: Any]) -> [String] {
    logRecords(body).compactMap { ($0["body"] as? [String: Any])?["stringValue"] as? String }
}

nonisolated private final class TelemetryMemoryEnrollment: EnrollmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = EnrollmentRecord()
    func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}
nonisolated private final class TelemetryMemoryQueue: FeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [QueuedFeedback] = []
    func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { reports } }
    func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { reports = items } }
}
/// Answers the access, report and OTLP routes the way the service does; records what was sent.
private actor TelemetryMockTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let now: @Sendable () -> Date
    private(set) var reportAttemptTimes: [Date] = []
    private var reportStatus = 200
    private var holdsNextRefresh = false
    private var heldRefresh: CheckedContinuation<Void, Never>?
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        refreshEnd = now().addingTimeInterval(86400).ISO8601Format()
    }
    func setReportStatus(_ status: Int) { reportStatus = status }
    func holdNextRefresh() { holdsNextRefresh = true }
    var refreshIsHeld: Bool { heldRefresh != nil }
    func releaseRefresh() { heldRefresh?.resume(); heldRefresh = nil }
    private let refreshEnd: String
    var reportBodies: [[String: Any]] {
        requests.filter { $0.url!.path.hasSuffix("/reports") }.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    var telemetryPaths: [String] { requests.map { $0.url!.path }.filter { $0.contains("/v1/otlp/") } }
    func bodies(for signal: String) -> [[String: Any]] {
        requests.filter { $0.url!.path.hasSuffix("/v1/otlp/v1/\(signal)") }
            .compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path.hasSuffix("access/refresh"), holdsNextRefresh {
            holdsNextRefresh = false
            await withCheckedContinuation { heldRefresh = $0 }
        }
        let object: [String: Any]
        if path.hasSuffix("access/redeem") || path.hasSuffix("access/refresh") {
            object = ["v": 1, "scopeVersion": 2, "gameId": "phone-ui-fixture", "token": String(repeating: "b", count: 43),
                      "refreshToken": String(repeating: "r", count: 43), "expiresAt": now().addingTimeInterval(3600).ISO8601Format(),
                      "refreshExpiresAt": refreshEnd, "feedbackCorrelationVersion": 1]
        } else if path.hasSuffix("/reports") {
            reportAttemptTimes.append(now())
            if reportStatus != 200 { return HTTPResponse(status: reportStatus, headers: ["retry-after": "60"], body: Data()) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            object = ["id": body["id"]!, "status": "ready", "gameId": "phone-ui-fixture"]
        } else if path.hasSuffix("access/disconnect") {
            object = ["v": 1, "disconnected": true]
        } else if path.contains("/v1/otlp/v1/") {
            object = [:]
        } else { throw FramebriarError.network }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: try JSONSerialization.data(withJSONObject: object))
    }
}

nonisolated private final class TelemetryRecordCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func increment() { lock.withLock { total += 1 } }
    var count: Int { lock.withLock { total } }
}

nonisolated private final class TelemetryFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(now: Date = Date()) { value = now }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@MainActor private struct TelemetryLifetimeProbe: View {
    @State private var lifetime: CompanionStateLifetime<Int>
    init(make: @escaping () -> Int) { _lifetime = State(initialValue: CompanionStateLifetime(make)) }
    var body: some View { Text("Runtime \(lifetime.value)") }
}
