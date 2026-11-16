import SwiftUI

/// A compact status row. Actions are explicit user intent; this view starts no recovery tasks.
struct CompanionRecoveryStatusView: View {
    let status: CompanionRecoveryStatus
    var hostName: String? = nil
    let onRetry: (CompanionRecoveryStatus.RetryAction) -> Void
    @State private var showsDetails = false
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if DEBUG
    /// Seed once when this component identity is created. Later input changes never control presentation.
    init(status: CompanionRecoveryStatus, hostName: String? = nil, initiallyShowsDetails: Bool = false,
         onRetry: @escaping (CompanionRecoveryStatus.RetryAction) -> Void) {
        self.status = status
        self.hostName = hostName
        self.onRetry = onRetry
        _showsDetails = State(initialValue: initiallyShowsDetails)
    }
    #endif

    var body: some View {
        if status.isVisible {
            CompanionCompactConnectionBanner(title: headline, systemImage: symbol,
                                             isInProgress: status.isInProgress) { actions }
            .padding(.horizontal, 16)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            // Keep identifiers on leaves: a container identifier can mask child selectors (#311).
            .sheet(isPresented: $showsDetails) {
                CompanionRecoveryStatusDetails(status: status, onRetry: onRetry)
                    .environment(\.companionPalette, palette)
            }
        }
    }

    private var headline: String {
        guard let hostName else { return status.title }
        switch status.phase {
        case .offline: return "\(hostName) is offline"
        case .connectionFailed: return "\(hostName) isn't connected"
        default: return status.title
        }
    }

    private var symbol: String {
        switch status.phase {
        case .offline, .connectionFailed: "wifi.slash"
        default: status.hasError ? "exclamationmark.circle" : "arrow.clockwise"
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if let action = status.retryAction {
                Button { onRetry(action) } label: {
                    Text(action.compactTitle)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("companion-recovery-retry")
            }
            Button { showsDetails = true } label: {
                Image(systemName: status.hasError ? "exclamationmark.circle" : "info.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(status.hasError ? "Recovery issue details" : "Recovery details")
            .accessibilityHint("Shows the full connection and conversation status")
            .accessibilityIdentifier("companion-recovery-details")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(palette.tint))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One compact line when it fits; long names and accessibility text get full-width wrapping and a reachable action row.
struct CompanionCompactConnectionBanner<Actions: View>: View {
    let title: String
    var systemImage = "wifi.slash"
    var isInProgress = false
    var titleIdentifier = "companion-connection-title"
    @ViewBuilder var actions: Actions
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headline(wrapping: false)
                Spacer(minLength: 0)
                actions
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    titleText.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        symbol
                        Spacer(minLength: 0)
                        actions
                    }
                    .frame(minHeight: 44)
                }
            } else {
                HStack(spacing: 8) {
                    headline(wrapping: true).frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color(palette.label))
        .padding(.horizontal, 12)
        .companionCardGlass(RoundedRectangle(cornerRadius: 20))
    }

    private func headline(wrapping: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            symbol
            titleText
        }
        .fixedSize(horizontal: !wrapping, vertical: true)
        .frame(minHeight: 44)
    }

    private var titleText: some View {
        Text(title).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(titleIdentifier)
    }

    @ViewBuilder private var symbol: some View {
        if isInProgress { ProgressView().controlSize(.small).accessibilityHidden(true) }
        else { Image(systemName: systemImage).foregroundStyle(Color(palette.secondaryLabel)).accessibilityHidden(true) }
    }
}

/// Home and Needs you share the same combined notice and explicit, per-host Retry routing.
struct CompanionDesktopConnectionBanner: View {
    @Bindable var store: CompanionStore
    let identifierPrefix: String
    @State private var retryAttempts: [String: UUID] = [:]

    var body: some View {
        let notice = CompanionConnectionNotice(hosts: store.hosts)
        Group {
            if notice.isVisible {
                CompanionCompactConnectionBanner(title: notice.title, isInProgress: notice.isInProgress,
                                                 titleIdentifier: "\(identifierPrefix)-connection-title") {
                    if !notice.retryHostIDs.isEmpty {
                        Button { retry(notice.retryHostIDs) } label: {
                            Text("Retry").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(notice.retryHostIDs.allSatisfy { retryAttempts[$0] != nil })
                        .accessibilityLabel(notice.retryLabel)
                        .accessibilityIdentifier(notice.retryHostIDs.count == 1 ? "\(identifierPrefix)-retry-\(notice.retryHostIDs[0])" : "\(identifierPrefix)-retry-all")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: store.hosts) { oldHosts, newHosts in
            retryAttempts = retryAttempts.filter { hostID, _ in
                guard let old = oldHosts.first(where: { $0.id == hostID }),
                      let new = newHosts.first(where: { $0.id == hostID }) else { return false }
                return old.connection == new.connection
            }
        }
    }

    private func retry(_ hostIDs: [String]) {
        for hostID in hostIDs where retryAttempts[hostID] == nil {
            let attempt = UUID()
            retryAttempts[hostID] = attempt
            Task {
                await store.reconnect(hostID: hostID)
                // An old attempt must not clear a newer latch after a reported state change.
                if retryAttempts[hostID] == attempt { retryAttempts[hostID] = nil }
            }
        }
    }
}

/// Internal so hosted tests can verify full details without a live store or transport.
struct CompanionRecoveryStatusDetails: View {
    let status: CompanionRecoveryStatus
    let onRetry: (CompanionRecoveryStatus.RetryAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(status.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(status.explanation).textSelection(.enabled)
                        .accessibilityIdentifier("companion-recovery-explanation")
                    if let action = status.retryAction {
                        Button {
                            dismiss()
                            onRetry(action)
                        } label: {
                            Text(action.title)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.glassProminent).companionProminentLabel().controlSize(.large)
                        .accessibilityIdentifier("companion-recovery-detail-retry")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .foregroundStyle(Color(palette.label))
            .background(Color(palette.background))
            .tint(Color(palette.tint))
            .navigationTitle("Connection and recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
