import SwiftUI
import AVKit
import ImageIO
import PDFKit
import WebKit

/// Opens desktop previews for a conversation or archived session.
struct CompanionContentPresenter {
    var richContentAvailable: Bool
    /// The displayed conversation's own snapshot hints, including negotiated any-path support.
    var contentRoots = CompanionContentRoots()
    var open: @MainActor (CompanionContentReference) -> Void
    /// The bytes for an image in a user message, for its inline thumbnail.
    var loadImage: @MainActor (CompanionMessageImage) async -> Data? = { $0.local?.data }
}

private struct CompanionContentPresenterKey: EnvironmentKey {
    static let defaultValue: CompanionContentPresenter? = nil
}

extension EnvironmentValues {
    var companionContentPresenter: CompanionContentPresenter? {
        get { self[CompanionContentPresenterKey.self] }
        set { self[CompanionContentPresenterKey.self] = newValue }
    }
}

extension View {
    /// Presents previews from here, once, rather than from timeline rows. Streaming updates re-create
    /// and fold rows, and a sheet owned by a row closed or got stuck with it (#134).
    func companionContentPreviews(store: CompanionStore, target: CompanionTarget, contentRoots: CompanionContentRoots? = nil) -> some View {
        modifier(CompanionContentPreviews(store: store, target: target, archiveRoots: contentRoots))
    }
}

private struct CompanionContentPreviews: ViewModifier {
    let store: CompanionStore
    let target: CompanionTarget
    /// Nil for live content; an archive always supplies a value, even before its first page.
    let archiveRoots: CompanionContentRoots?
    @State private var selected: CompanionContentReference?
    @State private var fullEvent: CompanionEventReference?
    func body(content: Content) -> some View {
        let roots = archiveRoots ?? store.contentRoots(for: target)
        content
            .companionMarkdownBlockPreviews()
            .environment(\.companionFullEventPresenter, .init(open: { fullEvent = $0 },
                canApprove: { store.canApprove($0, target: target) }, reason: { store.fullReviewReason($0, target: target) }))
            .environment(\.openURL, OpenURLAction { url in
                let reference = CompanionContentReference.link(url.absoluteString)
                if !CompanionContentReference.linkPaths(url.absoluteString, windows: roots.windows).isEmpty {
                    if store.richContentAvailable(for: target), reference.isOffered(roots: roots) { selected = reference }
                    return .handled
                }
                // External web/mail links keep their system behavior. Anchors,
                // network/device paths and other schemes never navigate on iOS.
                return ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
            .environment(\.companionContentPresenter, .init(richContentAvailable: store.richContentAvailable(for: target),
                                                             contentRoots: archiveRoots ?? store.contentRoots(for: target), open: { selected = $0 },
                                                             loadImage: { await store.imageData($0, target: target) }))
            .sheet(item: $fullEvent) { reference in
                CompanionFullEventReview(reference: reference, target: target, store: store)
            }
            .sheet(item: $selected) { reference in
                CompanionContentView(reference: reference, store: store, target: target, archiveRoots: archiveRoots) { selected = nil }
                    .interactiveDismissDisabled(false)
            }
    }
}

/// Explicit taps only: no remote URL fetches, filesystem probing or media prefetch.
/// Nothing shows when the desktop can't serve content; the conversation shows one hint instead.
struct CompanionContentLinks: View {
    let references: [CompanionContentReference]
    @Environment(\.companionContentPresenter) private var presenter
    var body: some View {
        if let presenter {
            let offered = CompanionContentReference.offered(references, richContentAvailable: presenter.richContentAvailable,
                                                                          roots: presenter.contentRoots)
            if !offered.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(offered) { reference in
                        Button { presenter.open(reference) } label: {
                            Label(reference.label, systemImage: reference.id.hasPrefix("image:") ? "photo" : "doc.text.magnifyingglass")
                                .lineLimit(2).font(.subheadline)
                        }.buttonStyle(.bordered).accessibilityIdentifier("companion-content-link")
                    }
                }
            }
        }
    }
}

/// Stands in for every image and file link while the desktop's Rich chat content is off.
struct CompanionContentHint: View {
    var body: some View {
        Label(CompanionContentReference.richContentOffHint, systemImage: "photo.on.rectangle.angled")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("companion-content-hint")
    }
}

