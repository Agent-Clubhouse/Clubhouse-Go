#if DEBUG
import SwiftUI

/// Opt-in, content-free hosted counters. No Release API, observation, storage of user content or timers.
@MainActor enum CompanionHomeBuildProbe {
    enum Kind: Hashable { case owner, content, scope, attention, layout, header, quiet, snapshot, row, rowMenu, projectMenu, quietRows, connection, activation, appUpdate, chips, linkedRows, dispatcherContent }
    static var renderedSort: ((CompanionProjectSort) -> Void)?
    static var scrollToIssued: ((CompanionHomeAnchor) -> Void)?
    static var phase: ((ScenePhase) -> Void)?
    static var snapshotAgents: ((Int) -> Void)?
    static var visibility: ((Bool) -> Void)?
    static var record: ((Kind) -> Void)?
    static var projection: ((CompanionHomeLayout) -> Void)?
    static var navigation: ((Binding<CompanionNavigation>) -> Void)?
    static var rowActions: ((CompanionTarget, CompanionAgentSettingsAction?, CompanionAgentWakeAction?, CompanionTerminalAction?) -> Void)?
    static var frame: ((Bool, String) -> Void)?
    static var frozenActions: ((CompanionAgentSettingsAction?, CompanionAgentWakeAction?, CompanionTerminalAction?) -> Void)?
    static var frozen: ((Bool) -> Void)?
    static var state: ((CompanionHomeScrollAnchorState, Binding<CompanionDesktopSelection>) -> Void)?
}
#endif
