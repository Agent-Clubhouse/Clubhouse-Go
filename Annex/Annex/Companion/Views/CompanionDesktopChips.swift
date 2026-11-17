import SwiftUI
import ClubhouseTransport

/// UI scope only. Owners keep it in launch-lifetime state; it never changes pairing or command authority.
enum CompanionDesktopSelection: Hashable, Sendable {
    case all
    case host(String)

    var hostID: String? { if case .host(let id) = self { id } else { nil } }

    func reconciled(with hosts: [CompanionHost]) -> Self {
        guard let hostID else { return .all }
        return hosts.contains { $0.id == hostID } ? self : .all
    }
}

/// One horizontally scrolling row, shared by Home and linked project pages. Offline scopes remain selectable.
/// A missing selected desktop resets to All; one desktop needs no chips. Long labels wrap through XXXL.
struct CompanionDesktopChips: View {
    let hosts: [CompanionHost]
    @Binding var selection: CompanionDesktopSelection
    var onSelect: () -> Void
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionTelemetryScreen) private var screen
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(hosts: [CompanionHost], selection: Binding<CompanionDesktopSelection>, onSelect: @escaping () -> Void = {}) {
        self.hosts = hosts
        _selection = selection
        self.onSelect = onSelect
    }

    init(members: [CompanionProjectMember], selection: Binding<CompanionDesktopSelection>, onSelect: @escaping () -> Void = {}) {
        self.init(hosts: members.map(\.host), selection: selection, onSelect: onSelect)
    }

    static func uniqueHosts(_ hosts: [CompanionHost]) -> [CompanionHost] {
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0.id).inserted }
    }

    private var available: [CompanionHost] { Self.uniqueHosts(hosts) }

    #if DEBUG
    @Environment(\.companionHomeBuildCounting) private var countsHomeBuilds
    #endif

    var body: some View {
        #if DEBUG
        let _ = CompanionHomeBuildProbe.count(.chips, when: countsHomeBuilds)
        #endif
        Group {
            if available.count >= 2 {
                ScrollView(.horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        chip("All", symbol: nil, value: .all, label: "All desktops", id: "desktop-chip-all")
                        ForEach(available) { host in
                            let state = host.connection.presentation()
                            chip(host.name, symbol: state.symbol, value: .host(host.id), label: "\(host.name), \(state.label)", id: "desktop-chip-host-\(host.id)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("desktop-chips")
            }
        }
        .onChange(of: available.map(\.id), initial: true) { _, _ in
            let next = selection.reconciled(with: available)
            if next != selection { selection = next }
        }
    }

    private func chip(_ title: String, symbol: String?, value: CompanionDesktopSelection, label: String, id: String) -> some View {
        let selected = selection == value
        return Button {
            CompanionUIActions.record(.selectDesktop, on: screen)
            onSelect()
            selection = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)).accessibilityHidden(true) }
                Text(title)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 280 : 240)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color(selected ? palette.onTint : palette.label))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color(selected ? palette.tint : palette.card), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(value == .all ? "Shows every desktop" : "Shows this desktop")
        .accessibilityIdentifier(id)
    }
}
