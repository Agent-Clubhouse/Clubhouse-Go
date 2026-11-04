import SwiftUI
import ClubhouseTransport

struct CompanionConversationView: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    /// Review keeps neighbouring chats alive; only the one on screen puts its menu in the navigation bar.
    var showsActions = true
    /// A parent-managed tab supplies visibility; navigation destinations use their normal appear/disappear lifecycle.
    var isVisible: Bool? = nil
    @State private var followLatest = true
    @State private var atLatest = true
    @State private var readingScrollPosition = ScrollPosition(edge: .bottom)
    @State private var confirmCancel = false
    @State private var showArchive = false
    /// How many of the newest timeline entries are laid out; Show earlier messages adds a page.
    @State private var shownEntries = Self.initialEntryLimit
    private static var initialEntryLimit: Int {
        #if DEBUG
        // A small deterministic window exercises prepend behavior without 150 UI gestures on hosted runners.
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-reading") { return 20 }
        #endif
        return CompanionTimelineWindow.pageSize
    }
    // A stable, lazily created bookmark survives retained-tab content unmounts. Input State lives below.
    @State private var composerMemory = CompanionStateLifetime { CompanionComposerMemory() }
    @State private var composerFocusRequests = 0
    @State private var composerDismissals = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionOpenAgent) private var openAgent
    @Environment(\.companionAgentSettings) private var agentSettings
    @Environment(\.companionSendFeedback) private var sendFeedback


    private var readingBookmark: CompanionReadingBookmark { store.readingBookmark(for: target) }
    private var readingViewport: CompanionReadingViewport { readingBookmark.viewport }
    private var target: CompanionTarget { agent.id }
    private var conversation: CompanionConversation { store.conversation(for: target) }
    private var connection: CompanionConnection { store.host(for: target)?.connection ?? .offline }
    private var canRespond: Bool { store.canOperate(target) && agent.capabilities.contains(.approve) && !store.pendingCommands.contains(target) }
    /// A running terminal agent's own PTY takes the chat's place, when the desktop lets the phone attach to it.
    private var showsAgentTerminal: Bool { agent.runsInTerminal && store.terminalAvailability(.agentPTY(target)).isAvailable }


    var body: some View {
        #if DEBUG
        let _ = CompanionConversationBuildProbe.record?(.body, target)
        #endif
        Group {
            if isVisible != false { content }
            else { Color.clear }
        }
        .onChange(of: isVisible) { _, visible in
            if visible == false {
                readingViewport.clearGeometry()
            }
        }
    }

    private var content: some View {
        CompanionChatPerformance.measureBody(target: target, messageCount: conversation.items.count) {
        VStack(spacing: 0) {
            contextHeader
            if store.justCreated == target { CompanionCreatedAgentNotice(store: store, agent: agent) { focusComposer() } }
            if !connection.canOperate || conversation.requiresResync { connectionBanner }
            if let error = store.operationErrors[target] {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { store.dismissError(for: target) }.labelStyle(.iconOnly)
                }
                .padding().background(Color(palette.warning).opacity(0.12))
                .accessibilityElement(children: .contain)
            }
            if showsAgentTerminal { CompanionAgentTerminalPane(store: store, target: target) }
            else {
                timeline.companionContentPreviews(store: store, target: target)
                    .environment(\.companionSenderResolver, CompanionSenderResolver(agents: store.host(for: target)?.allAgents ?? []))
            }
        }
        .companionBackground()
        .navigationTitle(agent.isDispatcher ? CompanionDispatcher.name : agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsActions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh conversation", systemImage: "arrow.clockwise") { Task { await store.load(target, force: true) } }
                        Button("Conversation archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                        if let agentSettings { CompanionAgentMenuItems(target: target, actions: agentSettings) }
                        CompanionTerminalMenuItem(scope: .agentShell(target))
                        Section("Conversation details") {
                            Text(contextName)
                            if let model = agent.model { Text(model) }
                        }
                        if agent.capabilities.contains(.wake) {
                            ForEach(store.wakeChoices(for: target)) { choice in
                                Button(choice.label, systemImage: choice.systemImage) { Task { await store.wake(target, choice) } }
                                    .disabled(!store.canWake(target))
                            }
                        }
                        if agent.status == .working {
                            Button("Interrupt turn", systemImage: "stop.circle", role: .destructive) { confirmCancel = true }
                                .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel))
                        }
                        if let sendFeedback { Button("Send feedback", systemImage: "exclamationmark.bubble", action: sendFeedback) }
                    } label: { Label("Conversation actions", systemImage: "ellipsis") }
                    .accessibilityIdentifier("conversation-actions-menu")
                }
            }
        }
        // Bars, not insets: the transcript gets the system scroll-edge effect under the glass instead of showing through.
        .safeAreaBar(edge: .top, spacing: 0) { otherAgentBanner }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if agent.runsInTerminal { if !showsAgentTerminal { terminalNotice } } else {
                CompanionConversationComposer(store: store, agent: agent, memory: composerMemory.value,
                    focusRequests: composerFocusRequests, confirmCancel: $confirmCancel, dismissals: composerDismissals)
            }
        }
        .sheet(isPresented: $showArchive) { CompanionArchiveView(store: store, target: target) }
        .task(id: target) { await store.load(target, force: conversation.requiresResync) }
        .task(id: scenePhase == .active && showsActions) {
            // A bounded summary while an open conversation is active. This is scheduling delay, not GPU frame time.
            guard scenePhase == .active, showsActions else { return }
            let performanceLease = CompanionChatPerformance.start(target: target)
            defer { CompanionChatPerformance.stop(performanceLease) }
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let start = clock.now
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled, scenePhase == .active else { return }
                let elapsed = start.duration(to: clock.now).components
                let ms = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                AnnexTelemetry.shared.recordMainActorDelay(durationMs: max(0, ms - 250), messageCount: conversation.items.count)
            }
        }
        .onChange(of: connection) { _, current in
            if current.canOperate && conversation.requiresResync && !conversation.isLoading {
                Task { await store.load(target, force: true) }
            }
        }
        .confirmationDialog("Interrupt this turn?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Interrupt turn", role: .destructive) { Task { await store.cancel(target) } }
        } message: { Text("The current turn will be interrupted. You can then send a new direction in the same conversation.") }
        }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                CompanionStatusText(status: agent.status).font(.caption.weight(.semibold))
                if agent.freeAgentMode { CompanionFreeAgentBadge() }
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("· \(contextName)").font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let controls = agent.chatControls { CompanionLevelBadge(level: controls.currentLevel) }
                    else if let model = agent.model { Text(model).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1) }
                } else {
                    Spacer(minLength: 0)
                    if let controls = agent.chatControls { CompanionLevelBadge(level: controls.currentLevel) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("companion-chat-header")
            activityLine
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    /// Elapsed time and the running tool, or what the agent waits on, with context fill: the desktop's chat header.
    @ViewBuilder private var activityLine: some View {
        let percent = agent.contextUsage?.percent
        let ticking = agent.status == .working && agent.turnStartedAt != nil
        TimelineView(.periodic(from: .now, by: ticking ? 1 : 60)) { context in
            let activity = CompanionChatActivity.line(status: agent.status, turnStartedAt: agent.turnStartedAt, items: conversation.items, now: context.date)
            if activity != nil || percent != nil {
                HStack(spacing: 6) {
                    if let activity {
                        Text(activity).font(.caption.monospacedDigit()).foregroundStyle(Color(palette.secondaryLabel))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .accessibilityIdentifier("companion-chat-activity")
                    }
                    Spacer(minLength: 8)
                    if let percent { CompanionContextRing(percent: percent) }
                }
            }
        }
    }

    private var contextName: String {
        guard let host = store.host(for: target) else { return "Desktop unavailable" }
        // The Dispatcher has no project; its own name stands in.
        return "\(host.name) / \(host.placeName(for: target) ?? "Project")"
    }

    private var connectionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: conversation.requiresResync ? "arrow.trianglehead.2.clockwise.rotate.90" : "wifi.exclamationmark")
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.requiresResync ? "Conversation needs a refresh" : connection.label).font(.subheadline.weight(.semibold))
                Text(conversation.requiresResync ? "Some updates were missed. Refresh before sending another command." : connection.detail).font(.caption)
                Button(conversation.requiresResync ? "Refresh conversation" : "Retry") {
                    Task {
                        if conversation.requiresResync { await store.load(target, force: true) }
                        else { await store.reconnect(hostID: target.hostID) }
                    }
                }
                .font(.subheadline.weight(.semibold)).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// While the app is open there are no system banners, so another agent that needs you shows here.
    @ViewBuilder private var otherAgentBanner: some View {
        // Compare by agent, not list entry: a desktop can list one agent under more than one project.
        if let other = store.allAgents.first(where: { $0.status.needsYou && ($0.id.agentID != target.agentID || $0.id.hostID != target.hostID) }) {
            CompanionGlassBanner(systemImage: other.status.symbol,
                                 text: Text("**\(other.name)** \(other.status == .failed ? "hit an error" : "needs you")")) {
                Button("View") { openAgent(other.id) }.buttonStyle(.glass)
                    .accessibilityLabel("View \(other.name)")
            }
            .padding(.bottom, 6)
        }
    }

    private var timeline: some View {
        #if DEBUG
        let _ = CompanionConversationBuildProbe.record?(.timeline, target)
        #endif
        let rows = store.timelineRows(for: target)
        let viewport = readingViewport
        let window = CompanionTimelineWindow(rows: rows, limit: shownEntries, retaining: followLatest ? nil : readingBookmark.position.entryID)
        let entries = window.entries
        let stops = CompanionAssistantNavigation.targets(in: entries)
        return ScrollViewReader { proxy in
            ScrollView {
                // A plain stack of the newest entries, not a lazy one: it re-estimated row heights as you scrolled, adding
                // and dropping rows at the screen's edge pass after pass, and stalled the main thread (#188). A long reply
                // is a row per slice, so no row is far taller than the screen.
                // Each entry sets its own spacing, never negative.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 22) {
                        timelineHeader
                        if window.hiddenCount > 0 {
                            Button("Show earlier messages", systemImage: "arrow.up.circle") {
                                setFollowing(false, reason: .earlier)
                                readingViewport.isRestoring = true
                                readingViewport.restoreOffset = nil
                                shownEntries += CompanionTimelineWindow.pageSize
                            }
                                .font(.caption).frame(maxWidth: .infinity)
                                .accessibilityIdentifier("companion-show-earlier")
                        }
                    }
                    let pinnedID = store.pinnedApproval(for: target)?.id
                    let items = conversation.items
                    let hintRowID = CompanionContentReference.hintRowID(in: rows, richContentAvailable: store.richContentAvailable(for: target))
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 22) {
                            timelineEntry(entry, pinnedApprovalID: pinnedID, items: items)
                            if entry.endsRow && entry.rowID == hintRowID { CompanionContentHint() }
                        }
                        .padding(.top, entry.id == entries.first?.id && !hasTimelineHeader && window.hiddenCount == 0 ? 0 : entry.spacingBefore)
                        .id(entry.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: CompanionReadingFrames.self,
                                    value: [entry.id: geometry.frame(in: .named("companion-transcript-content"))])
                            }
                        }
                    }
                    // Include the transcript's bottom breathing room in the target. Otherwise scrollTo("latest")
                    // stops 24pt before the physical bottom, leaving the near-bottom state permanently ambiguous.
                    Color.clear.frame(height: 1).padding(.top, 22).padding(.bottom, 24).id("latest")
                }
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 14 : 22)
                .padding(.top, 24)
                .coordinateSpace(name: "companion-transcript-content")
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CompanionReadingFrames.self,
                            value: ["__content": CGRect(origin: .zero, size: geometry.size)])
                    }
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($readingScrollPosition)
            .defaultScrollAnchor(followLatest ? .bottom : .top, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Away from the latest, keep what you're reading still as rows resize. Anchored to the bottom there, a reply
            // taller than the screen moved the offset with each of the lazy stack's height estimates, which never settled.
            .defaultScrollAnchor(followLatest ? .bottom : .top, for: .sizeChanges)
            // Your dragging stops following and reaching the latest resumes it, rather than the end marker's appear and
            // disappear: under a reply taller than the screen the lazy stack kept realising and dropping the marker as it
            // re-estimated, and each flip re-rendered the conversation, which never settled (#180). Rows loading, the
            // keyboard and the composer resizing don't stop following.
            .onScrollPhaseChange { old, phase, context in
                cancelReadingRestoration(.scrollPhase, userAction: phase == .tracking || phase == .interacting || phase == .decelerating)
                traceScrollPhase(phase, metrics: Self.metrics(context.geometry))
                CompanionChatPerformance.scroll(target: target, isUserScrolling: phase == .tracking || phase == .interacting || phase == .decelerating)
                if phase == .tracking {
                    readingViewport.gesture.begin(at: Self.metrics(context.geometry).normalizedOffset)
                } else if phase == .interacting && old != .tracking {
                    readingViewport.gesture.begin(at: Self.metrics(context.geometry), last: readingViewport.metrics, beforeLast: readingViewport.previousMetrics)
                }
                readingViewport.isInteracting = phase == .interacting || phase == .decelerating
                if phase == .idle && canRecordReadingPosition && !readingViewport.preserveBookmarkUntilUserAction && !readingViewport.isRestoring {
                    let metrics = Self.metrics(context.geometry)
                    if readingViewport.gesture.movedUp(to: metrics.normalizedOffset) { setFollowing(false, reason: .gesture) }
                    readingViewport.gesture.end()
                    atLatest = metrics.isAtTrueBottom
                    if metrics.isAtTrueBottom { setFollowing(true, reason: .bottom) }
                    saveReadingPosition(metrics)
                }
            }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                AnnexTelemetry.shared.measurePerformance(.scrollGeometry, messageCount: conversation.items.count) {
                    guard new.containerSize.height > 0, new.contentSize.height > 0 else { return }
                    let metrics = Self.metrics(new)
                    let scrolledUp = Self.scrolledUp(from: old, to: new, beforeLast: readingViewport.previousMetrics)
                    traceUpwardGeometry(from: Self.metrics(old), to: metrics, recognized: scrolledUp)
                    readingViewport.previousMetrics = Self.metrics(old)
                    readingViewport.metrics = metrics
                    CompanionChatPerformance.viewport(target: target, messageCount: conversation.items.count, frames: readingViewport.frames,
                        offset: metrics.normalizedOffset, height: max(0, metrics.containerHeight - metrics.topInset - metrics.bottomInset))
                    atLatest = metrics.isAtTrueBottom
                    guard canRecordReadingPosition, !readingViewport.preserveBookmarkUntilUserAction else { return }
                    if readingViewport.isInteracting && readingViewport.gesture.movedUp(to: metrics.normalizedOffset) { setFollowing(false, reason: .gesture) }
                    if readingViewport.isRestoring {
                        guard let restoreOffset = readingViewport.restoreOffset,
                              abs((readingViewport.frameContentHeight ?? -1) - metrics.contentHeight) < 1 else { return }
                        let desired = min(restoreOffset, metrics.maximumOffset)
                        guard abs(metrics.normalizedOffset - desired) <= 1 else { return }
                        readingViewport.isRestoring = false
                        saveReadingPosition(metrics)
                    }
                    if metrics.isAtTrueBottom { setFollowing(true, reason: .bottom) }
                    else if !readingViewport.isInteracting && followLatest && scrolledUp { setFollowing(false, reason: .nativeUpward) }
                    // A native upward animation keeps its current bookmark even if a chunk's height preference lags.
                    // Otherwise restoration can undo the jump. Layout changes still restore the existing entry first.
                    if readingViewport.isInteracting || scrolledUp || abs((readingViewport.frameContentHeight ?? -1) - metrics.contentHeight) < 1 {
                        saveReadingPosition(metrics)
                    }
                }
            }
            .onPreferenceChange(CompanionReadingFrames.self) { rects in
                AnnexTelemetry.shared.measurePerformance(.readingPreference, messageCount: conversation.items.count) {
                    let frames = rects.filter { $0.key != "__content" }.mapValues { Double($0.minY)...Double($0.maxY) }
                    readingViewport.frames = frames
                    readingViewport.frameContentHeight = rects["__content"].map { Double($0.height) }
                    CompanionChatPerformance.viewport(target: target, messageCount: conversation.items.count, frames: frames,
                        offset: readingViewport.metrics?.normalizedOffset ?? 0, height: readingViewport.metrics.map { max(0, $0.containerHeight - $0.topInset - $0.bottomInset) } ?? 0)
                    guard !readingViewport.preserveBookmarkUntilUserAction,
                          readingViewport.restoration?.outcome != nil || readingViewport.restoration == nil else { return }
                    guard canRecordReadingPosition, !followLatest, !readingViewport.isInteracting, !frames.isEmpty else { return }
                    let saved = readingBookmark.position
                    if let entryID = saved.entryID, frames[entryID] == nil { return }
                    let offset = saved.restoredOffset(frames: frames)
                    if let metrics = readingViewport.metrics,
                       abs(metrics.contentHeight - (readingViewport.frameContentHeight ?? -1)) < 1,
                       abs(metrics.normalizedOffset - min(offset, metrics.maximumOffset)) <= 1 {
                        readingViewport.isRestoring = false
                        saveReadingPosition(metrics)
                    } else if readingViewport.isRestoring || abs(offset - (readingViewport.metrics?.normalizedOffset ?? offset)) > 1 {
                        readingViewport.isRestoring = true
                        readingViewport.restoreOffset = offset
                        readingScrollPosition.scrollTo(y: offset)
                    }
                }
            }
            .background { CompanionReadingTouchObserver { cancelReadingRestoration(.touch) }.allowsHitTesting(false).accessibilityHidden(true) }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("companion-transcript")
            // Simultaneous recognition leaves links, cards and text selection in charge
            // of their own gestures. Blank transcript space also ends editing.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissComposer() })
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    if !stops.isEmpty {
                        Button { jump(stops: stops, forward: false, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("Previous assistant message")
                            .accessibilityIdentifier("companion-previous-message")
                        Button { jump(stops: stops, forward: true, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Next assistant message")
                            .accessibilityIdentifier("companion-next-message")
                    }
                    if !atLatest && CompanionReadingPosition(followsLatest: followLatest).showsLatestButton(readingViewport.metrics ?? .init(offset: 0, contentHeight: 0, containerHeight: 0)) && !conversation.items.isEmpty {
                        Button {
                            setFollowing(true, reason: .latest)
                            readingBookmark.position.followsLatest = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) }
                        } label: { Label("Latest", systemImage: "arrow.down") }
                    }
                }
                .buttonStyle(.glass).controlSize(.small).padding(10)
            }
            .onChange(of: conversation.itemsRevision) { _, _ in
                if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            // Once the history is in, pin to the latest after the layout settles. On iOS 26.5 a chat that loads during a
            // navigation transition can keep the bottom anchor's estimate with no rows laid out, which looks empty.
            // Full history can also reset the offset with unchanged estimated dimensions. Reject that preceding
            // generation's geometry/bookmark writes until this task restores the saved choice and issues its anchor.
            .task(id: conversation.historyRevision) {
                let revision = conversation.historyRevision
                readingViewport.finishRestoration(.generation)
                readingViewport.preserveBookmarkUntilUserAction = false
                readingViewport.hasInitialized = false
                readingViewport.historyRevision = nil
                readingViewport.gesture.end()
                if readingBookmark.hasMounted { shownEntries = max(shownEntries, readingBookmark.position.shownEntries) }
                else {
                    readingBookmark.hasMounted = true
                    readingBookmark.position.shownEntries = shownEntries
                }
                if let entryID = readingBookmark.position.entryID, !rows.contains(where: { $0.contains(entryID: entryID) }) {
                    readingBookmark.position.entryID = nil
                }
                let saved = readingBookmark.position
                setFollowing(saved.followsLatest, reason: .restore)
                traceFollow(reason: .mount, previous: followLatest, next: followLatest)
                readingViewport.isRestoring = !saved.followsLatest && conversation.isLoaded
                readingViewport.restoreOffset = nil
                readingViewport.restoration = saved.followsLatest || !conversation.isLoaded ? nil
                    : CompanionReadingRestoration(revision: revision, startedAt: ProcessInfo.processInfo.systemUptime)
                let restorationID = readingViewport.restoration?.id
                guard conversation.isLoaded else { return }
                await Task.yield()
                guard !Task.isCancelled, conversation.historyRevision == revision else {
                    if readingViewport.restoration?.id == restorationID { readingViewport.finishRestoration(.taskCancelled) }
                    return
                }
                readingViewport.historyRevision = revision
                readingViewport.hasInitialized = true
                if readingViewport.restoration?.outcome != nil, let metrics = readingViewport.metrics { saveReadingPosition(metrics) }
                if saved.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
                else if let restorationID { await restoreReadingPosition(saved, id: restorationID) }
            }
            .onChange(of: followLatest) { _, follows in readingBookmark.position.followsLatest = follows }
            .onChange(of: shownEntries) { _, count in readingBookmark.position.shownEntries = count }
            .onDisappear {
                // TabView can deliver an old disappear after the new transcript's frame preferences. A managed tab
                // clears on the parent's visibility change instead, so that late callback cannot erase fresh geometry.
                if isVisible == nil { viewport.clearGeometry() }
            }

        }
    }

    /// Loading, errors, the archive link and the empty state, above the conversation's entries.
    @ViewBuilder private var timelineHeader: some View {
        // Refreshes of a transcript already on screen show in the composer instead.
        if conversation.isLoading && conversation.items.isEmpty { ProgressView("Loading conversation…").frame(maxWidth: .infinity).padding() }
        if let error = conversation.error {
            ContentUnavailableView {
                Label("Conversation unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            } description: { Text(error) } actions: {
                Button("Try again") { Task { await store.load(target, force: true) } }
            }
        }
        if conversation.hasEarlierMessages {
            Button("Read earlier messages in archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                .font(.caption).frame(maxWidth: .infinity)
        }
        if conversation.items.isEmpty && !conversation.isLoading && conversation.error == nil {
            ContentUnavailableView("No messages yet. Send one to start.", systemImage: "bubble.left.and.text.bubble.right")
                .accessibilityIdentifier("companion-empty-conversation")
        }
    }
    /// Loading and the empty state show only without entries, so they never sit above one.
    private var hasTimelineHeader: Bool { conversation.error != nil || conversation.hasEarlierMessages }

    private static func metrics(_ geometry: ScrollGeometry) -> CompanionScrollMetrics {
        .init(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
              availableHeight: geometry.containerSize.height, topInset: geometry.contentInsets.top,
              bottomInset: geometry.contentInsets.bottom)
    }
    private var canRecordReadingPosition: Bool {
        readingViewport.acceptsGeometry(historyRevision: conversation.historyRevision, isLoaded: conversation.isLoaded)
    }
    private func saveReadingPosition(_ metrics: CompanionScrollMetrics) {
        guard canRecordReadingPosition, !readingViewport.preserveBookmarkUntilUserAction else { return }
        readingBookmark.position.followsLatest = followLatest
        readingBookmark.position.capture(offset: metrics.normalizedOffset, frames: readingViewport.frames)
    }
    private func cancelReadingRestoration(_ outcome: CompanionReadingRestoration.Outcome, userAction: Bool = true) {
        guard (userAction && readingViewport.preserveBookmarkUntilUserAction) || readingViewport.isRestoring
                || (readingViewport.restoration != nil && readingViewport.restoration?.outcome == nil) else { return }
        readingViewport.finishRestoration(outcome)
        if userAction { readingViewport.preserveBookmarkUntilUserAction = false }
        // A touch owns the current position immediately; a later frame preference must
        // not resurrect the old bookmark while the user's gesture is getting started.
        if let metrics = readingViewport.metrics { saveReadingPosition(metrics) }
    }

    private func restoreReadingPosition(_ saved: CompanionReadingPosition, id: UUID) async {
        while readingViewport.restoration?.id == id {
            guard !Task.isCancelled else { readingViewport.finishRestoration(.taskCancelled); return }
            guard var attempt = readingViewport.restoration, attempt.outcome == nil else { return }
            let hasEntry = saved.entryID == nil || readingViewport.frames[saved.entryID ?? ""] != nil
            let step = attempt.next(now: ProcessInfo.processInfo.systemUptime, revision: conversation.historyRevision,
                followsLatest: followLatest, metrics: readingViewport.metrics, frameContentHeight: readingViewport.frameContentHeight,
                proposedOffset: hasEntry ? saved.restoredOffset(frames: readingViewport.frames) : nil)
            readingViewport.restoration = attempt
            switch step {
            case .finish(let outcome):
                readingViewport.finishRestoration(outcome)
                if outcome == .arrived, let metrics = readingViewport.metrics { saveReadingPosition(metrics) }
                return
            case .scroll(let offset):
                readingViewport.restoreOffset = offset
                #if DEBUG
                let deliver = CompanionReadingRestoreProbe.deliver?(attempt.revision, attempt.attempts, offset) ?? true
                if deliver { readingScrollPosition.scrollTo(y: offset) }
                #else
                readingScrollPosition.scrollTo(y: offset)
                #endif
            case .wait: break
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch {
                if readingViewport.restoration?.id == id { readingViewport.finishRestoration(.taskCancelled) }
                return
            }
        }
    }

    private func jump(stops: [String], forward: Bool, proxy: ScrollViewProxy) {
        let offset = readingViewport.metrics?.normalizedOffset ?? readingBookmark.position.offset
        guard let id = CompanionAssistantNavigation.destination(in: stops, frames: readingViewport.frames,
                                                                viewportTop: offset, forward: forward) else {
            if !forward { setFollowing(false, reason: .messageJump); shownEntries += CompanionTimelineWindow.pageSize }
            return
        }
        setFollowing(false, reason: .messageJump)
        proxy.scrollTo(id, anchor: .top)
    }

    private enum FollowReason: String { case earlier, gesture, bottom, nativeUpward, latest, restore, messageJump, mount }

    private func setFollowing(_ follows: Bool, reason: FollowReason) {
        if reason == .bottom && readingViewport.preserveBookmarkUntilUserAction { return }
        if reason != .restore && reason != .mount { cancelReadingRestoration(.navigation, userAction: reason != .bottom) }
        let previous = followLatest
        followLatest = follows
        if previous != follows { traceFollow(reason: reason, previous: previous, next: follows) }
    }

    /// Opt-in preview diagnostics for CI. Closed reasons and numbers only; never draft or transcript text.
    private func traceFollow(reason: FollowReason, previous: Bool, next: Bool) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"), arguments.contains("--companion-preview-follow-trace") else { return }
        let metrics = readingViewport.metrics
        NSLog("%@", "CHAT_FOLLOW reason=\(reason.rawValue) from=\(previous ? 1 : 0) to=\(next ? 1 : 0) userPositioned=\(readingScrollPosition.isPositionedByUser ? 1 : 0) interacting=\(readingViewport.isInteracting ? 1 : 0) offset=\(metrics?.normalizedOffset ?? -1) contentHeight=\(metrics?.contentHeight ?? -1) containerHeight=\(metrics?.containerHeight ?? -1) messageCount=\(conversation.items.count)")
        #endif
    }

    private func traceUpwardGeometry(from old: CompanionScrollMetrics, to new: CompanionScrollMetrics, recognized: Bool) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"), arguments.contains("--companion-preview-follow-trace"),
              new.normalizedOffset < old.normalizedOffset else { return }
        let prior = readingViewport.previousMetrics
        NSLog("%@", "CHAT_UP oldOffset=\(old.normalizedOffset) newOffset=\(new.normalizedOffset) oldContent=\(old.contentHeight) newContent=\(new.contentHeight) oldContainer=\(old.containerHeight) newContainer=\(new.containerHeight) oldTopInset=\(old.topInset) newTopInset=\(new.topInset) oldBottomInset=\(old.bottomInset) newBottomInset=\(new.bottomInset) priorOffset=\(prior?.normalizedOffset ?? -1) priorContent=\(prior?.contentHeight ?? -1) recognized=\(recognized ? 1 : 0) following=\(followLatest ? 1 : 0) userPositioned=\(readingScrollPosition.isPositionedByUser ? 1 : 0) interacting=\(readingViewport.isInteracting ? 1 : 0) initialized=\(readingViewport.hasInitialized ? 1 : 0) historyReady=\(canRecordReadingPosition ? 1 : 0) restoring=\(readingViewport.isRestoring ? 1 : 0) messageCount=\(conversation.items.count)")
        #endif
    }

    private func traceScrollPhase(_ phase: ScrollPhase, metrics: CompanionScrollMetrics) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"), arguments.contains("--companion-preview-follow-trace") else { return }
        let value: Int
        switch phase {
        case .idle: value = 0
        case .tracking: value = 1
        case .interacting: value = 2
        case .decelerating: value = 3
        case .animating: value = 4
        @unknown default: value = 5
        }
        NSLog("%@", "CHAT_PHASE phase=\(value) following=\(followLatest ? 1 : 0) userPositioned=\(readingScrollPosition.isPositionedByUser ? 1 : 0) offset=\(metrics.normalizedOffset)")
        #endif
    }

    /// Pause on the first native upward sample, before another chunk can cancel
    /// the jump. Width/inset/keyboard changes and shrinking content are excluded.
    private static func scrolledUp(from old: ScrollGeometry, to new: ScrollGeometry, beforeLast: CompanionScrollMetrics?) -> Bool {
        old.containerSize == new.containerSize && metrics(new).didScrollUp(from: metrics(old), beforeLast: beforeLast)
    }

    @ViewBuilder private func timelineEntry(_ entry: CompanionTimelineEntry, pinnedApprovalID: String?, items: [CompanionTimelineItem]) -> some View {
        switch entry {
        case .row(let row): timelineRow(row, pinnedApprovalID: pinnedApprovalID, items: items)
        case .slice(let message, let slice):
            messageView(message, slice: slice)
            if slice.isLast && message.role == .assistant {
                CompanionContentLinks(references: CompanionContentReference.references(in: .message(message)))
            }
        }
    }

    private func messageView(_ message: CompanionMessage, slice: CompanionMessageSlice? = nil) -> some View {
        CompanionMessageView(message: message, canRetry: store.canSend(target), retry: {
            Task { await store.retry(messageID: message.id, target: target) }
        }, canRemoveQueued: store.canOperate(target) && agent.capabilities.contains(.removeQueued) && !store.pendingCommands.contains(target),
           removeQueued: agent.capabilities.contains(.removeQueued) ? { Task { await store.removeQueuedMessage(message.id, target: target) } } : nil,
           slice: slice, expansion: store.transcriptExpansion(for: target)).equatable()
    }

    @ViewBuilder private func timelineRow(_ row: CompanionTimelineRow, pinnedApprovalID: String?, items: [CompanionTimelineItem]) -> some View {
        switch row {
        case .item(let item): timelineItem(item, pinnedApprovalID: pinnedApprovalID, items: items)
        case .tools(let tools): CompanionToolGroupCard(tools: tools, store: store, target: target)
        case .activity(let parts): CompanionActivityCard(parts: parts, expansion: store.transcriptExpansion(for: target)).equatable()
        case .routed(let message, let index):
            CompanionRoutedFragmentView(message: message, index: index, expansion: store.transcriptExpansion(for: target))
        }
    }

    @ViewBuilder private func timelineItem(_ item: CompanionTimelineItem, pinnedApprovalID: String?, items: [CompanionTimelineItem]) -> some View {
        switch item {
        case .message(let message):
            messageView(message)
            if message.role == .assistant {
                CompanionContentLinks(references: CompanionContentReference.references(in: item))
            }
        case .tool(let tool):
            CompanionToolCard(tool: tool, expansion: store.transcriptExpansion(for: target).state(key: "tool:\(tool.id)"))
            CompanionContentLinks(references: CompanionContentReference.references(in: item))
        case .approval(let approval):
            CompanionApprovalCard(approval: approval, queuePosition: CompanionChatActivity.queuePosition(of: approval, in: items),
                                  canRespond: canRespond, actionsArePinned: approval.id == pinnedApprovalID,
                                  persistentApprovals: store.canAnswerPersistentApprovals(target)) { option in
                Task { await store.respond(approval, option: option, target: target) }
            }
        case .question(let question):
            CompanionQuestionCard(question: question, canRespond: store.canOperate(target) && agent.capabilities.contains(.answer) && !store.pendingCommands.contains(target)) { answers in
                Task { await store.answer(question, answers: answers, target: target) }
            }
        case .notice(_, let text):
            Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }

    private func focusComposer() { composerFocusRequests &+= 1 }

    private func dismissComposer() {
        composerDismissals &+= 1
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Messages only reach chat-runtime agents (the desktop answers `not_chat` otherwise).
    private var terminalNotice: some View {
        Label("\(agent.name) runs in a terminal on your desktop. Open it there to work with it.", systemImage: "terminal")
            .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 16).padding(.vertical, 10)
    }


}

/// Context fill as a small ring with its percentage, like the desktop's usage ring. Hot from 90%.
struct CompanionContextRing: View {
    let percent: Int
    @Environment(\.companionPalette) private var palette
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 11
    var body: some View {
        let hot = percent >= 90
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(hot ? Color(palette.error) : Color(palette.secondaryLabel), style: .init(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            Text("\(percent)%").font(.caption.monospacedDigit()).foregroundStyle(hot ? Color(palette.error) : Color(palette.secondaryLabel))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent)% full")
        .accessibilityIdentifier("companion-context-usage")
    }
}

private struct CompanionReadingFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        AnnexTelemetry.shared.measurePerformance(.readingFrameReduce) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }
}

#if DEBUG
@MainActor enum CompanionReadingRestoreProbe {
    /// Synthetic command loss only. Never installed outside bounded hosted tests.
    static var deliver: ((UUID, Int, Double) -> Bool)?
}
#endif
