#if DEBUG
import SwiftUI
import Framebriar
import FramebriarUI
import ClubhouseTransport
import CryptoKit

/// Mounts the actual app root, Settings and chat with isolated stores and no socket-capable feedback transport.
struct CompanionFeedbackRenewalFixture: View {
    @State private var fixture: Fixture?
    @State private var failure: String?
    @State private var evidence = ""

    var body: some View {
        Group {
            if let fixture {
                CompanionAppRoot(runtimeLifetime: fixture.runtimeLifetime)
                    .defaultAppStorage(fixture.defaults)
                    .overlay(alignment: .topLeading) {
                        Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
                            .accessibilityElement().accessibilityLabel("Synthetic renewal state")
                            .accessibilityValue(evidence).accessibilityIdentifier("feedback-renewal-evidence")
                    }
            } else if let failure {
                Text("Renewal fixture failed: \(failure)").accessibilityIdentifier("feedback-renewal-failure")
            } else {
                ProgressView("Preparing isolated renewal fixture")
            }
        }
        .task {
            guard fixture == nil else { return }
            do {
                let prepared = try Fixture()
                await prepared.prepare()
                fixture = prepared
                while !Task.isCancelled {
                    evidence = try prepared.evidence()
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                return
            } catch {
                fixture = nil
                failure = String(describing: error)
            }
        }
    }

    @MainActor private struct Fixture {
        let runtimeLifetime: CompanionStateLifetime<CompanionRuntime>
        let defaults: UserDefaults
        let model: FeedbackModel
        let transport: RenewalTransport
        let enrollment: RenewalEnrollment
        let queue: RenewalQueue

        init() throws {
            let now = Date(timeIntervalSince1970: 1_900_000_000)
            let arguments = ProcessInfo.processInfo.arguments
            let offline = arguments.contains("--feedback-renewal-offline")
            let required = arguments.contains("--feedback-renewal-access-required")
            let transport = RenewalTransport()
            let enrollment = RenewalEnrollment(record: EnrollmentRecord(
                refreshToken: required ? nil : String(repeating: "r", count: 43),
                expiresAt: now.addingTimeInterval(offline || required ? 86_400 : -1),
                enrolled: true, notice: required ? .accessRequired : .offline, enrollmentRef: "renewal-fixture"))
            let config = try Configuration(gameID: "renewal-fixture", buildSHA: "abcdef0", endpoint: URL(string: "https://fixture.invalid/api")!)
            let queue = RenewalQueue(items: try (0..<2).map {
                QueuedFeedback(feedback: try ReviewedFeedback(configuration: config, notes: "Synthetic held report \($0)"),
                               blocked: true, enrollmentRef: "previous-fixture", heldForEnrollment: true)
            })
            let model = FeedbackModel(client: try Client(configuration: config, transport: transport,
                enrollmentStore: enrollment, feedbackStore: queue, now: { now }))
            let defaults = UserDefaults(suiteName: "feedback-renewal-fixture")!
            defaults.set(false, forKey: CompanionFeedback.shakePreferenceKey)
            defaults.set(false, forKey: CompanionFeedback.shakeScreenshotPreferenceKey)
            defaults.set(false, forKey: CompanionScreenshotFeedback.preferenceKey)
            self.defaults = defaults
            self.transport = transport; self.enrollment = enrollment; self.queue = queue; self.model = model
            runtimeLifetime = CompanionStateLifetime {
                let oldFeedback = CompanionSceneTestSupport.makeFeedback
                let oldStore = CompanionSceneTestSupport.makeStore
                defer {
                    CompanionSceneTestSupport.makeFeedback = oldFeedback
                    CompanionSceneTestSupport.makeStore = oldStore
                }
                CompanionSceneTestSupport.makeFeedback = { (model, nil) }
                CompanionSceneTestSupport.makeStore = { CompanionStore(service: CompanionPreviewService()) }
                return CompanionRuntime(registry: AnnexTransportRegistry(), persistsDrafts: false)
            }
        }

        func prepare() async {
            await model.setActive(true)
            await model.tick()
            let runtime = runtimeLifetime.value
            await runtime.start()
            runtime.store.apply(.hosts(CompanionPreviewService.hosts(now: .now)))
            await runtime.store.load(CompanionPreviewService.target)
            runtime.store.drafts[CompanionPreviewService.target] = "Synthetic renewal draft"
            runtime.preferences.lastTab = .home
        }

        func evidence() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            let scope = model.client.configuration.storageScope
            let preferences = [CompanionFeedback.shakePreferenceKey, CompanionFeedback.shakeScreenshotPreferenceKey,
                               CompanionScreenshotFeedback.preferenceKey].map { defaults.bool(forKey: $0) }
            return "requests=\(transport.count);enrollment=\(digest(try encoder.encode(enrollment.load(scope: scope))));queue=\(digest(try encoder.encode(queue.load(scope: scope))));preferences=\(preferences);queued=\(model.status?.queued ?? -1);enrolled=\(model.status?.canSubmit == true);diagnostics=\(model.reportDiagnostics == .off ? "off" : "on")"
        }
    }
}

private final class RenewalTransport: HTTPTransport, @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var requests = 0
    nonisolated var count: Int { lock.withLock { requests } }
    nonisolated func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { requests += 1 }
        throw FramebriarError.network
    }
}

private final class RenewalEnrollment: EnrollmentStore, @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var record: EnrollmentRecord
    init(record: EnrollmentRecord) { self.record = record }
    nonisolated func load(scope: String) throws -> EnrollmentRecord { lock.withLock { record } }
    nonisolated func save(_ record: EnrollmentRecord, scope: String) throws { lock.withLock { self.record = record } }
}

private final class RenewalQueue: FeedbackStore, @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var items: [QueuedFeedback]
    init(items: [QueuedFeedback]) { self.items = items }
    nonisolated func load(scope: String) throws -> [QueuedFeedback] { lock.withLock { items } }
    nonisolated func save(_ items: [QueuedFeedback], scope: String) throws { lock.withLock { self.items = items } }
}
#endif
