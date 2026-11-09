import SwiftUI
import ClubhouseTransport

struct CompanionFullEventPresenter {
    var open: @MainActor (CompanionEventReference) -> Void
    var canApprove: @MainActor (CompanionApproval) -> Bool
    var reason: @MainActor (CompanionApproval) -> String?
}
private struct CompanionFullEventPresenterKey: EnvironmentKey {
    static let defaultValue: CompanionFullEventPresenter? = nil
}
extension EnvironmentValues {
    var companionFullEventPresenter: CompanionFullEventPresenter? {
        get { self[CompanionFullEventPresenterKey.self] }
        set { self[CompanionFullEventPresenterKey.self] = newValue }
    }
}

struct CompanionFullEventButton: View {
    let reference: CompanionEventReference
    @Environment(\.companionFullEventPresenter) private var presenter
    var body: some View {
        if let presenter {
            Button(reference.reviewLabel, systemImage: "doc.text.magnifyingglass") { presenter.open(reference) }
                .font(.subheadline)
                .accessibilityIdentifier("companion-review-full-\(reference.sequence)")
        }
    }
}

/// Shows the original structured event, without the summary's or preview's character limits.
struct CompanionFullEventReview: View {
    let reference: CompanionEventReference
    let target: CompanionTarget
    let store: CompanionStore
    @State private var full: AnnexFullEvent?
    @State private var sections: [CompanionFullEventSection]?
    @State private var acknowledgmentFailure: String?
    @State private var failure: String?
    @State private var reachedEnd = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let sections {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Session \(reference.sessionID) · event \(reference.sequence)").font(.caption).foregroundStyle(.secondary)
                            Text("Invisible formatting characters are shown as ⟨U+XXXX⟩.").font(.caption).foregroundStyle(.secondary)
                            ForEach(sections.indices, id: \.self) { index in
                                let section = sections[index]
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section.heading).font(.caption.weight(.semibold)).textSelection(.enabled)
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(section.chunks.indices, id: \.self) { chunk in
                                            Text(section.chunks[chunk].isEmpty ? " " : section.chunks[chunk])
                                                .font(.callout.monospaced()).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                            Text("End of full event").font(.caption).foregroundStyle(.secondary)
                                .onAppear { reachedEnd = true }
                        }.padding()
                    }
                } else if let failure {
                    ContentUnavailableView("Full review unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else { ProgressView("Fetching full event…") }
            }
            .safeAreaInset(edge: .bottom) {
                if full?.event["type"]?.string == "permission_request", !reachedEnd {
                    Text("Scroll to the end to confirm").font(.caption).padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .navigationTitle(reference.reviewLabel).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if let full, full.event["type"]?.string == "permission_request" {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Reviewed") {
                            if store.acknowledgeFullReview(full, reference: reference, target: target) { dismiss() }
                            else { acknowledgmentFailure = "This request changed or the review expired while it was open. Close this review, refresh the conversation, and fetch the request again." }
                        }.disabled(!reachedEnd)
                        .accessibilityHint(reachedEnd ? "Confirm that you reviewed this complete request" : "Scroll to the end to confirm")
                    }
                }
            }
        }
        .alert("Review no longer current", isPresented: Binding(get: { acknowledgmentFailure != nil }, set: { if !$0 { acknowledgmentFailure = nil } })) {
            Button("Close review") { dismiss() }
        } message: { Text(acknowledgmentFailure ?? "Fetch and review this request again.") }
        .task {
            do {
                let result = try await store.fetchFullEvent(reference, target: target)
                try Task.checkCancellation()
                let formatting = Task.detached(priority: .userInitiated) { try CompanionFullEventDocument.sections(result.event) }
                sections = try await withTaskCancellationHandler { try await formatting.value } onCancel: { formatting.cancel() }
                try Task.checkCancellation()
                full = result
            } catch is CancellationError { }
            catch { failure = CompanionFullReview.reason(error) }
        }
    }
}
