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
            Button("Review full payload", systemImage: "doc.text.magnifyingglass") { presenter.open(reference) }
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
    @State private var chunks: [String]?
    @State private var failure: String?
    @State private var reachedEnd = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let chunks {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Session \(reference.sessionID) · event \(reference.sequence)").font(.caption).foregroundStyle(.secondary)
                            // Whole JSON exposes rawInput, rawOutput, content and options together.
                            ForEach(chunks.indices, id: \.self) { index in
                                Text(chunks[index]).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("End of full event").font(.caption).foregroundStyle(.secondary)
                                .onAppear { reachedEnd = true }
                        }.padding()
                    }
                } else if let failure {
                    ContentUnavailableView("Full review unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else { ProgressView("Fetching full event…") }
            }
            .navigationTitle("Review full payload").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if let full, full.event["type"]?.string == "permission_request" {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Reviewed") {
                            store.acknowledgeFullReview(full, reference: reference, target: target)
                            dismiss()
                        }.disabled(!reachedEnd)
                    }
                }
            }
        }
        .task {
            do {
                let result = try await store.fetchFullEvent(reference, target: target)
                try Task.checkCancellation()
                var remaining = result.event.displayText[...]
                var parts: [String] = []
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: 16_384, limitedBy: remaining.endIndex) ?? remaining.endIndex
                    parts.append(String(remaining[..<end])); remaining = remaining[end...]
                }
                chunks = parts
                full = result
            } catch is CancellationError { }
            catch { failure = CompanionFullReview.reason(error) }
        }
    }
}
