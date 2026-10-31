import Testing
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// The paste hook on SwiftUI's vertical text field: it offers Paste for images only in the composer it registers.
@MainActor struct CompanionComposerPasteTests {
    private struct Field: View {
        var hooked: Bool
        @State private var text = ""
        var body: some View {
            TextField("Message", text: $text, axis: .vertical)
                .background { if hooked { CompanionComposerPasteHook { providers in providers.map { _ in true } } } }
        }
    }

    private func textView(hooked: Bool) throws -> (UITextView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.rootViewController = UIHostingController(rootView: Field(hooked: hooked))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? { (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first }
        let textView = try #require(find(window), "SwiftUI's vertical TextField is a UITextView")
        window.layoutIfNeeded()
        return (textView, window)
    }

    private var paste: Selector { #selector(UIResponder.paste(_:)) }

    @Test func offersPasteForImagesOnlyInTheHookedComposer() throws {
        let (composer, composerWindow) = try textView(hooked: true)
        let (other, otherWindow) = try textView(hooked: false)
        defer { composerWindow.isHidden = true; otherWindow.isHidden = true }
        #expect(type(of: composer) == type(of: other))
        #expect(composer.pasteDelegate is CompanionComposerPasteHook.Coordinator, "Drops on the field go through the hook")
        #expect(other.pasteDelegate == nil)
        let formatting = [#selector(UIResponder.toggleBoldface(_:)), NSSelectorFromString("_showTextFormattingOptions:")]
        #expect(formatting.allSatisfy { !composer.canPerformAction($0, withSender: nil) }, "The composer stays plain text")

        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        #expect(composer.canPerformAction(paste, withSender: nil), "The composer offers Paste for an image")
        #expect(!other.canPerformAction(paste, withSender: nil), "Other fields keep UIKit's text-only Paste")

        UIPasteboard.general.string = "words"
        for field in [composer, other] {
            _ = field.becomeFirstResponder()
            #expect(field.canPerformAction(paste, withSender: nil), "Text pastes everywhere")
            _ = field.resignFirstResponder()
        }
    }
}
