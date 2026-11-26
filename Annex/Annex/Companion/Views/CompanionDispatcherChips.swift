import SwiftUI
import ClubhouseTransport

/// When the Dispatcher's turn takes the chips' reading space, and how the collapsed stack draws.
enum CompanionDispatcherTurn {
    /// The whole turn, including a permission or question in the middle of it, so the chips and the reader's Show
    /// chips choice don't change at every prompt (#537). `turnStartedAt` isn't used: the desktop doesn't always send
    /// a turn time, and a reconnect drops it unless the agent is working.
    static func inTurn(agent: CompanionAgent?, isStreaming: Bool) -> Bool {
        isStreaming || [.working, .approval, .waiting].contains(agent?.status)
    }

    /// A desktop that is offline or failed has no live turn, as on Home. A blip keeps it: reconnecting,
    /// synchronizing, and connecting too, because every fresh `connect()` (Retry, returning to the app) passes
    /// through `.connecting` with the turn already known, sometimes straight from `.reconnecting`.
    static func isLive(_ connection: CompanionConnection?) -> Bool {
        switch connection {
        case nil, .offline, .failed: false
        case .connecting, .reconnecting, .synchronizing, .connected: true
        }
    }

    static func collapsesChips(agent: CompanionAgent?, isStreaming: Bool, connection: CompanionConnection?) -> Bool {
        isLive(connection) && inTurn(agent: agent, isStreaming: isStreaming)
    }

    /// A gap ring separates overlapping avatars; a lone avatar has nothing to separate.
    static func separatesAvatars(count: Int) -> Bool { count > 1 }
}

/// Dispatch has no All scope or machine labels. Home/project desktop-chip APIs remain unchanged.
struct CompanionDispatcherSwitcher<Content: View>: View {
    let desktops: [CompanionDispatcherDesktop]
    let hosts: [CompanionHost]
    let selectedHostID: String?
    let replies: Set<String>
    /// The Dispatcher's turn; its edges reset the reader's Show chips choice.
    let isWorking: Bool
    /// Whether that turn is live. Losing the desktop shows the chips without touching the reader's choice.
    let isLive: Bool
    var select: (String) -> Void
    var openSettings: () -> Void
    let content: Content
    @State private var expandedWhileWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(desktops: [CompanionDispatcherDesktop], hosts: [CompanionHost], selectedHostID: String?,
         replies: Set<String>, isWorking: Bool, isLive: Bool, select: @escaping (String) -> Void,
         openSettings: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.desktops = desktops
        self.hosts = hosts
        self.selectedHostID = selectedHostID
        self.replies = replies
        self.isWorking = isWorking
        self.isLive = isLive
        self.select = select
        self.openSettings = openSettings
        self.content = content()
    }

