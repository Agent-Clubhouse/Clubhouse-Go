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
    private var store: CompanionStore { lifetime.value }
    private var target: CompanionTarget { CompanionPreviewService.target }
    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                if ready, mounted, let agent = store.hosts.flatMap(\.allAgents).first(where: { $0.id == target }) {
                    CompanionConversationView(store: store, agent: agent)
                } else { Text("Reading fixture") }
            }
            Text(sample).font(.caption2).accessibilityIdentifier("reading-restore-fixture")
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
                if next != sample { sample = next }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
}

/// Uncredited #569 characterization. This never changes restoration or fabricates geometry: the existing
/// delivery probe only delays a command until a real Store event has trimmed the rendered window.
struct CompanionReadingPrefixTrimFixture: View {
    nonisolated struct Sample: Equatable, Sendable {
        var phase = "loading"
        var followsLatest = true
        var entryID: String?
        var offset: Double?
        var entryLowerBound: Double?
        var beforeOffset: Double?
        var beforeLowerBound: Double?
        var pinnedOffset: Double?
        var reloadShift: Double?
        var shift: Double?
        var miss: Double?
        var attempts = 0
        var gateElapsed: Double?
        var outcome = "pending"
        var description: String {
            "phase=\(phase) follow=\(followsLatest ? 1 : 0) entry=\(entryID ?? "nil") offset=\(offset ?? -1) lower=\(entryLowerBound ?? -1) beforeOffset=\(beforeOffset ?? -1) pin=\(pinnedOffset ?? -1) reloadShift=\(reloadShift ?? 0) shift=\(shift ?? 0) miss=\(miss ?? 0) attempts=\(attempts) elapsed=\(gateElapsed ?? 0) outcome=\(outcome)"
        }
    }

