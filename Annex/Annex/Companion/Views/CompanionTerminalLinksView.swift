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
    private(set) static var current: CompanionInAppBrowser?
    private let finished: () -> Void
    private var didFinish = false
    /// Weak: if the whole stack is dismissed from outside (an App Intent clears every presentation), the controller
    /// goes away without telling its delegate, and this is how the next `present` notices.
    private weak var controller: UIViewController?

    private init(finished: @escaping () -> Void) { self.finished = finished }

    /// A browser is up: its controller is still on screen. Several signs, because how soon UIKit clears each one after
    /// an outside dismissal varies by OS: the controller is gone, nothing presents it, it is on its way out, or (once
    /// it has finished appearing) its view has left every window.
    static var isPresented: Bool {
        guard let controller = current?.controller else { return false }
        if controller.presentingViewController == nil || controller.isBeingDismissed { return false }
        if !controller.isBeingPresented, controller.isViewLoaded, controller.view.window == nil { return false }
        return true
    }

    /// False when there is already a browser up, or nothing to present over; `finished` then never runs.
    /// `presenter`, `animated` and `makeController` are for tests (Safari's remote view won't stay up in a unit-test
    /// host); the app presents Safari over the foreground scene's topmost controller.
    @discardableResult
    static func present(_ link: CompanionTerminalLink, over presenter: UIViewController? = nil, animated: Bool = true,
                        makeController: ((URL) -> UIViewController)? = nil, finished: @escaping () -> Void) -> Bool {
        // A browser dismissed by anything other than its own Done never reports back; forget it so Open still works.
        if !isPresented { current = nil }
        guard current == nil, var top = presenter ?? foregroundRoot() else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let controller: UIViewController
        if let makeController {
            controller = makeController(link.url)
        } else {
            let configuration = SFSafariViewController.Configuration()
            configuration.entersReaderIfAvailable = false
            let safari = SFSafariViewController(url: link.url, configuration: configuration)
            safari.dismissButtonStyle = .done
            controller = safari
        }
        // Over the terminal rather than replacing it, so the terminal's view never leaves the hierarchy.
        controller.modalPresentationStyle = .overFullScreen
        let browser = CompanionInAppBrowser(finished: finished)
        browser.controller = controller
        (controller as? SFSafariViewController)?.delegate = browser
        current = browser
        top.present(controller, animated: animated)
        return true
    }

    private static func foregroundRoot() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        return (scene?.keyWindow ?? scene?.windows.first)?.rootViewController
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated {
            guard !didFinish else { return }
            didFinish = true
            if Self.current === self { Self.current = nil }
            finished()
        }
    }
}
