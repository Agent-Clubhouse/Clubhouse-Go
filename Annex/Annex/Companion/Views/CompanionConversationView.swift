import SwiftUI
import ClubhouseTransport

struct CompanionConversationView: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    /// Review keeps neighbouring chats alive; only the one on screen puts its menu in the navigation bar.
    var showsActions = true
    /// A parent-managed tab supplies visibility; navigation destinations use their normal appear/disappear lifecycle.
    var isVisible: Bool? = nil
    /// Review's selected page owns the same identity control, with its place in the pager.
    var reviewPosition: String? = nil
    #if DEBUG
    /// Initial value only for the recovery component's private State; normal callers leave it false.
    var initiallyShowsRecoveryDetails = false
    #endif
    @State private var followLatest = true
    @State private var atLatest = true
    @State private var readingScrollPosition = ScrollPosition(edge: .bottom)
    @State private var confirmCancel = false
    @State private var confirmSleep = false
    @State private var showArchive = false
    @State private var showContextSettings = false
    @State private var showHeaderDetails = false
    @State private var headerDetailsLackRoom = false
    @State private var keyboardVisible = false
    @ScaledMetric(relativeTo: .body) private var navigationClearance: CGFloat = 40
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
    private var recoveryStatus: CompanionRecoveryStatus {
        .init(connection: connection, isLoading: conversation.isLoading,
              requiresResync: conversation.requiresResync, error: conversation.error)
    }
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
        // Build the transcript outside the geometry callback: native editor layout can reevaluate
        // that callback without changing conversation data. Header measurement still uses its live geometry.
        let conversationContent = VStack(spacing: 0) {
            if store.justCreated == target { CompanionCreatedAgentNotice(store: store, agent: agent) { focusComposer() } }
            connectionBanner
            if store.hasPendingProviderAction(target) {
                Text("A provider action is awaiting confirmation. Open Agent settings to check its result.")
                    .font(.subheadline).padding(.horizontal)
            }
            if store.sleepRequests.contains(target), !(agent.isDispatcher && store.host(for: target)?.dispatcher?.mcpOff != nil) {
                HStack {
                    CompanionSleepAction(store: store, target: target)
                }
                .font(.subheadline).padding(.horizontal)
            }
            if let error = store.operationErrors[target] {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                            .accessibilityIdentifier("companion-operation-error")
                        if let other = store.otherMachineTarget(for: target), let machine = store.host(for: other)?.name {
                            Button("Open on \(machine)", systemImage: "arrow.up.right.square") { store.openOnOtherMachine(from: target) }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { store.dismissError(for: target) }.labelStyle(.iconOnly)
                }
                .padding().background(Color(palette.warning).opacity(0.12))
                .accessibilityElement(children: .contain)
            }
            if showsAgentTerminal { CompanionAgentTerminalPane(store: store, target: target) }
            else {
                timeline.companionContentPreviews(store: store, target: target)
                    .environment(\.companionSenderResolver, CompanionSenderResolver(host: store.host(for: target), hosts: store.hosts))
            }
        }
        .companionBackground()
        // The bottom bar reserves its real size before this boundary observes the safe region.
        // This boundary stays mounted while disclosure/focus/status changes.
        return GeometryReader { available in
        GeometryReader { geometry in
        conversationContent
        // Bars, not insets: the transcript gets the system scroll-edge effect under the glass instead of showing through.
        .safeAreaBar(edge: .top, spacing: 0) {
            // The photo's name pill hangs just below the bar, like Messages; status rows and banners start under it.
            // The transcript still scrolls beneath.
            CompanionConversationHeaderBarLayout(
                residualHeight: geometry.size.height,
                showsDetails: showHeaderDetails
            ) {
                // Both slots are stable, including the empty disclosure/banner cases.
                VStack(spacing: 0) {
                    // Too short for a usable disclosure (landscape with the keyboard up): keep the choice, show nothing,
                    // so neither the screen nor VoiceOver has details squeezed behind the bar or composer.
                    if showHeaderDetails, geometry.size.height >= CompanionConversationHeaderBarLayout.minimumRoomForDetails {
                        CompanionConversationDetailsViewport(agent: agent, contextName: contextName)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
                VStack(spacing: 0) { otherAgentBanner }
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, Self.headerPillClearance)
        }
        }
        // VoiceOver says when an expanded disclosure is hidden for lack of room, rather than "expanded".
        .onGeometryChange(for: Bool.self) { $0.size.height < CompanionConversationHeaderBarLayout.minimumRoomForDetails } action: {
            headerDetailsLackRoom = $0
        }
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsActions {
                // Both capsules draw their own glass over an opaque card, so the bar's shared glass stays off them.
                ToolbarItem(placement: .principal) {
                    CompanionConversationIdentityButton(agent: agent, isExpanded: $showHeaderDetails,
                                                        accessibilityLabel: headerAccessibilityLabel, reviewPosition: reviewPosition,
                                                        detailsLackRoom: headerDetailsLackRoom)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { contextButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh conversation", systemImage: "arrow.clockwise") { Task { await store.load(target, force: true) } }
                        Button("Conversation archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                        Button("Context and plan limits", systemImage: "chart.pie") { showContextSettings = true }
                            .accessibilityIdentifier("companion-context-settings-menu")
                        if let agentSettings { CompanionAgentMenuItems(target: target, actions: agentSettings) }
                        CompanionSleepAction(store: store, target: target) { confirmSleep = true }
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
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if store.grantRequests(for: target).isEmpty {
                composerBar(maximumHeight: max(44, available.size.height - Self.headerPillClearance - 44),
                            compactHeight: available.size.height < 360)
            } else {
                CompanionConversationGrantFooter(store: store, target: target,
                    maximumHeight: max(44, available.size.height - Self.headerPillClearance)) {
                    composerBar(compactHeight: available.size.height < 360)
                }
            }
        }
        .sheet(isPresented: $showContextSettings) { CompanionConversationUsageSheet(store: store, target: target) }
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
        // System keyboard visibility is independent of draft/selection observation in the composer.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if !keyboardVisible { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardVisible { keyboardVisible = false }
        }
        .onChange(of: connection) { _, current in
            if current.canOperate && conversation.requiresResync && !conversation.isLoading {
                Task { await store.load(target, force: true) }
            }
        }
        .alert("Interrupt this turn?", isPresented: $confirmCancel) {
            Button("Interrupt turn", role: .destructive) { Task { await store.cancel(target) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current turn will be interrupted. You can then send a new direction in the same conversation.") }
        .alert("Request no longer waiting", isPresented: Binding(get: { store.grantRequestNotice != nil }, set: { if !$0 { store.grantRequestNotice = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(store.grantRequestNotice ?? "") }
        .modifier(CompanionSleepConfirmation(store: store, target: target, isPresented: $confirmSleep))
        }
        }
    }

    @ViewBuilder private func composerBar(maximumHeight: CGFloat = .infinity, compactHeight: Bool) -> some View {
        if agent.runsInTerminal { if !showsAgentTerminal { terminalNotice } } else {
            CompanionComposerLayout(spacing: 0, maximumHeight: maximumHeight) {
                activityLine
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                CompanionConversationComposer(store: store, agent: agent, memory: composerMemory.value,
                    focusRequests: composerFocusRequests, confirmCancel: $confirmCancel, dismissals: composerDismissals)
            }
            .environment(\.companionComposerCompactHeight, compactHeight)
            .modifier(CompanionOfferedWidth())
        }
    }

    /// How far the identity's name pill hangs below the navigation bar, at most.
    private static let headerPillClearance: CGFloat = 8

    private var compactAccessibilityHeader: Bool { dynamicTypeSize.isAccessibilitySize && keyboardVisible }

    private var headerAccessibilityLabel: String {
        [agent.displayName, contextName, agent.status.label,
         (agent.displayedChatAccess?.label
          ?? (agent.freeAgentMode ? CompanionFreeAgentMode.title : nil)).map { "Access: \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private var contextButton: some View {
        Button { showContextSettings = true } label: {
            HStack(spacing: 0) {
                if let percent = agent.contextUsage?.percent { CompanionContextRing(percent: percent) }
                else { Image(systemName: "chart.pie").font(.caption) }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .companionCardGlass(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Context and plan limits")
        .accessibilityValue(agent.contextUsage?.percent.map { "Latest reported context: \($0)% full" } ?? "Context usage unknown")
        .accessibilityHint("Opens context settings and plan limits by desktop")
        .accessibilityIdentifier(agent.contextUsage?.percent == nil ? "companion-context-settings" : "companion-context-usage")
    }

    /// A slim worker/activity footer stays above the composer; idle chats reserve no footer line.
    private var activityLine: some View {
        let ticking = agent.status == .working && agent.turnStartedAt != nil
        return TimelineView(.periodic(from: .now, by: ticking ? 1 : 60)) { context in
            if let activity = CompanionChatActivity.line(status: agent.status, turnStartedAt: agent.turnStartedAt, items: conversation.items, now: context.date) {
                HStack(spacing: 4) {
                    Text(agent.displayName).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                    Text("·")
                    Text(activity)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(Color(palette.secondaryLabel))
                // One element for VoiceOver: who is working and on what, without the separator.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(agent.displayName), \(activity)")
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("companion-chat-activity")
            }
        }
    }

    private var contextName: String {
        guard let host = store.host(for: target) else { return "Desktop unavailable" }
        // The Dispatcher has no project; its own name stands in.
        return "\(host.name) / \(host.placeName(for: target) ?? "Project")"
    }

    /// The production callback, also invoked directly by hosted routing tests. No presentation state is exposed.
    var recoveryRetryAction: (CompanionRecoveryStatus.RetryAction) -> Void {
        // A retained page's presented action belongs to that page, even if selection changes before its Task runs.
        let presentedTarget = target
        let presentedStore = store
        return { action in
            Task {
                switch action {
                case .reconnect: await presentedStore.reconnect(hostID: presentedTarget.hostID)
                case .refreshConversation: await presentedStore.load(presentedTarget, force: true)
                }
            }
        }
    }

    private var connectionBanner: some View {
        let presentedTarget = target
        #if DEBUG
        let banner = CompanionRecoveryStatusView(status: recoveryStatus, initiallyShowsDetails: initiallyShowsRecoveryDetails,
                                                 onRetry: recoveryRetryAction)
        #else
        let banner = CompanionRecoveryStatusView(status: recoveryStatus, onRetry: recoveryRetryAction)
        #endif
        // Reset only recovery presentation when a retained page becomes inactive; never reset transcript identity.
        return banner.id(CompanionRecoveryPresentationID(target: presentedTarget, isActive: showsActions && isVisible != false))
    }

    /// While the app is open there are no system banners, so another agent that needs you shows here.
    @ViewBuilder private var otherAgentBanner: some View {
        // Compare by agent, not list entry: a desktop can list one agent under more than one project.
        if let other = store.allAgents.first(where: { $0.status.needsYou && ($0.id.agentID != target.agentID || $0.id.hostID != target.hostID) }) {
            if compactAccessibilityHeader {
                // Keep the other chat actionable without letting its banner consume this chat's viewport.
                Button { openAgent(other.id) } label: {
                    Label("\(other.name) \(other.status == .failed ? "hit an error" : "needs you")", systemImage: other.status.symbol)
                        .font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule)
                .accessibilityLabel("View \(other.name), \(other.status == .failed ? "hit an error" : "needs you")")
                .padding(.horizontal, 16).padding(.bottom, 6)
            } else {
                CompanionGlassBanner(systemImage: other.status.symbol,
                                     text: Text("**\(other.name)** \(other.status == .failed ? "hit an error" : "needs you")")) {
                    Button("View") { openAgent(other.id) }.buttonStyle(.glass)
                        .accessibilityLabel("View \(other.name)")
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var showsLatestControl: Bool {
        !atLatest && CompanionReadingPosition(followsLatest: followLatest).showsLatestButton(
            readingViewport.metrics ?? CompanionScrollMetrics(offset: 0, contentHeight: 0, containerHeight: 0)
        ) && !conversation.items.isEmpty
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
        let horizontalPadding: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 22
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
                    CompanionTranscriptEndSpacer(horizontalPadding: horizontalPadding, navigationClearance: navigationClearance) {
                        !stops.isEmpty || showsLatestControl
                    }
                    .id("latest")
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                .coordinateSpace(name: "companion-transcript-content")
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CompanionReadingFrames.self,
                            value: ["__content": CGRect(origin: .zero, size: geometry.size)])
                    }
                    CompanionNativeScrollTopObserver(requested: { nativeScrollToTopRequested() },
                        pending: { readingViewport.isScrollingToTop },
                        repaired: { traceFollow(reason: .nativeTopRepair, previous: followLatest, next: followLatest) })
                        .allowsHitTesting(false).accessibilityHidden(true)
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
                readingScrollPhaseChanged(from: old, to: phase, metrics: Self.metrics(context.geometry))
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
                    if readingViewport.isScrollingToTop {
                        guard metrics.normalizedOffset <= 1 else { return }
                        readingViewport.isScrollingToTop = false
                    }
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
                    guard !readingViewport.isScrollingToTop, !readingViewport.preserveBookmarkUntilUserAction,
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
            .background {
                CompanionReadingTouchObserver {
                    cancelNativeScrollToTop()
                    cancelReadingRestoration(.touch)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            // Soft at the top, like Messages: the transcript scrolls under the floating header instead of meeting a band.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("companion-transcript")
            // Simultaneous recognition leaves links, cards and text selection in charge
            // of their own gestures. Blank transcript space also ends editing.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissComposer() })
            .overlay(alignment: .bottomTrailing) {
                GlassEffectContainer {
                    HStack(spacing: 8) {
                        if !stops.isEmpty {
                            Button { jump(stops: stops, forward: false, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                                .accessibilityLabel("Previous assistant message")
                                .accessibilityIdentifier("companion-previous-message")
                                .buttonBorderShape(.circle)
                            Button { jump(stops: stops, forward: true, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                                .accessibilityLabel("Next assistant message")
                                .accessibilityIdentifier("companion-next-message")
                                .buttonBorderShape(.circle)
                        }
                        if showsLatestControl {
                            Button {
                                setFollowing(true, reason: .latest)
                                readingBookmark.position.followsLatest = true
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) }
                            } label: { Label("Latest", systemImage: "arrow.down") }
                        }
                    }
                    .buttonStyle(.glass).controlSize(.large)
                }.padding(8)
            }
            .onChange(of: conversation.itemsRevision) { _, _ in
                if followLatest && !readingViewport.isScrollingToTop {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
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
                if readingViewport.restoration?.outcome != nil, let metrics = readingViewport.metrics {
                    saveReadingPosition(metrics)
                }
                if saved.followsLatest && followLatest && !readingViewport.isScrollingToTop {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
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

    /// Recovery owns loading/errors above the transcript; archive and settled empty-state content stay here.
    @ViewBuilder private var timelineHeader: some View {
        if conversation.hasEarlierMessages {
            Button("Read earlier messages in archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                .font(.caption).frame(maxWidth: .infinity)
        }
        if conversation.items.isEmpty && !recoveryStatus.isVisible {
            ContentUnavailableView("No messages yet. Send one to start.", systemImage: "bubble.left.and.text.bubble.right")
                .accessibilityIdentifier("companion-empty-conversation")
        }
    }
    /// The settled empty state has no entries below it; only the archive link precedes actual entries.
    private var hasTimelineHeader: Bool { conversation.hasEarlierMessages }

    private static func metrics(_ geometry: ScrollGeometry) -> CompanionScrollMetrics {
        .init(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
              availableHeight: geometry.containerSize.height, topInset: geometry.contentInsets.top,
              bottomInset: geometry.contentInsets.bottom)
    }
    private var canRecordReadingPosition: Bool {
        readingViewport.acceptsGeometry(historyRevision: conversation.historyRevision, isLoaded: conversation.isLoaded)
    }
    private func readingScrollPhaseChanged(from old: ScrollPhase, to phase: ScrollPhase, metrics: CompanionScrollMetrics) {
        let userPhase = phase == .tracking || phase == .interacting || phase == .decelerating
        if userPhase {
            cancelNativeScrollToTop()
            cancelReadingRestoration(.scrollPhase)
        }
        traceScrollPhase(phase, metrics: metrics)
        CompanionChatPerformance.scroll(target: target, isUserScrolling: userPhase)
        if phase == .tracking {
            readingViewport.gesture.begin(at: metrics.normalizedOffset)
        } else if phase == .interacting && old != .tracking {
            readingViewport.gesture.begin(at: metrics, last: readingViewport.metrics, beforeLast: readingViewport.previousMetrics)
        }
        readingViewport.isInteracting = phase == .interacting || phase == .decelerating
        if phase == .idle {
            defer { readingViewport.gesture.end() }
            // A system animation or settling to idle is not a user's reading choice.
            guard readingViewport.gesture.hasStarted, canRecordReadingPosition,
                  !readingViewport.preserveBookmarkUntilUserAction, !readingViewport.isRestoring else { return }
            if readingViewport.gesture.movedUp(to: metrics.normalizedOffset) { setFollowing(false, reason: .gesture) }
            atLatest = metrics.isAtTrueBottom
            if metrics.isAtTrueBottom { setFollowing(true, reason: .bottom) }
            saveReadingPosition(metrics)
        }
    }

    private func saveReadingPosition(_ metrics: CompanionScrollMetrics) {
        guard canRecordReadingPosition, !readingViewport.preserveBookmarkUntilUserAction,
              !readingViewport.isScrollingToTop,
              readingViewport.restoration == nil || readingViewport.restoration?.outcome != nil else { return }
        readingBookmark.position.followsLatest = followLatest
        readingBookmark.position.capture(offset: metrics.normalizedOffset, frames: readingViewport.frames)
    }
    private func cancelReadingRestoration(_ outcome: CompanionReadingRestoration.Outcome) {
        guard readingViewport.preserveBookmarkUntilUserAction || readingViewport.isRestoring
                || (readingViewport.restoration != nil && readingViewport.restoration?.outcome == nil) else { return }
        readingViewport.finishRestoration(outcome)
        readingViewport.preserveBookmarkUntilUserAction = false
        // A touch owns the current position immediately; a later frame preference must
        // not resurrect the old bookmark while the user's gesture is getting started.
        // Navigation cancels delivery, but its pre-arrival geometry is not a new bookmark.
        if (outcome == .touch || outcome == .scrollPhase), let metrics = readingViewport.metrics { saveReadingPosition(metrics) }
    }

    private func restoreReadingPosition(_ saved: CompanionReadingPosition, id: UUID) async {
        while readingViewport.restoration?.id == id {
            guard !Task.isCancelled else { readingViewport.finishRestoration(.taskCancelled); return }
            guard var attempt = readingViewport.restoration, attempt.outcome == nil else { return }
            guard !readingViewport.isScrollingToTop else { readingViewport.finishRestoration(.navigation); return }
            let hasEntry = saved.entryID == nil || readingViewport.frames[saved.entryID ?? ""] != nil
            let step = attempt.next(now: ProcessInfo.processInfo.systemUptime, revision: conversation.historyRevision,
                followsLatest: followLatest, metrics: readingViewport.metrics, frameContentHeight: readingViewport.frameContentHeight,
                proposedOffset: hasEntry ? saved.restoredOffset(frames: readingViewport.frames) : nil)
            readingViewport.restoration = attempt
            switch step {
            case .finish(let outcome):
                readingViewport.finishRestoration(outcome)
                if outcome == .arrived, let metrics = readingViewport.metrics {
                    if metrics.isAtTrueBottom { setFollowing(true, reason: .bottom) }
                    saveReadingPosition(metrics)
                }
                return
            case .scroll(let offset):
                readingViewport.isRestoring = true
                readingViewport.restoreOffset = offset
                #if DEBUG
                var priorPhase = ScrollPhase.idle
                let deliver = CompanionReadingRestoreProbe.deliver?(attempt.revision, attempt.attempts, offset, { phase in
                    if let metrics = readingViewport.metrics { readingScrollPhaseChanged(from: priorPhase, to: phase, metrics: metrics) }
                    priorPhase = phase
                }) ?? true
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

    private func nativeScrollToTopRequested() {
        setFollowing(false, reason: .nativeTop)
        readingViewport.isScrollingToTop = true
        readingBookmark.position.followsLatest = false
        readingBookmark.position.capture(offset: 0, frames: readingViewport.frames)
    }

    private func cancelNativeScrollToTop() {
        guard readingViewport.isScrollingToTop else { return }
        readingViewport.isScrollingToTop = false
        if let metrics = readingViewport.metrics { saveReadingPosition(metrics) }
    }

    private enum FollowReason: String { case earlier, gesture, bottom, nativeTop, nativeTopRepair, nativeUpward, latest, restore, messageJump, mount }

    private func setFollowing(_ follows: Bool, reason: FollowReason) {
        if reason == .bottom {
            guard !readingViewport.isScrollingToTop, !readingViewport.preserveBookmarkUntilUserAction, !readingViewport.isRestoring,
                  readingViewport.restoration == nil || readingViewport.restoration?.outcome != nil else { return }
        } else if reason != .restore && reason != .mount {
            cancelNativeScrollToTop()
            cancelReadingRestoration(.navigation)
        }
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
            Text(text).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("companion-notice-\(item.id)")
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
            Text("\(percent)%").font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(hot ? Color(palette.error) : Color(palette.secondaryLabel))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent)% full")
        .accessibilityIdentifier("companion-context-usage")
    }
}

private struct CompanionTranscriptEndSpacer: View {
    let horizontalPadding: CGFloat
    let navigationClearance: CGFloat
    let showsControls: @MainActor () -> Bool

    var body: some View {
        CompanionTranscriptEndLayout(horizontalPadding: horizontalPadding, navigationClearance: navigationClearance,
                                     showsControls: showsControls()) {
            Color.clear.frame(height: 1).padding(.top, 22)
        }
    }
}

/// Restore the transcript's outer insets when applying the window-width breakpoint.
/// Choosing during measurement avoids a post-layout compact-mode transition.
private struct CompanionTranscriptEndLayout: Layout {
    let horizontalPadding: CGFloat
    let navigationClearance: CGFloat
    let showsControls: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let marker = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        let compact = proposal.width.map { $0 > 0 && $0 + horizontalPadding * 2 < 390 } ?? false
        let clearance = compact ? (showsControls ? max(0, navigationClearance - 8) : 0) : navigationClearance
        return CGSize(width: marker.width, height: marker.height + clearance)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Reports exactly the offered width. The bottom bar's measured width carried floating-point noise
/// (402.00000000000017), which rounded up a pixel and widened the whole conversation; the transcript then
/// wrapped at a different width from its scroll content, and reading restoration never saw them agree.
private struct CompanionOfferedWidth: ViewModifier {
    func body(content: Content) -> some View { OfferedWidthLayout { content } }
    private struct OfferedWidthLayout: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let size = subviews.first?.sizeThatFits(proposal) ?? .zero
            return CGSize(width: proposal.width ?? size.width, height: size.height)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

private struct CompanionRecoveryPresentationID: Hashable {
    let target: CompanionTarget
    let isActive: Bool
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
    /// Synthetic command loss/phase injection in bounded hosted tests and the opt-in UI fixture.
    static var deliver: ((UUID, Int, Double, (ScrollPhase) -> Void) -> Bool)?
}
#endif
