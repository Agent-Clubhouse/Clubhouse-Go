import SwiftUI
import Framebriar
#if os(iOS)
import PhotosUI
import UIKit

/// The one feedback screen. It never captures the screen itself; a host (such as the shake shortcut)
/// may pass a screenshot it captured, which starts attached and included, and can be left out, removed,
/// replaced or edited. With no image it opens text-only. Report diagnostics, under `.on`, are captured once
/// when it opens. Nothing is saved or sent until the user taps Send. The source image and marks live only in
/// this view's memory, and only flattened bytes are sent: see `ScreenshotAttachment` for when edits become
/// final. All wording about what's included lives in `FeedbackDisclosure`.
public struct FeedbackView: View {
    private enum Phase: Equatable { case composing, saving, sending, finished(FeedbackDeliveryOutcome) }

    @Bindable private var model: FeedbackModel
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var selection: PhotosPickerItem?
    @State private var attachment: ScreenshotAttachment?
    @State private var editing = false
    @State private var draft: FeedbackDraft?
    @State private var includeDiagnostics = true
    @State private var phase = Phase.composing
    @State private var error: String?
    @State private var loading = false
    private let onClose: (@MainActor () -> Void)?
    private let reportDiagnostics: FeedbackReportDiagnostics?
    private let screenshotUnavailable: FeedbackScreenshotUnavailable?

    /// - Parameters:
    ///   - onClose: replaces the SwiftUI dismiss action, for a host that presents this from UIKit.
    ///   - reportDiagnostics: the mode for the first draft this view opens, and no other. If the enrollment
    ///     changes, its new draft uses the model's mode: to send `.on` again, present a new composer.
    ///   - screenshotUnavailable: why a capture the user expected isn't here, to say so. Leave nil if capture
    ///     is simply off. An `initialScreenshotPNG` that can't be used counts as `.failed`.
    public init(model: FeedbackModel, initialScreenshotPNG: Data? = nil, onClose: (@MainActor () -> Void)? = nil,
                reportDiagnostics: FeedbackReportDiagnostics? = nil, screenshotUnavailable: FeedbackScreenshotUnavailable? = nil) {
        self.model = model; self.onClose = onClose; self.reportDiagnostics = reportDiagnostics
        let valid = ShakeScreenshot.validatedAttachment(initialScreenshotPNG)
        _attachment = State(initialValue: valid.map { ScreenshotAttachment(png: $0, isCapture: true) })
        self.screenshotUnavailable = valid != nil ? nil : initialScreenshotPNG != nil ? .failed : screenshotUnavailable
    }