    private var collapsible: Bool { isWorking && isLive }
    private var collapsed: Bool { collapsible && !expandedWhileWorking }
    private var usesReducedMotion: Bool {
        #if DEBUG
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatch-reduce-motion")
        #else
        reduceMotion
        #endif
    }
    private func agent(_ desktop: CompanionDispatcherDesktop) -> CompanionAgent? {
        hosts.first { $0.id == desktop.id }?.dispatcherAgent
    }
    private func label(_ desktop: CompanionDispatcherDesktop) -> String {
        let duplicates = desktops.filter { $0.displayName == desktop.displayName }
        let ordinal = duplicates.count > 1 ? ", \((duplicates.firstIndex { $0.id == desktop.id } ?? 0) + 1) of \(duplicates.count)" : ""
        return desktop.displayName + ordinal + (replies.contains(desktop.id) ? ", New reply" : "")
    }
    private func choose(_ desktop: CompanionDispatcherDesktop) {
        CompanionUIActions.record(.selectDesktop, on: .dispatcher)
        select(desktop.id)
    }
    var body: some View {
        // The chips are a bar over the conversation rather than a row above it: the conversation's wash runs
        // up behind the header and chips, and the transcript scrolls under one header (#529).
        // One container: a bar on a multi-view builder would be applied to each of its views.
        VStack(spacing: 0) { content }
        .safeAreaBar(edge: .top, spacing: 0) {
            if desktops.count > 1 && !collapsed {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(desktops) { desktop in
                            Button { choose(desktop) } label: {
                                HStack(spacing: 7) {
                                    avatar(desktop, size: 26)
                                    Text(desktop.displayName).multilineTextAlignment(.leading)
                                        .frame(maxWidth: textSize.isAccessibilitySize ? 280 : 240)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if replies.contains(desktop.id) {
                                        Circle().fill(Color(selectedHostID == desktop.id ? palette.onTint : palette.tint)).frame(width: 7, height: 7).accessibilityHidden(true)
                                    }
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color(selectedHostID == desktop.id ? palette.onTint : palette.label))
                                .padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 44)
                                .background(Color(selectedHostID == desktop.id ? palette.tint : palette.card), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(label(desktop))
                            .accessibilityAddTraits(selectedHostID == desktop.id ? [.isSelected] : [])
                            .accessibilityIdentifier("dispatcher-desktop-\(desktop.id)")
                        }
                        if collapsible {
                            Button("Collapse Dispatchers", systemImage: "chevron.up") { expandedWhileWorking = false }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    }.padding(.horizontal).padding(.vertical, 4)
                    // The header's photo-over-name chip hangs below the bar; keep the chips clear of it. A short
                    // (landscape) bar lays the chip out beside the photo and needs no room.
                    .padding(.top, verticalSizeClass == .compact ? 0 : CompanionConversationIdentityButton.overflowBelowBar)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("dispatcher-chips")
            }
        }
        .toolbar {
            // One leading item whose content changes, so expanding or collapsing never adds or removes a bar item.
            ToolbarItem(placement: .topBarLeading) {
                if desktops.count > 1 && collapsed {
                    Menu {
                        ForEach(desktops) { desktop in
                            Button { choose(desktop) } label: {
                                Label(desktop.displayName, systemImage: desktop.id == selectedHostID ? "checkmark" : "person.crop.circle")
                                if replies.contains(desktop.id) { Text("New reply") }
                            }
                            .accessibilityLabel(label(desktop))
                            .accessibilityIdentifier("dispatcher-desktop-\(desktop.id)")
                        }
                        Button("Show Dispatcher chips", systemImage: "chevron.down") { expandedWhileWorking = true }
                            .accessibilityIdentifier("dispatcher-expand-chips")
                        Divider()
                        settingsButton
                    } label: {
                        let others = Array(desktops.filter { $0.id != selectedHostID }.prefix(3))
                        HStack(spacing: -10) {
                            ForEach(others) { desktop in
                                avatar(desktop, size: 28)
                                    .overlay {
                                        if CompanionDispatcherTurn.separatesAvatars(count: others.count) {
                                            Circle().stroke(Color(palette.background), lineWidth: 2)
                                        }
                                    }
                            }
                        }.frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Switch Dispatcher")
                    .accessibilityValue(replies.isEmpty ? "" : "New replies")
                    .accessibilityIdentifier("dispatcher-desktop-switcher")
                } else {
                    // Home's own Settings control.
                    settingsButton.companionToolbarSecondary()
                }
            }
        }
        .animation(usesReducedMotion ? nil : .snappy(duration: 0.2), value: collapsed)
        // Only a turn's edges reset the choice; a connection edge alone never does.
        .onChange(of: isWorking) { _, _ in expandedWhileWorking = false }
        .onChange(of: selectedHostID) { _, _ in expandedWhileWorking = false }
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape", action: openSettings)
            .accessibilityIdentifier("dispatcher-settings")
    }

    @ViewBuilder private func avatar(_ desktop: CompanionDispatcherDesktop, size: CGFloat) -> some View {
        if let agent = agent(desktop) { CompanionAgentAvatar(agent: agent, size: size).accessibilityHidden(true) }
        else {
            Text(String(desktop.displayName.prefix(1))).font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Color(palette.onTint)).frame(width: size, height: size)
                .background(Color(palette.tint), in: Circle()).accessibilityHidden(true)
        }
    }
}

#if DEBUG
/// Explicit synthetic reports for the preview-only interaction probe; absent from normal previews and Release.
struct CompanionDispatcherPreviewReports: View {
    let store: CompanionStore
    let desktops: [CompanionDispatcherDesktop]
    let selectedHostID: String?
    var body: some View {
        VStack(spacing: 4) {
          HStack {
            Button("Report other reply") {
                guard let target = desktops.first(where: { $0.id != selectedHostID })?.target else { return }
                store.apply(.upsert(target, .message(.init(id: UUID().uuidString, role: .assistant,
                    text: "A cached reply from the other Dispatcher.")), sequence: nil))
            }.accessibilityIdentifier("dispatcher-preview-other-reply")
            Button("Start reply") {
                guard let target = desktops.first(where: { $0.id == selectedHostID })?.target else { return }
                store.apply(.upsert(target, .message(.init(id: "dispatcher-preview-stream", role: .assistant,
                    text: "A reply is streaming.", isStreaming: true)), sequence: nil))
            }.accessibilityIdentifier("dispatcher-preview-start-reply")
            Button("Finish reply") {
                guard let target = desktops.first(where: { $0.id == selectedHostID })?.target else { return }
                store.apply(.streamFinished(target, messageID: "dispatcher-preview-stream", sequence: nil))
            }.accessibilityIdentifier("dispatcher-preview-finish-reply")
          }
          HStack {
            // A turn spans several streamed messages; the Dispatcher stays working between them.
            Button("Start turn") { report(status: .working) }.accessibilityIdentifier("dispatcher-preview-start-turn")
            Button("Finish turn") { report(status: .idle) }.accessibilityIdentifier("dispatcher-preview-finish-turn")
            Button("Ask permission") { report(status: .approval) }.accessibilityIdentifier("dispatcher-preview-ask-permission")
            Button("Resume turn") { report(status: .working) }.accessibilityIdentifier("dispatcher-preview-resume-turn")
          }
          HStack {
            Button("Disconnect desktop") { report(connection: .offline) }.accessibilityIdentifier("dispatcher-preview-disconnect")
            Button("Reconnect desktop") { report(connection: .connected) }.accessibilityIdentifier("dispatcher-preview-reconnect")
            Button("Report Dispatcher off") { report(enabled: false) }.accessibilityIdentifier("dispatcher-preview-off")
          }
          HStack {
            Button("Report reconnecting") { report(connection: .reconnecting) }.accessibilityIdentifier("dispatcher-preview-reconnecting")
            Button("Report connecting") { report(connection: .connecting) }.accessibilityIdentifier("dispatcher-preview-connecting")
          }
        }.font(.caption).buttonStyle(.bordered).padding(.horizontal)
    }
    private func report(connection: CompanionConnection? = nil, enabled: Bool? = nil, status: CompanionAgentStatus? = nil) {
        var next = store.hosts
        guard let index = next.firstIndex(where: { $0.id == selectedHostID }) else { return }
        if let connection { next[index].connection = connection }
        if let status {
            next[index].dispatcher?.agent?.status = status
            let started = next[index].dispatcher?.agent?.turnStartedAt
            next[index].dispatcher?.agent?.turnStartedAt = status == .idle ? nil : started ?? .now
        }
        if let enabled { next[index].dispatcher?.enabled = enabled }
        store.apply(.hosts(next))
    }
}
#endif