private struct CompanionContentView: View {
    let reference: CompanionContentReference
    let store: CompanionStore
    let target: CompanionTarget
    let archiveRoots: CompanionContentRoots?
    let close: () -> Void
    @State private var content: CompanionContent?
    @State private var image: UIImage?
    @State private var pdf: PDFDocument?
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
                        if content.kind == "folder" {
                            ContentUnavailableView("Folder link", systemImage: "folder", description: Text(CompanionContentReference.folderLinkMessage))
                                .accessibilityIdentifier("companion-folder-link")
                        } else if content.tooLarge {
                            Text("This file exceeds the phone preview limit (8 MB). Open it on your desktop.")
                        } else if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel({ if case .localImage = reference { "Image you sent" } else { "Chat image from your desktop" } }())
                            HStack {
                                Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = image }
                                ShareLink(item: Image(uiImage: image), preview: SharePreview(content.name, image: Image(uiImage: image))) {
                                    Label("Share preview", systemImage: "square.and.arrow.up")
                                }
                            }.buttonStyle(.bordered)
                        } else if let pdf {
                            CompanionPDFPreview(document: pdf).containerRelativeFrame(.vertical) { length, _ in length * 0.8 }
                                .accessibilityIdentifier("companion-pdf-preview")
                            Text("PDF preview").font(.caption).foregroundStyle(.secondary)
                        } else if content.kind != "pdf", content.mimeType == "image/svg+xml", let bytes = content.bytes {
                            // SVG is an image resource, never an executable document.
                            CompanionSVGImage(bytes: bytes).frame(height: 360)
                            Text("SVG preview • scripts and external resources are blocked").font(.caption).foregroundStyle(.secondary)
                        } else if content.kind != "pdf", let text = content.text {
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close).accessibilityIdentifier("companion-preview-done") } }
            .task { await load() }
            .onDisappear { loadID = UUID(); pdf = nil; clearPlayback() }
        }
    }

    private func load() async {
        guard !loading else { return }
        let id = UUID(); loadID = id
        loading = true; error = nil; content = nil; image = nil; pdf = nil; clearPlayback()
        defer { loading = false }
        do {
            let value = try await store.content(reference, target: target, contentRoots: archiveRoots)
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
            } else if value.kind == "pdf" {
                pdf = try CompanionPDFPreview.document(for: value)
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

/// A desktop PDF shown from its bounded bytes in memory: no temporary file, share item or document URL.
/// Uses PDFKit's native scrolling, zoom and text selection. URL-link and remote-document delegate
/// actions are intercepted separately; this is not a claim about every PDF or system-menu action.
struct CompanionPDFPreview: UIViewRepresentable {
    let document: PDFDocument

    /// Nil when this response has no PDF to open: another kind, metadata only, or over the phone limit.
    static func document(for content: CompanionContent) throws -> PDFDocument? {
        guard let bytes = content.pdfBytes else { return nil }
        guard let document = PDFDocument(data: bytes) else { throw CompanionServiceError.unavailable("This PDF can't be opened on this iPhone. Open it on your desktop.") }
        // A locked document's properties can't be read until it's unlocked; the phone never asks for its password.
        guard !document.isLocked else { throw CompanionServiceError.unavailable("This PDF is password-protected. Open it on your desktop.") }
        guard document.pageCount > 0 else { throw CompanionServiceError.unavailable("This PDF has no pages to preview.") }
        return document
    }

    func makeCoordinator() -> LinkGuard { LinkGuard() }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        // PDFView holds its delegate weakly; SwiftUI keeps the coordinator until dismantleUIView.
        view.delegate = context.coordinator
        view.document = document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
    /// Nothing stays tappable once the guard can go: the document leaves before the delegate does.
    static func dismantleUIView(_ view: PDFView, coordinator: LinkGuard) {
        view.document = nil
        view.delegate = nil
    }

    final class LinkGuard: NSObject, PDFViewDelegate {
        /// PDFKit URL-link callback: do not request a system URL open.
        nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
        /// Links to another PDF: replaces the default beep. There's no other file to open.
        nonisolated func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
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
