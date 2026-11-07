#if DEBUG
import SwiftUI

/// Opt-in, socket-free fixture for a real pan after bounded restore exhaustion.
struct CompanionReadingRestoreFixture: View {
    @State private var lifetime = CompanionStateLifetime {
        CompanionStore(service: CompanionPreviewService(showsLongReply: true))
    }
    @State private var ready = false
    @State private var mounted = true
    @State private var refuse = true
    @State private var sample = "pending"
    @State private var restoreDiagnostic = "pending"
    private var store: CompanionStore { lifetime.value }
    private var target: CompanionTarget { CompanionPreviewService.target }
    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                if ready, mounted, let agent = store.hosts.flatMap(\.allAgents).first(where: { $0.id == target }) {
                    CompanionConversationView(store: store, agent: agent)
                } else { Text("Reading fixture") }
            }
            // The label and its layout stay unchanged; closed restore operands appear only in the accessibility value.
            Text(sample).font(.caption2).accessibilityIdentifier("reading-restore-fixture")
                .accessibilityValue(restoreDiagnostic)
            Button("Remount chat") {
                Task {
                    refuse = false
                    mounted = false
                    try? await Task.sleep(for: .milliseconds(100))
                    mounted = true
                }
            }.accessibilityIdentifier("reading-restore-remount")
        }
        .task {
            let preview = CompanionPreviewService(showsLongReply: true)
            var events = preview.events().makeAsyncIterator()
            if let event = await events.next() { store.apply(event) }
            await store.load(target)
            let bookmark = store.readingBookmark(for: target)
            bookmark.position = CompanionReadingPosition(followsLatest: false, offset: 1_200,
                shownEntries: CompanionTimelineWindow.pageSize)
            CompanionReadingRestoreProbe.deliver = { _, _, _, _ in !refuse }
            ready = true
            defer { CompanionReadingRestoreProbe.deliver = nil }
            while !Task.isCancelled {
                let viewport = bookmark.viewport
                let next = "offset=\(viewport.metrics?.normalizedOffset ?? -1) saved=\(bookmark.position.offset) held=\(viewport.preserveBookmarkUntilUserAction ? 1 : 0) restoring=\(viewport.isRestoring ? 1 : 0) outcome=\(viewport.restoration?.outcome?.rawValue ?? "pending") mounted=\(mounted ? 1 : 0)"
                var diagnostic = "attempts=-1 target=-1 hold=none"
                if let restoration = viewport.restoration {
                    diagnostic = "attempts=\(restoration.attempts) target=\(restoration.offset ?? -1) hold=\(restoration.lastHold?.rawValue ?? "none")"
                    if let operands = restoration.lastOperands {
                        diagnostic += " holdOffset=\(operands.offset) holdMax=\(operands.maximum) holdContent=\(operands.content) holdFrameContent=\(operands.frameContent)"
                        diagnostic += " holdRaw=\(operands.rawOffset) holdTop=\(operands.topInset) holdBottom=\(operands.bottomInset) holdModelContainer=\(operands.container)"
                    }
                }
                // These latest owner samples are sequential and may be newer than lastHold.
                if let g = viewport.debugGeometry {
                    diagnostic += " nowGeometry(seq=\(g.sequence),at=\(g.at),content=\(g.content),rawY=\(g.rawY),top=\(g.top),bottom=\(g.bottom),container=\(g.container),visible=\(g.visible))"
                }
                if let p = viewport.debugPreference {
                    diagnostic += " nowPreference(seq=\(p.sequence),at=\(p.at),size=\(String(describing: p.size)))"
                }
                if let c = viewport.debugContentGlobal {
                    diagnostic += " nowContentGlobal(seq=\(c.sequence),at=\(c.at),frame=\(c.frame))"
                }
                if let v = viewport.debugScrollGlobal {
                    diagnostic += " nowScrollGlobal(seq=\(v.sequence),at=\(v.at),frame=\(v.frame))"
                }
                if next != sample { sample = next }
                if diagnostic != restoreDiagnostic { restoreDiagnostic = diagnostic }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
}
#endif
