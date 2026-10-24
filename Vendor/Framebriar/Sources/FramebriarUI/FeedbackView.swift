import SwiftUI
import Framebriar
#if os(iOS)
import PhotosUI
import UIKit

/// Uses the system photo picker only after a user tap. Never captures an app screen.
public struct FeedbackView: View {
    @Bindable private var model: FeedbackModel
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var selection: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var review: ReviewedFeedback?
    @State private var error: String?
    @State private var loading = false
    public init(model: FeedbackModel) { self.model = model }
    public var body: some View {
        Form {
            Section {
                Text("Describe the issue without prompts, agent responses, credentials, or other private information. An attachment is optional.")
                TextEditor(text: $notes).frame(minHeight: 140).accessibilityLabel("Feedback notes")
                Text("\(notes.utf16.count) / 2000 characters").font(.caption)
                PhotosPicker("Choose screenshot to review", selection: $selection, matching: .images)
                if loading { ProgressView("Preparing image…") }
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                    Button("Remove attachment", role: .destructive) { selection = nil; self.imageData = nil; review = nil }
                }
                Button("Review feedback") {
                    do { review = try ReviewedFeedback(configuration: model.client.configuration, notes: notes, reviewedScreenshotPNG: imageData); error = nil }
                    catch { self.error = "Use at most 2000 characters and an image up to 8 MiB." }
                }.disabled(loading || model.working)
            }
            if let review {
                Section("Review exactly what will be saved") {
                    Text(review.notes)
                    Text(review.screenshotPNG == nil ? "No attachment" : "The image shown above will be attached.")
                    Text("Context: iOS, touch input, app identifier and configured build, submission time and random report/session IDs. No diagnostics are attached.")
                    Button("Submit reviewed feedback") {
                        Task { if await model.submit(review) { dismiss() } }
                    }.disabled(model.working || loading || model.status?.canSubmit != true)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let message = model.message { Text(message) }
        }
        .navigationTitle("Send feedback")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.working) } }
        .onChange(of: notes) { _, _ in review = nil }
        .task(id: selection) {
            review = nil; imageData = nil
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
                imageData = png; error = nil
            } catch { if !Task.isCancelled { self.error = "Could not read that image." } }
        }
        .task { await model.update() }
    }
}
#endif
