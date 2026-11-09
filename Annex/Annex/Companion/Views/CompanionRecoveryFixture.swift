#if DEBUG
import SwiftUI
import Observation
import ClubhouseTransport

/// Explicit result gates and value call records only. No network, timer, UI owner or production service mutation.
@MainActor @Observable final class CompanionRecoveryFixtureService: CompanionService {
    enum ResultMode: Equatable { case success, failure, held }
    static let alpha = CompanionTarget(hostID: "recovery-one", projectID: "fixture", agentID: "alpha")
    static let beta = CompanionTarget(hostID: "recovery-one", projectID: "fixture", agentID: "beta")
    static let gamma = CompanionTarget(hostID: "recovery-two", projectID: "fixture", agentID: "gamma")
    static let targets = [alpha, beta, gamma]
    static let historyError = "Synthetic history failure.\nThe response was incomplete.\nNo real desktop was contacted."
    static let connectionError = "Synthetic connection failure.\nThe client is disconnected from this fixture host."

    var modes: [CompanionTarget: ResultMode] = [:]
    private(set) var historyCalls: [CompanionTarget: Int] = [:]
    private(set) var reconnectCalls: [String: Int] = [:]
    private(set) var isTearingDown: Bool = false
    @ObservationIgnored private var pending: [CompanionTarget: [CheckedContinuation<CompanionHistory, Error>]] = [:]
    nonisolated deinit {}

    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        historyCalls[target, default: 0] += 1
        guard !isTearingDown else { return Self.history(target) }
        switch modes[target] ?? .success {
        case .success: return Self.history(target)
        case .failure: throw CompanionServiceError.unavailable(Self.historyError + "\nTarget: \(target.agentID) on \(target.hostID).")
        case .held:
            return try await withCheckedThrowingContinuation { pending[target, default: []].append($0) }
        }
    }
    func finish(_ target: CompanionTarget, as mode: ResultMode) {
        guard mode != .held else { return }
        modes[target] = mode
        let requests = pending.removeValue(forKey: target) ?? []
        for request in requests {
            if mode == .success { request.resume(returning: Self.history(target)) }
            else { request.resume(throwing: CompanionServiceError.unavailable(Self.historyError + "\nTarget: \(target.agentID) on \(target.hostID).")) }
        }
    }
    var pendingHistoryCount: Int { pending.values.reduce(0) { $0 + $1.count } }
    func beginTeardown() {
        // Close admission before draining: a queued callback can arrive after the current pending list is emptied.
        isTearingDown = true
        modes.removeAll()
        for target in Array(pending.keys) { finish(target, as: .success) }
    }
    func reconnect(hostID: String) async { reconnectCalls[hostID, default: 0] += 1 }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Synthetic fixture only") }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Synthetic fixture only") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Synthetic fixture only") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Synthetic fixture only") }

    static func hosts() -> [CompanionHost] {
        ["recovery-one", "recovery-two"].map { hostID in
            CompanionHost(id: hostID, name: hostID == "recovery-one" ? "Fixture One" : "Fixture Two", endpoint: "Synthetic only", connection: .connected,
                projects: [.init(id: "fixture", name: "Recovery fixture", agents: targets.filter { $0.hostID == hostID }.map {
                    CompanionAgent(id: $0, name: $0.agentID.capitalized, subtitle: "Synthetic recovery conversation", status: .idle,
                                   capabilities: [.chat, .steer], executionMode: "chat")
                })])
        }
    }
    private static func history(_ target: CompanionTarget) -> CompanionHistory {
        .init(items: (1...12).map {
            .message(.init(id: "recovery-\(target.agentID)-\($0)", role: .assistant,
                text: "\(target.agentID.capitalized) reading marker \($0). " + String(repeating: "Synthetic retained transcript. ", count: 8)))
        }, hasEarlierMessages: true, lastSequence: 12, sessionID: "recovery-\(target.agentID)")
    }
}

