import SwiftUI
import UIKit
import ObjectiveC

/// Lets the composer take pasted images. SwiftUI's vertical `TextField` is a `UITextView`, which offers Paste only
/// for text unless it edits rich text, so this finds the one it sits behind and registers it: Paste is then offered
/// for images too, and image items go to `handle` while text pastes as before. Other text views are untouched.
struct CompanionComposerPasteHook: UIViewRepresentable {
    let handle: @MainActor ([NSItemProvider]) async -> [Bool]

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeUIView(context: Context) -> HookView {
        let view = HookView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: HookView, context: Context) {
        context.coordinator.handle = handle
        view.attach()
    }

    /// Also the text view's paste delegate, which UIKit calls for drops: images go to `handle`, and text goes in
    /// as plain text rather than the styled text a rich text view would take.
    @MainActor final class Coordinator: NSObject, UITextPasteDelegate {
        var handle: @MainActor ([NSItemProvider]) async -> [Bool]
        private var pending: [UITextPasteItem] = []

        init(handle: @escaping @MainActor ([NSItemProvider]) async -> [Bool]) { self.handle = handle }

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
        var type: AnyClass = object_getClass(textView) ?? UITextView.self
        // Key-value observing swaps in a temporary subclass; patch the real one.
        if NSStringFromClass(type).hasPrefix("NSKVONotifying_"), let base = class_getSuperclass(type) { type = base }
        guard type != UITextView.self, patched.insert(ObjectIdentifier(type)).inserted else { return }
        patchCanPerformAction(type)
        patchPaste(type)
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

    /// Adds the override to the class itself, or replaces its own implementation if it already has one.
    private static func replace(_ selector: Selector, in type: AnyClass, method: Method, with implementation: IMP) {
        if !class_addMethod(type, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}

