import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CompanionArtifactDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CompanionContentError.unavailable("This file's bytes aren't available.")
        }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct CompanionArtifactShareView: UIViewControllerRepresentable {
    let artifact: CompanionArtifactExport
    let completed: @MainActor (String?) -> Void

    static func itemProvider(for artifact: CompanionArtifactExport) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = artifact.filename
        provider.registerDataRepresentation(forTypeIdentifier: artifact.contentType.identifier, visibility: .all) { completion in
            completion(artifact.bytes, nil)
            return nil
        }
        return provider
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let configuration = UIActivityItemsConfiguration(itemProviders: [Self.itemProvider(for: artifact)])
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.completionWithItemsHandler = { _, _, _, error in
            let message = error?.localizedDescription
            Task { @MainActor in completed(message) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: ()) {
        controller.completionWithItemsHandler = nil
        controller.activityItemsConfiguration = nil
    }
}