    var runRequest = 0
    var onSample: (@MainActor (Sample) -> Void)?
    @State private var lifetime = CompanionStateLifetime {
        CompanionStore(service: CompanionPreviewService(showsReadingScenario: true))
    }
    @State private var ready = false
    @State private var mounted = true
    @State private var armed = false
    @State private var released = false
    @State private var notExercised = false
    @State private var saved: CompanionReadingPosition?
    @State private var oldFirst: String?
    @State private var oldHidden = 0
    @State private var oldEntryIDs: [String] = []
    @State private var oldLower: Double?
    @State private var oldMetrics: CompanionScrollMetrics?
    @State private var reloadRevision: UUID?
    @State private var editedEntryID: String?
    @State private var editedFrame: ClosedRange<Double>?
    @State private var pinnedLower: Double?
    @State private var startedAt: TimeInterval?
    @State private var pinned: Double?
    @State private var observedShift: Double?
    @State private var attempts = 0
    @State private var gateAttempts: Int?
    @State private var gateElapsed: Double?
    @State private var sample = Sample()
    private var store: CompanionStore { lifetime.value }
    private var target: CompanionTarget { CompanionPreviewService.target }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                if ready, mounted, let agent = store.hosts.flatMap(\.allAgents).first(where: { $0.id == target }) {
                    CompanionConversationView(store: store, agent: agent)
                } else { Text("Reading fixture") }
            }
            // Fixed geometry: publishing diagnostics must not resize the transcript.
            Text(sample.description).font(.caption2).lineLimit(1).frame(height: 24)
                .accessibilityIdentifier("reading-prefix-trim-state")
            Button("Restore across a prefix trim", action: begin)
                .accessibilityIdentifier("reading-prefix-trim-begin")
                .disabled(!ready || armed || saved != nil)
        }
        .onChange(of: runRequest) { _, _ in begin() }
        .task {
            let service = CompanionPreviewService(showsReadingScenario: true)
            var events = service.events().makeAsyncIterator()
            if let event = await events.next() { store.apply(event) }
            await store.load(target)
            // A same-session snapshot is the production history-replacement route used below.
            store.apply(.timeline(target, items: store.conversation(for: target).items, sequence: 0,
                reset: true, sessionID: "prefix-trim-fixture"))
            CompanionReadingRestoreProbe.deliver = { _, attempt, offset, _ in
                guard armed else { return true }
                return delivery(attempt: attempt, offset: offset)
            }
            PrefixTrimWindowObservation.observed = false
            CompanionReadingOpeningProbe.record = { value in
                guard value.target == target, value.phase == .body else { return }
                PrefixTrimWindowObservation.observed = true
                PrefixTrimWindowObservation.startID = value.windowStartID
                PrefixTrimWindowObservation.revision = value.historyRevision
            }
            defer {
                CompanionReadingRestoreProbe.deliver = nil
                CompanionReadingOpeningProbe.record = nil
                PrefixTrimWindowObservation.observed = false
                PrefixTrimWindowObservation.startID = nil
                PrefixTrimWindowObservation.revision = nil
            }
            ready = true
            while !Task.isCancelled {
                publish()
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    private func window(retaining id: String?) -> CompanionTimelineWindow {
        CompanionTimelineWindow(rows: store.timelineRows(for: target),
                                limit: store.readingBookmark(for: target).position.shownEntries, retaining: id)
    }

    private func begin() {
        let bookmark = store.readingBookmark(for: target)
        let viewport = bookmark.viewport
        guard ready, !armed, saved == nil, !bookmark.position.followsLatest,
              PrefixTrimWindowObservation.observed, PrefixTrimWindowObservation.startID == nil,
              !viewport.isRestoring, let id = bookmark.position.entryID,
              let lower = viewport.frames[id]?.lowerBound, let metrics = viewport.metrics,
              abs(metrics.contentHeight - (viewport.frameContentHeight ?? -1)) < 1 else { return }
        let before = window(retaining: id)
        var items = store.conversation(for: target).items
        guard let index = items.indices.reversed().first(where: { index in
            guard case .message(let message) = items[index] else { return false }
            let entryID = "message:\(message.id)"
            return entryID != before.entries.first?.id && before.entries.contains { $0.id == entryID }
                && viewport.frames[entryID].map { $0.upperBound <= lower } == true
        }), case .message(var message) = items[index],
              let measuredEditedFrame = viewport.frames["message:\(message.id)"] else {
            notExercised = true
            publish()
            return
        }
        editedEntryID = "message:\(message.id)"
        editedFrame = measuredEditedFrame
        message.text += "\n\nA resynchronised paragraph expands this existing earlier message without changing its identity."
        items[index] = .message(message)
        saved = bookmark.position
        oldFirst = before.entries.first?.id
        oldHidden = before.hiddenCount
        oldEntryIDs = before.entries.map(\.id)
        oldLower = lower
        oldMetrics = metrics
        armed = true
        // #582 makes remount windows bookmark-first. Exercise A on a still-open normal window instead:
        // a real same-session resync changes one measured preceding row, forcing a nonzero restore.
        // Identical history would already be aligned and could never reach the delivery gate.
        let conversation = store.conversation(for: target)
        store.apply(.timeline(target, items: items, sequence: (conversation.lastSequence ?? 0) + 1,
            reset: true, sessionID: conversation.sessionID))
        reloadRevision = store.conversation(for: target).historyRevision
        NSLog("READING569_RELOAD edited=%@ oldFrame=%@ bookmark=%@ oldLower=%.6f oldOffset=%.6f oldRevision=%@ newRevision=%@",
              editedEntryID ?? "nil", String(describing: measuredEditedFrame), id, lower, metrics.normalizedOffset,
              conversation.historyRevision.uuidString, reloadRevision?.uuidString ?? "nil")
    }

    private func delivery(attempt: Int, offset: Double) -> Bool {
        attempts = attempt
        guard let saved, let id = saved.entryID, let oldLower, let oldMetrics else {
            notExercised = true
            return true
        }
        let bookmark = store.readingBookmark(for: target)
        let viewport = bookmark.viewport
        if startedAt == nil {
            let beforeTail = window(retaining: id)
            guard PrefixTrimWindowObservation.observed, PrefixTrimWindowObservation.startID == nil,
                  let reloadRevision, viewport.historyRevision == reloadRevision,
                  viewport.restoration?.revision == reloadRevision,
                  PrefixTrimWindowObservation.revision == reloadRevision,
                  beforeTail.entries.map(\.id) == oldEntryIDs, beforeTail.hiddenCount == oldHidden,
                  bookmark.position.entryID == id,
                  let lower = viewport.frames[id]?.lowerBound, abs(lower - oldLower) > 1,
                  let editedEntryID, let editedFrame, let changedFrame = viewport.frames[editedEntryID],
                  changedFrame.upperBound - changedFrame.lowerBound > editedFrame.upperBound - editedFrame.lowerBound + 1,
                  let metrics = viewport.metrics,
                  abs(metrics.contentHeight - (viewport.frameContentHeight ?? -1)) < 1 else {
                // A different reload window cannot classify this race. Never compensate the fixture silently.
                notExercised = true
                return true
            }
            // The real restoration has already pinned its offset before invoking this existing hook.
            startedAt = ProcessInfo.processInfo.systemUptime
            pinned = viewport.restoration?.offset
            pinnedLower = lower
            guard pinned == offset, abs(offset - (oldMetrics.normalizedOffset + lower - oldLower)) <= 2 else {
                notExercised = true
                return true
            }
            NSLog("READING569_PIN edited=%@ changedFrame=%@ bookmark=%@ newLower=%.6f reloadShift=%.6f pin=%.6f revision=%@",
                  editedEntryID, String(describing: changedFrame), id, lower, lower - oldLower, offset, reloadRevision.uuidString)
            store.apply(.upsert(target, .message(.init(id: "prefix-trim-tail", role: .assistant,
                text: "A distinct tail reply arrives while the earlier reading command is in flight.")), sequence: nil))
            publish()
            return false
        }
        if released || notExercised { return true }
        let elapsed = ProcessInfo.processInfo.systemUptime - (startedAt ?? 0)
        gateElapsed = elapsed
        if attempt > 10 || elapsed >= 1 {
            notExercised = true
            publish()
            return true
        }
        let after = window(retaining: id)
        let first = after.entries.first?.id
        let shift = pinnedLower.flatMap { before in viewport.frames[id].map { $0.lowerBound - before } }
        let matches = viewport.metrics.map {
            abs($0.contentHeight - (viewport.frameContentHeight ?? -1)) < 1
                && abs($0.containerHeight - oldMetrics.containerHeight) < 1
                && abs($0.topInset - oldMetrics.topInset) < 1
                && abs($0.bottomInset - oldMetrics.bottomInset) < 1
        } ?? false
        // The projection alone is insufficient: require the new first entry's real frame and the old
        // first entry's removal, as well as the bookmarked entry's actual measured displacement.
        if pinned != nil, after.hiddenCount != oldHidden, first != oldFirst,
           first.map({ viewport.frames[$0] != nil }) == true,
           oldFirst.map({ viewport.frames[$0] == nil }) == true,
           let shift, abs(shift) > 1, matches {
            observedShift = shift
            gateAttempts = attempt
            released = true
            publish()
            return true
        }
        if attempt >= 10 {
            // A missed gate is a fixture failure, never evidence for or against H1. Release normal
            // delivery so this diagnostic does not modify product cancellation/timeout semantics.
            notExercised = true
            publish()
            return true
        }
        publish()
        return false
    }

    private func publish() {
        let bookmark = store.readingBookmark(for: target)
        let viewport = bookmark.viewport
        if armed, pinned == nil, let reloadRevision,
           viewport.restoration?.revision == reloadRevision, viewport.restoration?.outcome == .arrived {
            // Already aligned is a missed precondition, never a passing H1 regression.
            notExercised = true
        }
        var next = Sample()
        next.phase = notExercised ? "H1-not-exercised" : released ? "released" : armed ? "waiting" : ready ? "ready" : "loading"
        next.followsLatest = bookmark.position.followsLatest
        next.entryID = saved?.entryID ?? bookmark.position.entryID
        next.offset = viewport.metrics?.normalizedOffset
        next.entryLowerBound = next.entryID.flatMap { viewport.frames[$0]?.lowerBound }
        next.beforeOffset = oldMetrics?.normalizedOffset
        next.beforeLowerBound = oldLower
        next.pinnedOffset = pinned
        next.reloadShift = pinnedLower.flatMap { lower in oldLower.map { lower - $0 } }
        next.shift = observedShift
        next.attempts = gateAttempts ?? attempts
        next.gateElapsed = gateElapsed
        next.outcome = viewport.restoration?.outcome?.rawValue ?? "pending"
        if let saved, let lower = next.entryLowerBound, let offset = next.offset {
            next.miss = offset - (lower + saved.distanceFromEntry)
        }
        if next != sample {
            sample = next
            onSample?(next)
            NSLog("READING569_FIXTURE %@", next.description)
        }
    }
}
/// Shared only by this opt-in serialized fixture; it observes the actual production window mode.
@MainActor private enum PrefixTrimWindowObservation {
    static var observed = false
    static var startID: String?
    static var revision: UUID?
}
#endif
