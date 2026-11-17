import SwiftUI

/// Needs you's origin badges apply to the combined tree and its one quiet disclosure.
/// Offline cached rows remain in Home's separate, non-actionable machine disclosures.
struct CompanionHomeLinkedProjectRows: View {
    let group: CompanionProjectGroup
    let quiet: CompanionHomeLinkedRows
    let preferences: CompanionPreferences
    let parentLines: [CompanionTarget: String]
    let onDismissFinished: (CompanionFinishedRun) -> Void
    let onClearFinished: ([CompanionProjectTarget]) -> Void
    let canOpenFinished: (CompanionTarget) -> Bool
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionAgentRowContext) private var rowContext

    private var attributedContext: CompanionAgentRowContext {
        var context = rowContext
        context.projectOriginLabels = quiet.projectOriginLabels
        return context
    }

    var body: some View {
        Group {
            CompanionAgentTreeRows(tree: group.tree, rows: group.tree.active, preferences: preferences, parentLines: parentLines)
            CompanionAgentTreeQuietFold(projectID: quiet.foldID, tree: group.tree, preferences: preferences,
                parentLines: parentLines, finishedRuns: quiet.finishedRuns, onDismissFinished: onDismissFinished,
                onClearFinished: { onClearFinished(quiet.finishedProjects) }, canOpenFinished: canOpenFinished)
            if group.tree.all.isEmpty && quiet.finishedRuns.isEmpty && group.entry.members.contains(where: { $0.host.connection.canOperate }) {
                Text("No agents yet").foregroundStyle(Color(palette.secondaryLabel))
                    .listRowBackground(CompanionCardBackground())
            }
        }
        .environment(\.companionAgentRowContext, attributedContext)
    }
}
