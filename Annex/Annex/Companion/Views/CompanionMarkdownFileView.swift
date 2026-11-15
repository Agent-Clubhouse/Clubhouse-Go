import SwiftUI
import ImageIO

struct CompanionMarkdownFileView: View {
    let preview: CompanionMarkdownFilePreview
    var line: Int?
    let truncated: Bool
    @State private var mode: CompanionMarkdownFilePreview.Mode

    init(text: String, line: Int?, truncated: Bool) {
        preview = .init(source: text)
        self.line = line
        self.truncated = truncated
        _mode = State(initialValue: line == nil ? .preview : .source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Markdown view", selection: $mode) {
                Text("Preview").tag(CompanionMarkdownFilePreview.Mode.preview)
                Text("Source").tag(CompanionMarkdownFilePreview.Mode.source)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("companion-markdown-file-mode")
            if mode == .preview {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(preview.elements.enumerated()), id: \.offset) { index, element in
                                Group {
                                    switch element {
                                    case .block(let block): CompanionMarkdownBlockView(block: block, depth: 0)
                                    case .image(let alt, let resource): CompanionMarkdownFileImage(alt: alt, resource: resource)
                                    }
                                }.id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 420)
                    .environment(\.openURL, OpenURLAction { url in
                        switch CompanionMarkdownFilePolicy.link(url.absoluteString) {
                        case .external: return .systemAction
                        case .fragment(let fragment):
                            if let index = preview.anchors[fragment] { reader.scrollTo(index, anchor: .top) }
                            return .handled
                        case .blocked: return .discarded
                        }
                    })
                    .accessibilityIdentifier("companion-markdown-file-preview")
                }
            } else {
                CompanionMarkdownSourceView(source: preview.source, range: line.map { preview.sourceRange(line: $0) })
                    .frame(height: 420)
                if let line {
                    Text("Source line \(line)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if truncated {
                Text("Preview truncated by desktop.").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("companion-markdown-file-truncated")
            }
            Button("Copy preview", systemImage: "doc.on.doc") { UIPasteboard.general.string = preview.source }
                .accessibilityIdentifier("companion-markdown-file-copy")
        }
        .companionMarkdownBlockPreviews()
    }
}

/// UIKit receives the original string, not Markdown's formatted source or split/joined lines.
struct CompanionMarkdownSourceView: UIViewRepresentable {
    let source: String
    var range: NSRange?
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .callout).withDesign(.monospaced)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "companion-markdown-file-source"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != source else { return }
        view.text = source
        if let range {
            view.selectedRange = range
            DispatchQueue.main.async { view.scrollRangeToVisible(range) }
        }
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        UIFont(descriptor: fontDescriptor.withDesign(design) ?? fontDescriptor, size: 0)
    }
}

private struct CompanionMarkdownFileImage: View {
    let alt: String
    let resource: CompanionMarkdownFilePolicy.Image
    @State private var image: UIImage?
    @State private var loading = false
    @State private var error: String?
    @State private var requested = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(alt) }
            else {
                Label(alt.isEmpty ? "Image not shown" : "Image not shown: \(alt)", systemImage: "photo")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("companion-markdown-file-image-placeholder")
                if resource != .blocked {
                    Button("Load image") { requested = true }.disabled(loading)
                }
            }
            if loading { ProgressView("Loading image") }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: requested) {
            if requested { await load(); requested = false }
        }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let data: Data
            switch resource {
            case .blocked: return
            case .data(let bytes): data = bytes
            case .remote(let url):
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCredentialStorage = nil
                configuration.httpCookieStorage = nil
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (stream, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 30), delegate: CompanionMarkdownHTTPSOnly())
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      response.url?.scheme?.lowercased() == "https",
                      CompanionMarkdownFilePolicy.rasterMIMETypes.contains(response.mimeType?.lowercased() ?? ""),
                      response.expectedContentLength <= CompanionMarkdownFilePolicy.maximumImageBytes else {
                    throw CompanionServiceError.unavailable("This image type or size is not supported.")
                }
                var bytes = Data()
                for try await byte in stream {
                    guard bytes.count < CompanionMarkdownFilePolicy.maximumImageBytes else {
                        throw CompanionServiceError.unavailable("This image exceeds the 2 MB preview limit.")
                    }
                    bytes.append(byte)
                }
                data = bytes
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 64 * 1024 * 1024 / height,
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw CompanionServiceError.unavailable("This image cannot be decoded safely.") }
            image = UIImage(cgImage: bitmap)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private final class CompanionMarkdownHTTPSOnly: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.map { if case .remote = CompanionMarkdownFilePolicy.image($0.absoluteString) { true } else { false } } ?? false
        completionHandler(allowed ? request : nil)
    }
}
