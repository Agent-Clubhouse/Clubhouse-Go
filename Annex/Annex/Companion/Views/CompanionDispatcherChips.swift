import SwiftUI
import ClubhouseTransport

/// Dispatch has no All scope or machine labels. Home/project desktop-chip APIs remain unchanged.
struct CompanionDispatcherSwitcher<Content: View>: View {
    let desktops: [CompanionDispatcherDesktop]
    let hosts: [CompanionHost]
    let selectedHostID: String?
    let replies: Set<String>
    let isWorking: Bool
    var select: (String) -> Void
    let content: Content
    @State private var expandedWhileWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var textSize

    init(desktops: [CompanionDispatcherDesktop], hosts: [CompanionHost], selectedHostID: String?,
         replies: Set<String>, isWorking: Bool, select: @escaping (String) -> Void,
         @ViewBuilder content: () -> Content) {
        self.desktops = desktops
        self.hosts = hosts
        self.selectedHostID = selectedHostID
        self.replies = replies
        self.isWorking = isWorking
        self.select = select
        self.content = content()
    }

    private var collapsed: Bool { isWorking && !expandedWhileWorking }
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
        VStack(spacing: 0) {
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
                        if isWorking {
                            Button("Collapse Dispatchers", systemImage: "chevron.up") { expandedWhileWorking = false }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    }.padding(.horizontal).padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("dispatcher-chips")
            }
            content
        }
        .toolbar {
            if desktops.count > 1 && collapsed {
                ToolbarItem(placement: .topBarLeading) {
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
                    } label: {
                        HStack(spacing: -10) {
                            ForEach(Array(desktops.filter { $0.id != selectedHostID }.prefix(3))) { desktop in
                                avatar(desktop, size: 28).overlay(Circle().stroke(Color(palette.background), lineWidth: 2))
                            }
                        }.frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Switch Dispatcher")
                    .accessibilityValue(replies.isEmpty ? "" : "New replies")
                    .accessibilityIdentifier("dispatcher-desktop-switcher")
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: collapsed)
        .onChange(of: isWorking) { _, _ in expandedWhileWorking = false }
        .onChange(of: selectedHostID) { _, _ in expandedWhileWorking = false }
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
        }.font(.caption).buttonStyle(.bordered).padding(.horizontal)
    }
}
#endif
