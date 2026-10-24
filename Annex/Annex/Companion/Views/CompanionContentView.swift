import SwiftUI
import AVKit
import ImageIO
import WebKit

/// Explicit taps only: no remote URL fetches, filesystem probing or media prefetch.
struct CompanionContentLinks: View {
    let references: [CompanionContentReference]
    let store: CompanionStore
    let target: CompanionTarget
    @State private var selected: CompanionContentReference?
    var body: some View {
        if !references.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Set(references)).sorted { $0.id < $1.id }) { reference in
                    Button { selected = reference } label: {
                        Label(reference.label, systemImage: reference.id.hasPrefix("image:") ? "photo" : "doc.text.magnifyingglass")
                            .lineLimit(2).font(.subheadline)
                    }.buttonStyle(.bordered).accessibilityIdentifier("companion-content-link")
                }
            }
            .sheet(item: $selected) { reference in
                CompanionContentView(reference: reference, store: store, target: target)
            }
        }
    }
}

private struct CompanionContentView: View {
    let reference: CompanionContentReference
    let store: CompanionStore
    let target: CompanionTarget
    @Environment(\.dismiss) private var dismiss
    @State private var content: CompanionContent?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var player: AVPlayer?
    @State private var temporaryFile: URL?
    @State private var loading = false
    @State private var loadID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading { ProgressView("Loading from your desktop…") }
                    if let error {
                        ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark", description: Text(error))
                        Button("Try again") { Task { await load() } }.frame(maxWidth: .infinity)
                    }
                    if let content {
                        if content.tooLarge {
                            Text("This file exceeds the phone preview limit (8 MB). Open it on your desktop.")
                        } else if let image {
                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Chat image from your desktop")
                            HStack {
                                Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = image }
                                ShareLink(item: Image(uiImage: image), preview: SharePreview(content.name, image: Image(uiImage: image))) {
                                    Label("Share preview", systemImage: "square.and.arrow.up")
                                }
                            }.buttonStyle(.bordered)
                        } else if content.mimeType == "image/svg+xml", let bytes = content.bytes {
                            // SVG is an image resource, never an executable document.
                            CompanionSVGImage(bytes: bytes).frame(height: 360)
                            Text("SVG preview • scripts and external resources are blocked").font(.caption).foregroundStyle(.secondary)
                        } else if let text = content.text {
                            Text(text).font(.callout.monospaced()).textSelection(.enabled)
                            if content.truncated { Text("Preview truncated by desktop.").font(.caption).foregroundStyle(.secondary) }
                            Button("Copy preview", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        } else if let player {
                            VideoPlayer(player: player).frame(height: content.kind == "audio" ? 130 : 300)
                            Text("Playback starts only when you press Play.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("This format cannot be previewed on this iPhone. Open it on your desktop.")
                        }
                    }
                }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .privacySensitive()
            .navigationTitle(content?.name ?? "Desktop preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .onDisappear { loadID = UUID(); clearPlayback() }
        }
    }

    private func load() async {
        guard !loading else { return }
        let id = UUID(); loadID = id
        loading = true; error = nil; content = nil; image = nil; clearPlayback()
        defer { loading = false }
        do {
            let value = try await store.content(reference, target: target)
            guard !Task.isCancelled, loadID == id else { return }
            content = value
            if value.kind == "image", value.mimeType != "image/svg+xml", let bytes = value.bytes {
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 64 * 1024 * 1024 / height,
                      let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { throw CompanionServiceError.unavailable("The image cannot be decoded safely.") }
                image = UIImage(cgImage: bitmap)
            } else if ["audio", "video"].contains(value.kind), let bytes = value.bytes,
                      let mime = value.mimeType {
                let extensions = ["video/mp4": "mp4", "video/webm": "webm", "video/ogg": "ogv", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac", "audio/wav": "wav", "audio/ogg": "ogg", "audio/flac": "flac"]
                guard let ext = extensions[mime] else { throw CompanionServiceError.unavailable("Unsupported media type.") }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("clubhouse-preview-" + UUID().uuidString).appendingPathExtension(ext)
                try bytes.write(to: file, options: [.atomic, .completeFileProtection])
                temporaryFile = file
                let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
        } catch {
            guard !Task.isCancelled, loadID == id else { return }
            content = nil; self.error = error.localizedDescription
        }
    }
    private func clearPlayback() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        temporaryFile = nil
    }
}

private struct CompanionSVGImage: UIViewRepresentable {
    let bytes: Data
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.accessibilityLabel = "SVG image preview"
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let html = "<meta name='viewport' content='width=device-width'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; base-uri 'none'\"><style>body{margin:0}img{max-width:100%;height:auto}</style><img alt='Chat image' src='data:image/svg+xml;base64,\(bytes.base64EncodedString())'>"
        view.loadHTMLString(html, baseURL: nil)
    }
}
