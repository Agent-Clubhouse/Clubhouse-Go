import Foundation

/// Decides which app-level plugin rows the Clubhouse (Annexes) tab surfaces.
///
/// The tab is a rail of **Canvas + projects** (GH #86): we only show plugins
/// that are Annex-enabled *and* have a working mobile view. That hides rows
/// which are not Annex-enabled and rows that only lead to the
/// "This plugin is not yet available on mobile." placeholder (hub, browser,
/// git, search, issues, group project, …).
enum ClubhousePluginVisibility {
    /// App-scope plugin IDs that render a real, functional mobile view today.
    /// Project-scoped plugins (terminal, files) surface from the project page,
    /// and `home` is already covered by the Dashboard tab — so the only
    /// app-level rail entry is the canvas.
    static let supportedAppPluginIDs: Set<String> = ["canvas"]

    /// Whether a single app-level plugin should appear as a row.
    static func shouldShow(_ plugin: PluginSummary) -> Bool {
        plugin.annexEnabled && supportedAppPluginIDs.contains(plugin.id)
    }

    /// Filter a plugin list down to the rows the Clubhouse tab should display.
    static func visibleAppPlugins(_ plugins: [PluginSummary]) -> [PluginSummary] {
        plugins.filter(shouldShow)
    }
}
