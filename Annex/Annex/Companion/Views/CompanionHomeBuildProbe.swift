#if DEBUG
import SwiftUI

/// Opt-in, content-free hosted counters. No Release API, observation, storage of user content or timers.
@MainActor enum CompanionHomeBuildProbe {
    enum Kind: Hashable { case owner, content, scope, attention, layout, header, quiet }
    static var visibility: ((Bool) -> Void)?
    static var record: ((Kind) -> Void)?
    static var projection: ((CompanionHomeLayout) -> Void)?
    static var navigation: ((Binding<CompanionNavigation>) -> Void)?
    static var state: ((CompanionHomeScrollAnchorState, Binding<CompanionDesktopSelection>) -> Void)?
}
#endif