/// All stored owners are the reviewed UI-free Store/service; selection/visibility are values.
@MainActor @Observable final class CompanionRecoveryFixtureScene {
    let service: CompanionRecoveryFixtureService
    let store: CompanionStore
    var target: CompanionTarget = CompanionRecoveryFixtureService.alpha
    var isActive: Bool = true
    var initiallyShowsRecoveryDetails = false
    /// Passive fixture witnesses; neither value controls the component's private presentation State.
    var observedRecoveryDetailsSeed: Bool?
    var recoveryDetailsSeedObservationCount = 0
    nonisolated deinit {}

    init() {
        let service = CompanionRecoveryFixtureService()
        self.service = service
        self.store = CompanionStore(service: service)
        store.apply(.hosts(CompanionRecoveryFixtureService.hosts()))
    }
    func connection(_ value: CompanionConnection, hostID: String? = nil) {
        var hosts = store.hosts
        guard let index = hosts.firstIndex(where: { $0.id == (hostID ?? target.hostID) }) else { return }
        hosts[index].connection = value
        store.apply(.hosts(hosts))
    }
}

/// Retains the same conversation structure when target/selection changes; no .id reset of the transcript.
struct CompanionRecoveryFixtureConversation: View {
    @Bindable var scene: CompanionRecoveryFixtureScene
    var showsControls = false
    @State private var showsActions = false
    var body: some View {
        NavigationStack {
            Group {
                if let agent = scene.store.agent(for: scene.target) {
                    let seed = scene.initiallyShowsRecoveryDetails
                    CompanionConversationView(store: scene.store, agent: agent, showsActions: scene.isActive,
                                              initiallyShowsRecoveryDetails: seed)
                        .onChange(of: seed) { _, observed in
                            scene.observedRecoveryDetailsSeed = observed
                            scene.recoveryDetailsSeedObservationCount += 1
                        }
                }
            }
            .toolbar {
                if showsControls {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Recovery fixture", systemImage: "switch.2") { showsActions = true }
                            .accessibilityIdentifier("recovery-fixture-menu")
                    }
                }
            }
        }
        .companionTheme(.clubhouse)
        // A plain list rather than a native menu, so UI tests can scroll to any action at large text sizes.
        .sheet(isPresented: $showsActions) {
            List(actions, id: \.id) { action in
                Button(action.title) {
                    action.run()
                    showsActions = false
                }
                .accessibilityIdentifier("recovery-fixture-\(action.id)")
            }
        }
    }
    private var actions: [(id: String, title: String, run: () -> Void)] {
        [
            ("fail", "Fail held history", { scene.service.finish(scene.target, as: .failure) }),
            ("next-success", "Next refresh succeeds", { scene.service.modes[scene.target] = .success }),
            ("complete", "Complete held history", { scene.service.finish(scene.target, as: .success) }),
            ("connection-failure", "Connection failure", { scene.connection(.failed(CompanionRecoveryFixtureService.connectionError)) }),
            ("progress", "Reconnect progress", { scene.connection(.reconnecting) }),
            ("connected", "Connected", { scene.connection(.connected) }),
            ("operation", "Operation warning", { scene.store.reportAttachmentProblem("Synthetic operation warning stays separate.", target: scene.target) }),
        ] + CompanionRecoveryFixtureService.targets.map { target in
            ("select-\(target.agentID)", "Select \(target.agentID.capitalized)", { scene.target = target })
        }
    }
}

struct CompanionRecoveryFixture: View {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--companion-preview") && arguments.contains("--companion-preview-recovery-fixture")
    }
    @State private var scene: CompanionRecoveryFixtureScene = {
        let scene = CompanionRecoveryFixtureScene()
        scene.service.modes[CompanionRecoveryFixtureService.alpha] = .held
        scene.service.modes[CompanionRecoveryFixtureService.beta] = .failure
        scene.service.modes[CompanionRecoveryFixtureService.gamma] = .failure
        return scene
    }()
    var body: some View { CompanionRecoveryFixtureConversation(scene: scene, showsControls: true) }
}
#endif