    private var sendBlock: FeedbackSendBlock? {
        FeedbackSendBlock.evaluate(status: model.status, notes: notes, hasScreenshot: attachment?.bytesToSend != nil, preparingImage: loading, saving: phase == .saving)
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
        .fullScreenCover(isPresented: $editing) {
            if let attachment {
                FeedbackScreenshotEditor(png: attachment.source, marks: attachment.marks, editsAreFinal: attachment.editsAreFinal, onDone: { flattened, marks in
                    // `selection` goes too, so nothing can reload a picked image over the edit.
                    self.attachment?.edit(image: flattened, marks: marks); selection = nil
                    editing = false
                }, onCancel: { editing = false })
                // A cover can take the composer's views out of the window, so the composer counts as open through this too.
                .onAppear { model.composerAppeared() }
                .onDisappear { model.composerDisappeared() }
            }
        }
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
        .interactiveDismissDisabled(phase == .saving || (phase == .composing && (!notes.isEmpty || attachment?.hasEdits == true)))
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
                    PhotosPicker(attachment == nil ? "Add screenshot" : "Replace screenshot", selection: $selection, matching: .images)
                    Spacer()
                    if attachment != nil {
                        Button("Remove", role: .destructive) { selection = nil; attachment = nil }
                            .accessibilityIdentifier("framebriar-remove-attachment")
                    }
                }.buttonStyle(.borderless).disabled(phase == .saving)
                if attachment == nil, let screenshotUnavailable {
                    Text(FeedbackDisclosure.screenshotUnavailable(screenshotUnavailable)).font(.caption).accessibilityIdentifier("framebriar-screenshot-unavailable")
                }
                if let attachment, let image = UIImage(data: attachment.image) {
                    Toggle(FeedbackDisclosure.screenshotToggle, isOn: Binding(get: { self.attachment?.included ?? false }, set: { self.attachment?.included = $0 }))
                        .disabled(phase == .saving).accessibilityIdentifier("framebriar-screenshot-switch")
                    if !attachment.included {
                        Text(FeedbackDisclosure.screenshotLeftOutNote).font(.caption).accessibilityIdentifier("framebriar-screenshot-left-out-note")
                    } else {
                        if attachment.editsAreFinal {
                            Text(FeedbackDisclosure.editedImageFinalNote).font(.caption).accessibilityIdentifier("framebriar-edited-final-note")
                        } else if attachment.hasEdits {
                            Text(FeedbackDisclosure.editedImageNote).font(.caption).accessibilityIdentifier("framebriar-edited-note")
                        } else if attachment.isCapture {
                            Text(FeedbackDisclosure.capturedScreenNote).font(.caption).accessibilityIdentifier("framebriar-captured-screen-note")
                        }
                        Text(FeedbackDisclosure.imageToolsHint).font(.caption)
                    }
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).opacity(attachment.included ? 1 : 0.35)
                        // Not `onTapGesture` or a default action, either of which would make the image a button to UI tests.
                        .gesture(TapGesture().onEnded { openEditor() })
                        .accessibilityLabel("Attached screenshot").accessibilityIdentifier("framebriar-attachment")
                        .accessibilityAction(named: "Zoom and mark up") { openEditor() }
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
        }
        // Pinned too: below an image, a row at the end of the form would be off screen when it appears.
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let sendBlock {
                    Text(FeedbackDisclosure.sendBlocked(sendBlock)).font(.caption).padding(.horizontal).padding(.vertical, 6)
                        .frame(maxWidth: .infinity).accessibilityIdentifier("framebriar-send-reason")
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("framebriar-error")
                }
            }
            .background(.bar)
        }
        // Pinned, so what's about to go out stays in view however long the form gets.
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let draft {
                    Text(draft.summary(notes: notes, hasScreenshot: attachment?.bytesToSend != nil, includeDiagnostics: including(draft), screenshotLeftOut: attachment?.included == false))
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
            // This task runs again when the composer reappears, so a finished selection can't stay: it would reload over an edit.
            loading = true; defer { loading = false; if !Task.isCancelled { selection = nil } }
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
                attachment = ScreenshotAttachment(png: png); error = nil
            } catch { if !Task.isCancelled { self.error = "Could not read that image." } }
        }
    }

    /// Only while composing and only for an image that's going out.
    private func openEditor() { if phase == .composing, !loading, attachment?.included == true { editing = true } }

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
        // The first Send tap ends reversibility, included or not, whatever then happens to the save.
        attachment?.endReversibility()
        phase = .saving; error = nil
        let notes = notes, png = attachment?.bytesToSend, include = including(draft)
        // Not tied to the view: closing the sheet after the commit must not cancel the attempt.
        Task {
            do {
                let report = try await model.save(draft, notes: notes, screenshotPNG: png, includeDiagnostics: include)
                phase = .sending
                phase = .finished(await model.deliver(report, includeDiagnostics: include))
            } catch {
                // Notes and image stay, and nothing is resent until the user taps Send. After an enrollment
                // change the rest is captured again and the summary above follows, in the model's mode, not
                // this view's: an override doesn't carry across enrollments.
                let recovery = model.recovery(after: error, for: draft)
                self.draft = recovery.draft
                self.error = recovery.notice
                phase = .composing
            }
        }
    }
}
#endif
