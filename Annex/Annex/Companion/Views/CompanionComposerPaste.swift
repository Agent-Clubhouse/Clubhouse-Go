import SwiftUI
import UIKit
import ObjectiveC

/// Plain editing state shared with the binding. Remember the exact native Shift Return edit so a deferred
/// SwiftUI binding update also bypasses slash completion; an unrelated edit cannot inherit the exemption.
@MainActor final class CompanionComposerReturnInput {
    nonisolated deinit {}
    private var newlineEdit: (old: String, new: String)?

    func insertNewline(in textView: UITextView) {
        let old = textView.text ?? ""
        let selection = textView.selectedRange
        let text = old as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return }
        newlineEdit = (old, text.replacingCharacters(in: selection, with: "\n"))
        textView.insertText("\n")
    }

    func consumesNewline(old: String, new: String) -> Bool {
        guard old != new else { return false }
        defer { newlineEdit = nil }
        return newlineEdit?.old == old && newlineEdit?.new == new
    }
}

/// Lets the composer take pasted images. SwiftUI's vertical `TextField` is a `UITextView`, which offers Paste only
/// for text unless it edits rich text, so this finds the one it sits behind and registers it: Paste is then offered
/// for images too, and image items go to `handle` while text pastes as before. The same stable native input also
/// exposes hardware Return commands and keyboard dismissal to accessibility while editing. Other text views are untouched.
struct CompanionComposerPasteHook: UIViewRepresentable {
    let handle: @MainActor ([NSItemProvider]) async -> [Bool]
    /// Nil outside editing, so Escape retains UIKit's standard navigation behavior.
    var dismissKeyboard: (@MainActor () -> Void)? = nil
    var hardwareReturn: (@MainActor () -> Void)? = nil
    var returnInput: CompanionComposerReturnInput? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle, dismissKeyboard: dismissKeyboard, hardwareReturn: hardwareReturn, returnInput: returnInput)
    }

    func makeUIView(context: Context) -> HookView {
        let view = HookView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: HookView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.dismissKeyboard = dismissKeyboard
        context.coordinator.hardwareReturn = hardwareReturn
        context.coordinator.returnInput = returnInput
        view.attach()
    }

    /// Also the text view's paste delegate, which UIKit calls for drops: images go to `handle`, and text goes in
    /// as plain text rather than the styled text a rich text view would take.
    @MainActor final class Coordinator: NSObject, UITextPasteDelegate {
        var handle: @MainActor ([NSItemProvider]) async -> [Bool]
        var dismissKeyboard: (@MainActor () -> Void)?
        var hardwareReturn: (@MainActor () -> Void)?
        var returnInput: CompanionComposerReturnInput?
        private var pending: [UITextPasteItem] = []

        init(handle: @escaping @MainActor ([NSItemProvider]) async -> [Bool], dismissKeyboard: (@MainActor () -> Void)?,
             hardwareReturn: (@MainActor () -> Void)? = nil, returnInput: CompanionComposerReturnInput? = nil) {
            self.handle = handle
            self.dismissKeyboard = dismissKeyboard
            self.hardwareReturn = hardwareReturn
            self.returnInput = returnInput
        }

        /// UIKit asks about every item of one drop in a row, so they are handled together on the next turn.
        func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting, transform item: UITextPasteItem) {
            pending.append(item)
            guard pending.count == 1 else { return }
            Task { @MainActor in
                let items = pending
                pending = []
                let used = await handle(items.map(\.itemProvider))
                for (index, item) in items.enumerated() {
                    if index < used.count && used[index] { item.setNoResult() } else { await Self.insertPlainText(item) }
                }
            }
        }

        private static func insertPlainText(_ item: UITextPasteItem) async {
            guard item.itemProvider.canLoadObject(ofClass: NSString.self) else { return item.setNoResult() }
            let text: String? = await withCheckedContinuation { continuation in
                _ = item.itemProvider.loadObject(ofClass: NSString.self) { value, _ in continuation.resume(returning: value as? String) }
            }
            if let text { item.setResult(string: text) } else { item.setNoResult() }
        }
    }

    final class HookView: UIView {
        weak var coordinator: Coordinator?
        private weak var textView: UITextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }

        func attach() {
            guard let coordinator, window != nil else { return }
            if textView?.window == nil { textView = findTextView() }
            if let textView { CompanionImagePaste.register(textView, coordinator) }
        }

        /// The nearest text view that overlaps this one, looking a few levels up so it never reaches another screen's field.
        private func findTextView() -> UITextView? {
            let frame = convert(bounds, to: nil)
            guard !frame.isEmpty else { return nil }
            var ancestor = superview
            for _ in 0..<6 {
                guard let current = ancestor else { return nil }
                if let match = Self.textViews(in: current).first(where: { $0.convert($0.bounds, to: nil).intersects(frame) }) { return match }
                ancestor = current.superview
            }
            return nil
        }

        private static func textViews(in view: UIView) -> [UITextView] {
            view.subviews.flatMap { subview in (subview as? UITextView).map { [$0] } ?? textViews(in: subview) }
        }
    }
}

