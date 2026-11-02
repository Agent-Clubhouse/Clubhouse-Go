import SwiftUI
import Framebriar
#if os(iOS)
import PhotosUI
import UIKit

/// The one feedback screen. It never captures the screen itself; a host (such as the shake shortcut)
/// may pass a screenshot it captured, which starts attached and can be removed or replaced. Report
/// diagnostics, under `.on`, are captured once when it opens. Nothing is saved or sent until the user taps Send.
/// All wording about what's included lives in `FeedbackDisclosure`.
public struct FeedbackView: View {
    private enum Phase: Equatable { case composing, saving, sending, finished(FeedbackDeliveryOutcome) }

    @Bindable private var model: FeedbackModel
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var selection: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var imageIsCapture: Bool
    @State private var draft: FeedbackDraft?
    @State private var includeDiagnostics = true
    @State private var phase = Phase.composing
    @State private var error: String?
    @State private var loading = false
    private let onClose: (@MainActor () -> Void)?
    private let reportDiagnostics: FeedbackReportDiagnostics?

    /// - Parameters:
    ///   - onClose: replaces the SwiftUI dismiss action, for a host that presents this from UIKit.
    ///   - reportDiagnostics: the mode for the first draft this view opens, and no other. If the enrollment
    ///     changes, its new draft uses the model's mode: to send `.on` again, present a new composer.
    public init(model: FeedbackModel, initialScreenshotPNG: Data? = nil, onClose: (@MainActor () -> Void)? = nil,
                reportDiagnostics: FeedbackReportDiagnostics? = nil) {
        self.model = model; self.onClose = onClose; self.reportDiagnostics = reportDiagnostics
        let attachment = ShakeScreenshot.validatedAttachment(initialScreenshotPNG)
        _imageData = State(initialValue: attachment)
        _imageIsCapture = State(initialValue: attachment != nil)
    }

    private var sendBlock: FeedbackSendBlock? {
        FeedbackSendBlock.evaluate(status: model.status, notes: notes, hasScreenshot: imageData != nil, preparingImage: loading, saving: phase == .saving)
    }
    private func close() { if let onClose { onClose() } else { dismiss() } }
    private func including(_ draft: FeedbackDraft) -> Bool { includeDiagnostics && draft.offersDiagnosticsSwitch }

