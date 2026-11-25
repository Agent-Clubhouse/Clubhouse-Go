import ClubhouseTransport
import SafariServices
import SwiftUI
import UIKit

/// The terminal's web links, newest first. Open shows one in the in-app browser, so the app stays in front and the
/// shell stays up while the person signs in; Copy puts the exact address on the pasteboard.
struct CompanionTerminalLinksSheet: View {
    let links: [CompanionTerminalLink]
    let open: (CompanionTerminalLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied: CompanionTerminalLink?

    var body: some View {
        NavigationStack {
            List(Array(links.enumerated()), id: \.element.id) { index, link in
                VStack(alignment: .leading, spacing: 8) {
                    Text(link.host).font(.headline)
                    Text(link.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4).truncationMode(.middle)
                        .accessibilityIdentifier("terminal-link-text-\(index)")
                    HStack(spacing: 12) {
                        Button("Open", systemImage: "safari") {
                            CompanionUIActions.record(.openLink, on: .terminal)
                            open(link)
                        }
                        .accessibilityLabel("Open \(link.host)")
                        .accessibilityIdentifier("terminal-link-open-\(index)")
                        Button(copied == link ? "Copied" : "Copy", systemImage: copied == link ? "checkmark" : "doc.on.doc") {
                            CompanionUIActions.record(.copy, on: .terminal)
                            UIPasteboard.general.string = link.text
                            copied = link
                        }
                        .accessibilityLabel("Copy link to \(link.host)")
                        .accessibilityIdentifier("terminal-link-copy-\(index)")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("terminal-links-done")
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("terminal-links-sheet")
    }
}

/// An in-app Safari, presented over everything with UIKit so SwiftUI's own presentations (the terminal is one) are
/// left alone. The app doesn't leave the foreground, so its connection to the desktop stays up. Only
/// `CompanionTerminalLink` addresses (http and https) get here: Safari view controllers raise on any other scheme.
@MainActor final class CompanionInAppBrowser: NSObject, SFSafariViewControllerDelegate {
    private static var current: CompanionInAppBrowser?
    private let finished: () -> Void
    private var didFinish = false

    private init(finished: @escaping () -> Void) { self.finished = finished }

    /// False when there is nothing to present over; `finished` then never runs.
    @discardableResult
    static func present(_ link: CompanionTerminalLink, finished: @escaping () -> Void) -> Bool {
        guard current == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = (scene.keyWindow ?? scene.windows.first)?.rootViewController else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: link.url, configuration: configuration)
        controller.dismissButtonStyle = .done
        // Over the terminal rather than replacing it, so the terminal's view never leaves the hierarchy.
        controller.modalPresentationStyle = .overFullScreen
        let browser = CompanionInAppBrowser(finished: finished)
        controller.delegate = browser
        current = browser
        top.present(controller, animated: true)
        return true
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated {
            guard !didFinish else { return }
            didFinish = true
            Self.current = nil
            finished()
        }
    }
}
