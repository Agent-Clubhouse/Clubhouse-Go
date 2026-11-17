import Combine
import SwiftUI

/// Display values only, captured once when pushing from Home. Never used to authorize an action.
/// Unlike a Store clone this has no observation, service, callbacks, tasks or persistence.
struct CompanionHomeRenderSnapshot {
    let hosts: [CompanionHost]
    let palette: CompanionPalette
    let helperLabels: [String: CompanionHelperRouting.Labels]
    let entries: [CompanionProjectEntry]
    let layout: CompanionHomeLayout
    let attention: [CompanionAttentionItem]
    let rowContext: CompanionAgentRowContext
    let finished: [CompanionProjectTarget: [CompanionFinishedRun]]
    let finishedError: String?
    let states: [CompanionProjectTarget: CompanionProjectMenuDisplay]
    let linkedStates: [String: CompanionProjectMenuDisplay]
    let projectActivity: [CompanionProjectTarget: Date]
    let dispatcherActivity: [CompanionTarget: CompanionCapturedActivity]
    let agents: Set<CompanionTarget>
    let settings: Set<CompanionTarget>
    let wake: [CompanionTarget: [CompanionWakeChoice]]
    let terminal: [CompanionTerminalScope: CompanionTerminalAvailability]
    let wakeProjects: Set<CompanionProjectTarget>
}

/// Optional wrapper distinguishes a captured missing value from nil (the ordinary live path).
struct CompanionCapturedActivity { let date: Date? }

/// Optional display input for the existing menu bodies. Nil keeps every non-Home caller live.
struct CompanionProjectMenuDisplay: Equatable {
    let state: CompanionProjectState?
    var lastActivity: Date? = nil
    var canChange = false
    var connectionHint: String? = nil
}

/// Owner-computed presentation values for the lazy List, in both live and frozen Home.
/// No Store, action closures, views or per-agent permission projection crosses this boundary.
struct CompanionHomeContentValues: Equatable {
    let hosts: [CompanionHost]
    let entries: [CompanionProjectEntry]
    let attention: [CompanionAttentionItem]
    let finished: [CompanionProjectTarget: [CompanionFinishedRun]]
    let finishedError: String?
    let states: [CompanionProjectTarget: CompanionProjectMenuDisplay]
    let linkedStates: [String: CompanionProjectMenuDisplay]
    let projectActivity: [CompanionProjectTarget: Date]
    let terminal: [CompanionTerminalScope: CompanionTerminalAvailability]
    let wakeProjects: Set<CompanionProjectTarget>

    init(snapshot: CompanionHomeRenderSnapshot) {
        self.init(hosts: snapshot.hosts, entries: snapshot.entries, attention: snapshot.attention,
                  finished: snapshot.finished, finishedError: snapshot.finishedError, states: snapshot.states,
                  linkedStates: snapshot.linkedStates, projectActivity: snapshot.projectActivity,
                  terminal: snapshot.terminal, wakeProjects: snapshot.wakeProjects)
    }

    init(hosts: [CompanionHost], entries: [CompanionProjectEntry], attention: [CompanionAttentionItem],
         finished: [CompanionProjectTarget: [CompanionFinishedRun]], finishedError: String?,
         states: [CompanionProjectTarget: CompanionProjectMenuDisplay], linkedStates: [String: CompanionProjectMenuDisplay],
         projectActivity: [CompanionProjectTarget: Date], terminal: [CompanionTerminalScope: CompanionTerminalAvailability],
         wakeProjects: Set<CompanionProjectTarget>) {
        self.hosts = hosts; self.entries = entries; self.attention = attention
        self.finished = finished; self.finishedError = finishedError; self.states = states
        self.linkedStates = linkedStates; self.projectActivity = projectActivity
        self.terminal = terminal; self.wakeProjects = wakeProjects
    }
}

/// Existing execution handles, held only for the pushed route. Kept separate from display values.
/// No new task or owner; cleared on pop/tab exit. Predicates read the real Store when activated.
struct CompanionHomeFrozenActions {
    let settings: CompanionAgentSettingsAction?
    let wake: CompanionAgentWakeAction?
    let terminal: CompanionTerminalAction?
    var openAgent: @MainActor (CompanionTarget) -> Void = { _ in }
    var openReview: (@MainActor (CompanionReviewLaunch) -> Void)? = nil
}

extension CompanionHomeFrozenActions {
    /// Build stable display closures once. Their execution delegates still resolve through live Store/Root State.
    func capturingDisplay(_ snapshot: CompanionHomeRenderSnapshot, store: CompanionStore) -> Self {
        .init(settings: frozenSettings(snapshot, store: store), wake: frozenWake(snapshot), terminal: frozenTerminal(snapshot),
              openAgent: openAgent, openReview: openReview)
    }