/// Adds image paste to the text view class SwiftUI uses, once per class. The overrides act only for a registered
/// text view and otherwise call the class's own implementation, so every other field behaves exactly as before.
@MainActor enum CompanionImagePaste {
    private static var key: UInt8 = 0
    private static var patched: Set<ObjectIdentifier> = []

    static func register(_ textView: UITextView, _ coordinator: CompanionComposerPasteHook.Coordinator) {
        objc_setAssociatedObject(textView, &key, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // UIKit offers Paste for images only in a text view that edits rich text. The composer stays plain:
        // formatting actions are hidden below, and everything but images pastes with rich text off.
        if !textView.allowsEditingTextAttributes { textView.allowsEditingTextAttributes = true }
        if textView.pasteDelegate == nil { textView.pasteDelegate = coordinator }
        // Native equivalents of SwiftUI's named action and .escape. Unlike a conditional modifier around
        // TextField, updating these doesn't replace the field (and its selection) when focus changes.
        let actionName = String(localized: "Dismiss Keyboard")
        let actions = textView.accessibilityCustomActions ?? []
        let hasDismissAction = actions.contains { $0.name == actionName }
        if coordinator.dismissKeyboard != nil, !hasDismissAction {
            let action = UIAccessibilityCustomAction(name: actionName) { [weak textView] _ in
                guard let textView, textView.isFirstResponder,
                      let dismiss = Self.coordinator(for: textView)?.dismissKeyboard else { return false }
                dismiss()
                return true
            }
            textView.accessibilityCustomActions = actions + [action]
        } else if coordinator.dismissKeyboard == nil, hasDismissAction {
            let remaining = actions.filter { $0.name != actionName }
            textView.accessibilityCustomActions = remaining.isEmpty ? nil : remaining
        }
        var type: AnyClass = object_getClass(textView) ?? UITextView.self
        // Key-value observing swaps in a temporary subclass; patch the real one.
        if NSStringFromClass(type).hasPrefix("NSKVONotifying_"), let base = class_getSuperclass(type) { type = base }
        guard type != UITextView.self, patched.insert(ObjectIdentifier(type)).inserted else { return }
        patchCanPerformAction(type)
        patchPaste(type)
        patchAccessibilityEscape(type)
        patchHardwareReturn(type)
        patchTypingProbe(type)
    }

    /// Rich text actions the composer never offers.
    private static let formatting: Set<Selector> = [
        #selector(UIResponder.toggleBoldface(_:)), #selector(UIResponder.toggleItalics(_:)), #selector(UIResponder.toggleUnderline(_:)),
        #selector(UIResponder.increaseSize(_:)), #selector(UIResponder.decreaseSize(_:)),
        #selector(UIResponder.updateTextAttributes(conversionHandler:)), #selector(UIResponder.pasteAndMatchStyle(_:)),
        // The edit menu's Format item.
        NSSelectorFromString("_showTextFormattingOptions:")
    ]

    private static func coordinator(for textView: UITextView) -> CompanionComposerPasteHook.Coordinator? {
        objc_getAssociatedObject(textView, &key) as? CompanionComposerPasteHook.Coordinator
    }

    private static func patchCanPerformAction(_ type: AnyClass) {
        typealias Function = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
        let selector = #selector(UIResponder.canPerformAction(_:withSender:))
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject, Selector, Any?) -> Bool = { object, action, sender in
            if action == hardwareReturnAction || action == hardwareNewlineAction {
                return MainActor.assumeIsolated {
                    guard let textView = object as? UITextView else { return false }
                    return returnCoordinator(for: textView) != nil
                }
            }
            if let textView = object as? UITextView, MainActor.assumeIsolated({ coordinator(for: textView) != nil }) {
                if formatting.contains(action) { return false }
                // Only detection such as `hasImages` works on another app's pasteboard before the person pastes.
                if action == #selector(UIResponder.paste(_:)), MainActor.assumeIsolated({ textView.isEditable && UIPasteboard.general.hasImages }) { return true }
            }
            return original(object, selector, action, sender)
        }
        replace(selector, in: type, method: method, with: imp_implementationWithBlock(block))
    }

