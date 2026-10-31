import SwiftUI
import PhotosUI
import ImageIO

/// Picks images for the next message. The system photo picker runs out of process, so no library permission is asked.
struct CompanionAttachButton: View {
    let store: CompanionStore
    let target: CompanionTarget
    let limits: CompanionAttachmentLimits
    @State private var selection: [PhotosPickerItem] = []
    @State private var processing = false

    /// UI tests can't drive the system picker: a preview launch with `--companion-sample-images` adds a generated image per tap.
    /// So does a DEBUG launch with the live suite's test invitation, so a real desktop receives the image.
    static let usesSampleImages = ProcessInfo.processInfo.arguments.contains("--companion-sample-images")
        && (ProcessInfo.processInfo.arguments.contains("--companion-preview") || isLiveTestLaunch)

    private static var isLiveTestLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil
        #else
        false
        #endif
    }

    private var remaining: Int { max(0, limits.maxCount - (store.attachmentDrafts[target]?.count ?? 0)) }

    var body: some View {
        Group {
            if Self.usesSampleImages {
                Button { Task { await add([CompanionSampleImage.png(index: store.attachmentDrafts[target]?.count ?? 0)]) } } label: { icon }
            } else {
                PhotosPicker(selection: $selection, maxSelectionCount: max(1, remaining), selectionBehavior: .ordered,
                             matching: .images, preferredItemEncoding: .current) { icon }
            }
        }
        .buttonStyle(.plain)
        .disabled(remaining == 0 || processing || !store.canSend(target))
        .accessibilityLabel(remaining == 0 ? "Attach images, \(limits.maxCount) already attached" : "Attach images")
        .accessibilityIdentifier("companion-attach")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            selection = []
            Task { await load(items) }
        }
    }

    private var icon: some View {
        Group {
            if processing { ProgressView() } else { Image(systemName: "photo.badge.plus").font(.title3) }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var data: [Data] = []
        var unreadable = 0
        processing = true
        for item in items.prefix(remaining) {
            if let value = try? await item.loadTransferable(type: Data.self) { data.append(value) } else { unreadable += 1 }
        }
        await add(data, alreadyFailed: unreadable)
    }

    private func add(_ sources: [Data], alreadyFailed: Int = 0) async {
        processing = true
        defer { processing = false }
        let processed = await CompanionImageProcessor.processAll(sources, limits: limits, alreadyFailed: alreadyFailed)
        store.addAttachments(processed.images, to: target)
        if let problem = processed.problem { store.reportAttachmentProblem(problem, target: target) }
    }
}

/// The picked images above the message field, each with a remove button.
struct CompanionAttachmentStrip: View {
    let store: CompanionStore
    let target: CompanionTarget
    @Environment(\.companionPalette) private var palette

    var body: some View {
        if let images = store.attachmentDrafts[target], !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        ZStack(alignment: .topTrailing) {
                            CompanionImageThumbnail(data: image.bytes.data)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(6)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Image \(index + 1) of \(images.count)")
                                .accessibilityAddTraits(.isImage)
                                .accessibilityIdentifier("companion-attachment-thumbnail")
                            Button { store.removeAttachment(image.id, from: target) } label: {
                                Image(systemName: "xmark.circle.fill").font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color(palette.onTint), Color(palette.tint))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove image \(index + 1)")
                            .accessibilityIdentifier("companion-attachment-remove")
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
        }
    }
}

/// Images in a user message. Tapping one opens the conversation's preview sheet: the phone's own copy if it has one,
/// otherwise the desktop's when Rich chat content is on. Without either it is a placeholder with the file name.
struct CompanionMessageImages: View {
    let images: [CompanionMessageImage]
    /// Rows of three, right-aligned with your message like the text bubble.
    private var rows: [[CompanionMessageImage]] {
        stride(from: 0, to: images.count, by: 3).map { Array(images[$0..<min($0 + 3, images.count)]) }
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(spacing: 8) {
                    ForEach(row) { CompanionMessageImageTile(image: $0) }
                }
            }
        }
    }
}

private struct CompanionMessageImageTile: View {
    let image: CompanionMessageImage
    @Environment(\.companionContentPresenter) private var presenter
    @Environment(\.companionPalette) private var palette
    @State private var data: Data?

    private var reference: CompanionContentReference? {
        if image.local != nil { return .localImage(image.id) }
        if let reference = image.mediaRef, presenter?.richContentAvailable == true { return .image(reference) }
        return nil
    }

    var body: some View {
        Button { if let reference { presenter?.open(reference) } } label: {
            Group {
                if let data { CompanionImageThumbnail(data: data) } else { placeholder }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(reference == nil)
        .accessibilityLabel(image.name.map { "Image, \($0)" } ?? "Image")
        .accessibilityHint(reference == nil ? "" : "Opens the image")
        .accessibilityIdentifier("companion-message-image")
        .task(id: [image.id, image.mediaRef ?? "", presenter?.richContentAvailable == true ? "rich" : ""]) {
            if let local = image.local { data = local.data; return }
            data = await presenter?.loadImage(image)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.title3)
            if let name = image.name { Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center) }
        }
        .foregroundStyle(Color(palette.secondaryLabel))
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(palette.fill))
    }
}

/// A small decode of image bytes, made off the main thread at about the size it's shown.
struct CompanionImageThumbnail: View {
    let data: Data
    var pixelSize = 300
    @State private var image: UIImage?
    @Environment(\.companionPalette) private var palette

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color(palette.fill) }
        }
        .task(id: data) {
            let data = data, size = pixelSize
            image = await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixelSize: size) }.value
        }
    }

    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Generated images for UI tests and the preview, so they never need the photo library.
enum CompanionSampleImage {
    static func png(index: Int) -> Data {
        let colors: [UIColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen, .systemPink]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).pngData { context in
            colors[index % colors.count].setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 220, y: 120, width: 160, height: 160))
        }
    }
}
