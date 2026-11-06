import SwiftUI

/// A compact status row. Actions are explicit user intent; this view starts no recovery tasks.
struct CompanionRecoveryStatusView: View {
    let status: CompanionRecoveryStatus
    let onRetry: (CompanionRecoveryStatus.RetryAction) -> Void
    @State private var showsDetails = false
    @Environment(\.companionPalette) private var palette

    var body: some View {
        if status.isVisible {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headline(wrapping: false)
                    Spacer(minLength: 0)
                    actions
                }
                VStack(alignment: .leading, spacing: 0) {
                    headline(wrapping: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        actions
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color(palette.label))
            .padding(.horizontal, 12)
            .background(Color(status.isInProgress ? palette.card : palette.warning).opacity(status.isInProgress ? 1 : 0.12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion-recovery-status")
            .sheet(isPresented: $showsDetails) {
                CompanionRecoveryStatusDetails(status: status, onRetry: onRetry)
                    .environment(\.companionPalette, palette)
            }
        }
    }

    private func headline(wrapping: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if status.isInProgress {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                Image(systemName: status.hasError ? "exclamationmark.circle" : "arrow.clockwise")
                    .accessibilityHidden(true)
            }
            Text(status.title).fixedSize(horizontal: false, vertical: true)
        }
        // Let ViewThatFits measure the untruncated label before choosing its stacked fallback.
        .fixedSize(horizontal: !wrapping, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if let action = status.retryAction {
                Button(action.compactTitle) { onRetry(action) }
                    .frame(minWidth: 44, minHeight: 44)
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
                        Button(action.title) {
                            dismiss()
                            onRetry(action)
                        }
                        .frame(minWidth: 44, minHeight: 44)
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
                    Button("Done") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
