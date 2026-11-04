import Testing
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// The paste hook on SwiftUI's vertical text field: it offers Paste for images only in the composer it registers.
@MainActor struct CompanionComposerPasteTests {
    private struct Field: View {
        var hooked: Bool
        @State private var text: String
        init(hooked: Bool, text: String = "") {
            self.hooked = hooked
            _text = State(initialValue: text)
        }
        var body: some View {
            TextField("Message", text: $text, axis: .vertical)
                .background { if hooked { CompanionComposerPasteHook { providers in providers.map { _ in true } } } }
        }
    }

    private func textView(hooked: Bool, text: String = "") throws -> (UITextView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.rootViewController = UIHostingController(rootView: Field(hooked: hooked, text: text))
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

    @Test func keyboardAccessibilityActionsOnlyHandleAnEditingComposerAndKeepSelection() throws {
        let (composer, window) = try textView(hooked: true, text: "Keep this selected draft")
        defer { window.isHidden = true }
        let selection = NSRange(location: 5, length: 4)
        composer.selectedRange = selection
        var dismissals = 0
        let coordinator = CompanionComposerPasteHook.Coordinator(handle: { _ in [] }, dismissKeyboard: { [weak composer] in
            dismissals += 1
            composer?.resignFirstResponder()
        })
        CompanionImagePaste.register(composer, coordinator)
        let action = try #require(composer.accessibilityCustomActions?.first { $0.name == "Dismiss Keyboard" })
        let perform = try #require(action.actionHandler)
        #expect(!perform(action), "A stale action must not handle an unfocused field")
        #expect(dismissals == 0)
        #expect(composer.becomeFirstResponder())
        composer.selectedRange = selection
        #expect(perform(action), "Invoke the actual UIKit custom action, not a test-only dismissal")
        #expect(dismissals == 1)
        #expect(!composer.isFirstResponder)
        #expect(composer.text == "Keep this selected draft")
        #expect(composer.selectedRange == selection)
        #expect(composer.becomeFirstResponder())
        #expect(composer.accessibilityPerformEscape(), "Invoke the same native Escape handler used by VoiceOver")
        #expect(dismissals == 2)
        #expect(!composer.isFirstResponder)
        #expect(composer.text == "Keep this selected draft")
        #expect(composer.selectedRange == selection)

        coordinator.dismissKeyboard = nil
        CompanionImagePaste.register(composer, coordinator)
        #expect(!(composer.accessibilityCustomActions ?? []).contains { $0.name == "Dismiss Keyboard" })
        #expect(!composer.accessibilityPerformEscape(), "Outside editing, leave Escape to the original UIKit handler")
        #expect(dismissals == 2)
        let (other, otherWindow) = try textView(hooked: false)
        defer { otherWindow.isHidden = true }
        #expect(!(other.accessibilityCustomActions ?? []).contains { $0.name == "Dismiss Keyboard" })
        #expect(!other.accessibilityPerformEscape(), "The shared native text-view class leaves other fields alone")
    }

}