    private static func patchPaste(_ type: AnyClass) {
        typealias Function = @convention(c) (AnyObject, Selector, Any?) -> Void
        let selector = #selector(UIResponder.paste(_:))
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject, Any?) -> Void = { object, sender in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let textView = object as? UITextView, let coordinator = coordinator(for: textView), UIPasteboard.general.hasImages else { return false }
                // Reading the pasteboard here is the person's own paste, so iOS doesn't ask for permission.
                let providers = UIPasteboard.general.itemProviders
                let images = providers.filter { CompanionPastedImages.imageType(in: $0.registeredTypeIdentifiers) != nil }
                guard !images.isEmpty else { return false }
                let handle = coordinator.handle
                Task { @MainActor in _ = await handle(images) }
                // Text items pasted alongside the images still go into the field.
                return images.count == providers.count
            }
            guard !handled else { return }
            MainActor.assumeIsolated {
                guard let textView = object as? UITextView, coordinator(for: textView) != nil else { return original(object, selector, sender) }
                textView.allowsEditingTextAttributes = false
                original(object, selector, sender)
                textView.allowsEditingTextAttributes = true
            }
        }
        replace(selector, in: type, method: method, with: imp_implementationWithBlock(block))
    }

    private static func patchAccessibilityEscape(_ type: AnyClass) {
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let selector = #selector(NSObject.accessibilityPerformEscape)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject) -> Bool = { object in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let textView = object as? UITextView, textView.isFirstResponder,
                      let dismiss = coordinator(for: textView)?.dismissKeyboard else { return false }
                dismiss()
                return true
            }
            return handled || original(object, selector)
        }
        replace(selector, in: type, method: method, with: imp_implementationWithBlock(block))
    }

    private static let hardwareReturnAction = NSSelectorFromString("companionComposerHardwareReturn:")
    private static let hardwareNewlineAction = NSSelectorFromString("companionComposerHardwareNewline:")

    /// Guard advertisement, action validation and dispatch: a cached command must never confirm marked text,
    /// send from an unfocused input, or edit a disabled field. Send eligibility remains the store's responsibility.
    private static func returnCoordinator(for textView: UITextView) -> CompanionComposerPasteHook.Coordinator? {
        guard textView.isFirstResponder, textView.isEditable, textView.isUserInteractionEnabled,
              textView.markedTextRange == nil, let coordinator = coordinator(for: textView),
              coordinator.hardwareReturn != nil, coordinator.returnInput != nil else { return nil }
        return coordinator
    }

    private static func patchHardwareReturn(_ type: AnyClass) {
        // Only two exact hardware chords. Software Return, insertText, paste and the existing SwiftUI
        // Command Return shortcut keep their own paths; no newline interception or delegate replacement.
        for (action, modifiers) in [(hardwareReturnAction, UIKeyModifierFlags()), (hardwareNewlineAction, .shift)] {
            let block: @convention(block) (AnyObject, Any?) -> Void = { object, sender in
                MainActor.assumeIsolated {
                    guard let textView = object as? UITextView, let command = sender as? UIKeyCommand,
                          command.input == "\r", command.modifierFlags == modifiers,
                          let coordinator = returnCoordinator(for: textView) else { return }
                    if modifiers == .shift { coordinator.returnInput?.insertNewline(in: textView) }
                    else { coordinator.hardwareReturn?() }
                }
            }
            class_addMethod(type, action, imp_implementationWithBlock(block), "v@:@")
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> NSArray?
        let selector = #selector(getter: UIResponder.keyCommands)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject) -> NSArray? = { object in
            let existing = original(object, selector)
            return MainActor.assumeIsolated {
                guard let textView = object as? UITextView, returnCoordinator(for: textView) != nil else { return existing }
                let send = UIKeyCommand(input: "\r", modifierFlags: [], action: hardwareReturnAction)
                let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: hardwareNewlineAction)
                // UIKit text input normally owns Return. Give these chords priority only for this registered,
                // editing composer, and remove exact duplicates without affecting Command/Option/Control Return.
                send.wantsPriorityOverSystemBehavior = true
                newline.wantsPriorityOverSystemBehavior = true
                let remaining = (existing as? [UIKeyCommand] ?? []).filter {
                    !($0.input == "\r" && ($0.modifierFlags.isEmpty || $0.modifierFlags == .shift))
                }
                return ([send, newline] + remaining) as NSArray
            }
        }
        replace(selector, in: type, method: method, with: imp_implementationWithBlock(block))
    }

    #if DEBUG
    /// #234: preview-only numeric diagnostics distinguish input delivery from composer/binding rollback.
    static let tracesPreviewTyping = ProcessInfo.processInfo.environment["CLUBHOUSE_PREVIEW_TYPING_PROBE"] == "1"
        && ProcessInfo.processInfo.arguments.contains("--companion-preview")
    private static func patchTypingProbe(_ type: AnyClass) {
        guard tracesPreviewTyping else { return }
        typealias Function = @convention(c) (AnyObject, Selector, String) -> Void
        let selector = #selector(UIKeyInput.insertText(_:))
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Function.self)
        let block: @convention(block) (AnyObject, String) -> Void = { object, text in
            original(object, selector, text)
            MainActor.assumeIsolated {
                if let view = object as? UITextView {
                    print("COMPOSER_INPUT input=\(text.utf16.count) length=\(view.text.utf16.count) focused=\(view.isFirstResponder)")
                }
            }
        }
        replace(selector, in: type, method: method, with: imp_implementationWithBlock(block))
    }
    #else
    private static func patchTypingProbe(_ type: AnyClass) {}
    #endif

    /// Adds the override to the class itself, or replaces its own implementation if it already has one.
    private static func replace(_ selector: Selector, in type: AnyClass, method: Method, with implementation: IMP) {
        if !class_addMethod(type, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}

