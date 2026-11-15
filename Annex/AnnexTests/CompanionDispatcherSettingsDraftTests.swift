import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor final class CompanionDispatcherSettingsDraftTests: XCTestCase {
    private static let corpus = [
        "\u{1F642}", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F1FA}\u{1F1F3}",
        "\u{1F44D}\u{1F3FD}", "\u{20000}", "e\u{301}"
    ]

    func testRepeatedSettingsAndUnrelatedSaveKeepEveryPendingFieldByteExact() {
        for sample in Self.corpus {
            var settings = CompanionPreviewService.previewDispatcherSettings
            var drafts = CompanionDispatcherSettingsDrafts()
            drafts.receive(settings)
            drafts.name.text += sample
            drafts.emoji.text = sample
            drafts.personality.text += sample
            let name = Array(drafts.name.text.utf8)
            let personality = Array(drafts.personality.text.utf8)
            drafts.receive(settings)
            settings.behavior.value = "thorough"
            drafts.receive(settings)
            XCTAssertEqual(Array(drafts.name.text.utf8), name)
            XCTAssertEqual(Array(drafts.emoji.text.utf8), Array(sample.utf8))
            XCTAssertEqual(Array(drafts.personality.text.utf8), personality)
            XCTAssertFalse(drafts.name.hasConflict)

            settings.identity.name = "Desktop name"
            settings.identity.emoji = "Desktop emoji"
            settings.personality?.text = "Desktop personality"
            drafts.receive(settings)
            XCTAssertEqual(Array(drafts.name.text.utf8), name)
            XCTAssertEqual(Array(drafts.emoji.text.utf8), Array(sample.utf8))
            XCTAssertEqual(Array(drafts.personality.text.utf8), personality)
            XCTAssertTrue(drafts.name.hasConflict)
            XCTAssertTrue(drafts.emoji.hasConflict)
            XCTAssertTrue(drafts.personality.hasConflict)

            settings.identity.name = "Saved name"
            drafts.receive(settings, saved: .name)
            XCTAssertEqual(drafts.name.text, "Saved name", "A submitted field accepts the desktop's normalized result")
            XCTAssertFalse(drafts.name.hasConflict)
            XCTAssertEqual(Array(drafts.emoji.text.utf8), Array(sample.utf8), "Saving name does not discard another field")
            XCTAssertEqual(Array(drafts.personality.text.utf8), personality)
        }
    }

    func testCanonicalEquivalentEditIsStillPendingAndConflictClearsWhenResolved() {
        var field = CompanionDispatcherSettingsDrafts.TextDraft()
        field.receive("\u{e9}")
        field.text = "e\u{301}"
        field.receive("Changed on desktop")
        XCTAssertEqual(Array(field.text.utf8), Array("e\u{301}".utf8))
        XCTAssertTrue(field.hasConflict)
        field.text = "Changed on desktop"
        XCTAssertFalse(field.hasConflict)
        field.text += " new edit"
        XCTAssertFalse(field.hasConflict, "A resolved conflict must not reappear for a later edit")
        field.receive("Changed on desktop new edit")
        XCTAssertFalse(field.hasConflict, "An incoming value matching the draft acknowledges it")
        field.receive("Next desktop value")
        XCTAssertEqual(field.text, "Next desktop value", "Acknowledgement makes the field clean again")
    }

    func testHostedFormReceivesDesktopNameChangesOffscreenWithoutReplacingPendingEdits() async throws {
        let service = CompanionPreviewService(showsDispatcher: true)
        service.showsDispatcherSettings = true
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        store.start()
        defer { store.shutdown() }
        try await waitUntil { store.dispatcherSettings(hostID: target.hostID) != nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: CompanionAgentSettingsSheet(store: store, target: target))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        var input: UITextField?
        try await waitUntil {
            window.layoutIfNeeded()
            input = self.textField("Name", in: window)
            if input == nil, let scroll = self.scrollView(in: window) {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 150)), animated: false)
            }
            return input != nil
        }
        XCTAssertEqual(input?.text, "Dispatcher")
        let initialName = try XCTUnwrap(input)
        let scroll = try XCTUnwrap(scrollView(in: window))
        let nameRect = initialName.convert(initialName.bounds, to: scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: nameRect.minY - scroll.adjustedContentInset.top - 20), animated: false)
        try await waitUntil {
            window.layoutIfNeeded()
            let top = scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top
            let field = initialName.convert(initialName.bounds, to: window)
            return field.minY >= top && field.maxY < top + 80
        }
        for sample in Self.corpus {
            let name = "Desktop " + sample
            _ = try await service.updateDispatcher(.init(name: name), hostID: target.hostID, clientCommandID: UUID().uuidString)
            try await waitUntil {
                window.layoutIfNeeded()
                return self.textField("Name", in: window)?.text == name
            }
            XCTAssertEqual(Array((textField("Name", in: window)?.text ?? "").utf8), Array(name.utf8))
        }
        let name = try XCTUnwrap(textField("Name", in: window))
        XCTAssertTrue(name.becomeFirstResponder())
        name.selectedTextRange = name.textRange(from: name.endOfDocument, to: name.endOfDocument)
        let suffix = Self.corpus.joined()
        name.insertText(suffix)
        let draft = "Desktop " + (try XCTUnwrap(Self.corpus.last)) + suffix
        XCTAssertEqual(Array((name.text ?? "").utf8), Array(draft.utf8))
        _ = try await service.updateDispatcher(.init(name: "Renamed externally", emoji: .set("X")),
            hostID: target.hostID, clientCommandID: UUID().uuidString)
        try await waitUntil {
            window.layoutIfNeeded()
            return self.textField("None", in: window)?.text == "X"
        }
        XCTAssertEqual(Array((textField("Name", in: window)?.text ?? "").utf8), Array(draft.utf8),
            "The same incoming snapshot updates a clean emoji but preserves the edited name")
    }

    private func textField(_ placeholder: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == placeholder { return field }
        return view.subviews.lazy.compactMap { self.textField(placeholder, in: $0) }.first
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap(scrollView).first
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The hosted settings form must reach the expected state", file: file, line: line)
    }
}