    private func frozenSettings(_ snapshot: CompanionHomeRenderSnapshot, store: CompanionStore) -> CompanionAgentSettingsAction? {
        settings.map { actions in
            .init(canOpen: { snapshot.settings.contains($0) }, open: { target in
                if actions.canOpen(target) {
                    #if DEBUG
                    CompanionHomeBuildProbe.record?(.activation)
                    #endif
                    actions.open(target)
                }
            }, openDetails: actions.openDetails.map { open in { target in
                if store.agent(for: target) != nil { open(target) }
            } })
        }
    }

    private func frozenWake(_ snapshot: CompanionHomeRenderSnapshot) -> CompanionAgentWakeAction? {
        wake.map { actions in
            .init(choices: { snapshot.wake[$0] ?? [] }, wake: { target, choice in
                if actions.choices(target).contains(choice) {
                    #if DEBUG
                    CompanionHomeBuildProbe.record?(.activation)
                    #endif
                    actions.wake(target, choice)
                }
            })
        }
    }

    private func frozenTerminal(_ snapshot: CompanionHomeRenderSnapshot) -> CompanionTerminalAction? {
        terminal.map { actions in
            .init(availability: { snapshot.terminal[$0] ?? .hidden }, open: { target in
                if actions.availability(target).isAvailable {
                    #if DEBUG
                    CompanionHomeBuildProbe.record?(.activation)
                    #endif
                    actions.open(target)
                }
            })
        }
    }

}

/// The modifier's concrete hierarchy is identical before/during/after a push: the List never changes branches.
/// Transforming an environment key replaces incoming Root closure churn with the SAME captured action values.
struct CompanionHomeRowInputs: ViewModifier {
    let store: CompanionStore
    let snapshot: CompanionHomeRenderSnapshot?
    let impliedHostID: String?
    var actions: CompanionHomeFrozenActions? = nil

    func body(content: Content) -> some View {
        #if DEBUG
        let _ = snapshot.map { _ in CompanionHomeBuildProbe.frozenActions?(actions?.settings, actions?.wake, actions?.terminal) }
        #endif
        return content
            .environment(\.companionAgentRowContext, context)
            .transformEnvironment(\.companionHelperLabels) { value in if let snapshot { value = snapshot.helperLabels } }
            .transformEnvironment(\.companionPalette) { value in if let snapshot { value = snapshot.palette } }
            .transformEnvironment(\.companionAgentSettings) { value in if snapshot != nil { value = actions?.settings } }
            .transformEnvironment(\.companionAgentWake) { value in if snapshot != nil { value = actions?.wake } }
            .transformEnvironment(\.companionTerminal) { value in if snapshot != nil { value = actions?.terminal } }
            .transformEnvironment(\.companionOpenAgent) { value in if let actions, snapshot != nil { value = actions.openAgent } }
            .transformEnvironment(\.companionOpenReview) { value in if snapshot != nil { value = actions?.openReview } }
    }

    private var context: CompanionAgentRowContext {
        if let snapshot {
            var value = snapshot.rowContext
            value.impliedHostID = impliedHostID
            return value
        }
        return .init(hostNames: Dictionary(store.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            impliedHostID: impliedHostID, projectAccessDefaults: store.projectAccessDefaults, agentAccessDefaults: store.agentAccessDefaults)
    }
}

/// SwiftUI creates this storage lazily once. Mutating these non-published display values during
/// the owner's construction cannot schedule another body pass. Captured execution handles can
/// retain Root's UI State, so a real MainActor task owns their final release.
@MainActor final class CompanionHomeRenderSession: ObservableObject {
    private(set) var snapshot: CompanionHomeRenderSnapshot?
    private(set) var actions: CompanionHomeFrozenActions?

    nonisolated deinit {
        // Root/UI State captured by these handles must be released inside a real Swift
        // task. The isolated-deinit runtime itself aborts during SwiftUI teardown (#551).
        Task { @MainActor [actions, snapshot] in
            withExtendedLifetime((actions, snapshot)) {}
        }
    }

    func prepare(visible: Bool, pushed: Bool,
                 capture: () -> (CompanionHomeRenderSnapshot, CompanionHomeFrozenActions)) {
        guard visible && pushed else { snapshot = nil; actions = nil; return }
        guard snapshot == nil else { return }
        let (snapshot, actions) = capture()
        self.actions = actions
        self.snapshot = snapshot
    }
}