    public var body: some View {
        Group {
            switch phase {
            case .composing, .saving: composer
            case .sending: result(FeedbackDisclosure.sendingTitle, FeedbackDisclosure.sendingDetail, sending: true)
            case .finished(let outcome): result(FeedbackDisclosure.title(outcome), FeedbackDisclosure.detail(outcome), sending: false)
            }
        }
        .navigationTitle("Send feedback")
        .toolbar {
            switch phase {
            case .composing, .saving:
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() }.disabled(phase == .saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }.disabled(sendBlock != nil || draft == nil).accessibilityIdentifier("framebriar-send")
                }
            case .sending, .finished:
                ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.accessibilityIdentifier("framebriar-done") }
            }
        }
        // A swipe must not throw away typed text or interrupt the local commit. Cancel stays explicit.
        .interactiveDismissDisabled(phase == .saving || (phase == .composing && !notes.isEmpty))
        .onAppear {
            model.composerAppeared()
            if draft == nil { draft = model.openDraft(reportDiagnostics: reportDiagnostics) }
        }
        .onDisappear { model.composerDisappeared() }
        .task { await model.update() }
    }

    private var composer: some View {
        Form {
            Section {
                Text(FeedbackDisclosure.notesPrompt).font(.caption)
                TextEditor(text: $notes).frame(minHeight: 100).accessibilityLabel("Feedback notes").accessibilityIdentifier("framebriar-notes")
                Text("\(notes.utf16.count) / 2000 characters").font(.caption)
            }
            Section {
                if loading { ProgressView("Preparing image…") }
                HStack {
                    PhotosPicker(imageData == nil ? "Add screenshot" : "Replace screenshot", selection: $selection, matching: .images)
                    Spacer()
                    if imageData != nil {
                        Button("Remove", role: .destructive) { selection = nil; imageData = nil; imageIsCapture = false }
                            .accessibilityIdentifier("framebriar-remove-attachment")
                    }
                }.buttonStyle(.borderless)
                if let imageData, let image = UIImage(data: imageData) {
                    if imageIsCapture {
                        Text(FeedbackDisclosure.capturedScreenNote).font(.caption).accessibilityIdentifier("framebriar-captured-screen-note")
                    }
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        .accessibilityLabel("Attached screenshot").accessibilityIdentifier("framebriar-attachment")
                }
            }
            Section {
                DisclosureGroup("What this means") {
                    Text(FeedbackDisclosure.alwaysIncluded).font(.caption)
                    if let draft {
                        if let meaning = draft.diagnosticsMeaning { Text(meaning).font(.caption) }
                        if let note = draft.telemetryNote(telemetry: model.telemetry, includeDiagnostics: including(draft)) {
                            Text(note).font(.caption)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("framebriar-error") }
        }
        .safeAreaInset(edge: .top) {
            if let sendBlock {
                Text(FeedbackDisclosure.sendBlocked(sendBlock)).font(.caption).padding(.horizontal).padding(.vertical, 6)
                    .frame(maxWidth: .infinity).background(.bar).accessibilityIdentifier("framebriar-send-reason")
            }
        }
        // Pinned, so what's about to go out stays in view however long the form gets.
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let draft {
                    Text(draft.summary(notes: notes, hasScreenshot: imageData != nil, includeDiagnostics: including(draft)))
                        .font(.footnote).accessibilityIdentifier("framebriar-included")
                    if draft.offersDiagnosticsSwitch {
                        Toggle(FeedbackDisclosure.diagnosticsToggle, isOn: $includeDiagnostics).font(.footnote).accessibilityIdentifier("framebriar-diagnostics-switch")
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 8).background(.bar)
        }
        .task(id: selection) {
            // A nil selection (first appearance, or Remove) must not discard a pre-attached capture.
            guard let selected = selection else { return }
            loading = true; defer { loading = false }
            do {
                guard let data = try await selected.loadTransferable(type: Data.self), !Task.isCancelled,
                      data.count <= 8 * 1024 * 1024,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 20_000_000,
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let png = UIImage(cgImage: cgImage).pngData(), png.count <= 8 * 1024 * 1024 else {
                    if !Task.isCancelled { error = "Choose an image up to 8 MiB and 20 megapixels." }; return
                }
                guard !Task.isCancelled else { return }
                // Decode/re-encode to strip source metadata. Only the displayed PNG can be submitted.
                imageData = png; imageIsCapture = false; error = nil
            } catch { if !Task.isCancelled { self.error = "Could not read that image." } }
        }
    }

    private func result(_ title: String, _ detail: String, sending: Bool) -> some View {
        Form {
            Section {
                if sending { ProgressView() }
                Text(title).font(.headline).accessibilityIdentifier("framebriar-result-title")
                Text(detail).accessibilityIdentifier("framebriar-result-detail")
            }
        }
    }

    private func send() {
        guard let draft, sendBlock == nil else { return }
        phase = .saving; error = nil
        let notes = notes, png = imageData, include = including(draft)
        // Not tied to the view: closing the sheet after the commit must not cancel the attempt.
        Task {
            do {
                let report = try await model.save(draft, notes: notes, screenshotPNG: png, includeDiagnostics: include)
                phase = .sending
                phase = .finished(await model.deliver(report, includeDiagnostics: include))
            } catch FramebriarError.enrollmentChanged {
                // This draft can never send. Notes and image stay; the rest is captured again, and the
                // summary above follows. Nothing is resent until the user taps Send. The model's mode,
                // not this view's: an override doesn't carry across enrollments.
                self.draft = model.openDraft()
                self.error = FeedbackDisclosure.enrollmentChangedNotice
                phase = .composing
            } catch {
                self.error = FeedbackDisclosure.detail(.needsAttention(FeedbackModel.notSaved(error)))
                phase = .composing
            }
        }
    }
}
#endif
