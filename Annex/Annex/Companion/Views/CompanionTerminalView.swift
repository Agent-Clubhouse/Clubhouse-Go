import SwiftUI
import UIKit

/// Opens terminals from anywhere: a project's header menu and page, an agent's long-press and chat menus.
struct CompanionTerminalAction {
    var availability: @MainActor (CompanionTerminalScope) -> CompanionTerminalAvailability
    var open: @MainActor (CompanionTerminalScope) -> Void
}

private struct CompanionTerminalActionKey: EnvironmentKey {
    static let defaultValue: CompanionTerminalAction? = nil
}

extension EnvironmentValues {
    var companionTerminal: CompanionTerminalAction? {
        get { self[CompanionTerminalActionKey.self] }
        set { self[CompanionTerminalActionKey.self] = newValue }
    }
}

/// "Terminal" in a menu: a shell at the project root, or in the agent's worktree. Hidden when the desktop has no terminals.
struct CompanionTerminalMenuItem: View {
    let scope: CompanionTerminalScope
    @Environment(\.companionTerminal) private var terminal
    var body: some View {
        if let terminal {
            let availability = terminal.availability(scope)
            if availability.isShown {
                Button("Terminal", systemImage: "terminal") { terminal.open(scope) }
                    .disabled(!availability.isAvailable)
            }
        }
    }
}

// MARK: Full screen

/// A full-screen terminal, presented over everything: the shell (or agent PTY), the key bar, and its state.
struct CompanionTerminalScreenView: View {
    @Bindable var store: CompanionStore
    let scope: CompanionTerminalScope
    @Environment(\.dismiss) private var dismiss
    @State private var session: CompanionTerminalSession?
    @State private var openError: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    CompanionTerminalPane(session: session, colors: colors)
                } else {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(openError ?? ""))
                }
            }
            .navigationTitle(session?.title ?? "Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(colors.background), for: .navigationBar)
            .toolbarColorScheme(colors.background.luminance < 0.4 ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("terminal-done")
                }
                if let session {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Copy all", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = session.screen.plainText()
                                copied = true
                            }
                            if case .exited = session.state { Button(restartLabel, systemImage: "arrow.clockwise") { session.restart() } }
                            if case .failed = session.state { Button("Try again", systemImage: "arrow.clockwise") { session.restart() } }
                            if let cwd = session.cwd { Section(cwd) {} }
                        } label: { Label("Terminal actions", systemImage: "ellipsis") }
                        .accessibilityIdentifier("terminal-menu")
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5)); copied = false
        }
        .onAppear(perform: open)
        .onDisappear { session?.close() }
    }

    private var restartLabel: String { scope.resizesPTY ? "New shell" : "Reattach" }

    private var colors: CompanionTerminalColors {
        (store.hosts.first { $0.id == scope.hostID }?.theme ?? .clubhouse).terminal
    }

    private func open() {
        guard session == nil else { return }
        do {
            let session = try store.makeTerminal(scope)
            session.start()
            self.session = session
        } catch {
            openError = error.localizedDescription
        }
    }
}

/// A terminal-mode agent's own PTY in its chat, where the "runs in a terminal" notice was.
struct CompanionAgentTerminalPane: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @State private var session: CompanionTerminalSession?
    @State private var openError: String?

    var body: some View {
        Group {
            if let session {
                CompanionTerminalPane(session: session, colors: (store.host(for: target)?.theme ?? .clubhouse).terminal)
            } else if let openError {
                ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(openError))
            } else {
                ProgressView()
            }
        }
        .task(id: target) {
            guard session == nil else { return }
            do {
                let session = try store.makeTerminal(.agentPTY(target))
                session.start()
                self.session = session
            } catch {
                openError = error.localizedDescription
            }
        }
        .onDisappear { session?.close(); session = nil }
    }
}

// MARK: Pane

/// The terminal itself: its state, the screen, and the key bar above the keyboard.
struct CompanionTerminalPane: View {
    let session: CompanionTerminalSession
    let colors: CompanionTerminalColors
    @State private var focus = CompanionTerminalFocus()

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            CompanionTerminalCanvas(session: session, colors: colors, revision: session.revision, focus: focus)
                .accessibilityElement(children: .contain)
            CompanionTerminalKeyBar(session: session, focus: focus, colors: colors)
        }
        .background(Color(colors.background))
    }

    @ViewBuilder private var statusBanner: some View {
        switch session.state {
        case .running, .closed: EmptyView()
        case .connecting: banner("Connecting…", systemImage: nil, progress: true)
        case .reconnecting: banner("Reconnecting to your desktop…", systemImage: nil, progress: true)
        case .exited(let code):
            banner(code.map { "Exited with code \($0)." } ?? "Exited.", systemImage: "stop.circle",
                   action: (session.scope.resizesPTY ? "New shell" : "Reattach", session.restart))
        case .failed(let message):
            banner(message, systemImage: "exclamationmark.triangle", action: ("Try again", session.restart))
        }
    }

    private func banner(_ text: String, systemImage: String?, progress: Bool = false, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small) }
            if let systemImage { Image(systemName: systemImage) }
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if let action { Button(action.0, action: action.1).font(.footnote.weight(.semibold)).accessibilityIdentifier("terminal-retry") }
        }
        .foregroundStyle(Color(colors.foreground))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(colors.foreground).opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal-status")
    }
}

/// Lets SwiftUI buttons show and hide the keyboard of the UIKit view that takes typing.
@MainActor @Observable final class CompanionTerminalFocus {
    @ObservationIgnored weak var view: CompanionTerminalUIView?
    private(set) var isEditing = false
    func toggle() { if isEditing { _ = view?.resignFirstResponder() } else { _ = view?.becomeFirstResponder() } }
    func editingChanged(_ editing: Bool) { isEditing = editing }
}

// MARK: Key bar

/// Esc, Tab, Ctrl, ⌃C, the arrows and the symbols a phone keyboard hides, then Paste and the keyboard.
struct CompanionTerminalKeyBar: View {
    let session: CompanionTerminalSession
    let focus: CompanionTerminalFocus
    let colors: CompanionTerminalColors
    private static let symbols = ["|", "~", "/", "-", "*", "$", "&", ">"]

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc", "Escape", id: "esc") { session.press(.escape) }
                    key("tab", "Tab", id: "tab") { session.press(.tab) }
                    key("ctrl", "Control", id: "ctrl", selected: session.controlArmed) { session.controlArmed.toggle() }
                    key("⌃C", "Interrupt", id: "interrupt") { session.press(.interrupt) }
                    icon("arrow.left", "Left", id: "left") { session.press(.left) }
                    icon("arrow.up", "Up", id: "up") { session.press(.up) }
                    icon("arrow.down", "Down", id: "down") { session.press(.down) }
                    icon("arrow.right", "Right", id: "right") { session.press(.right) }
                    ForEach(Self.symbols, id: \.self) { symbol in key(symbol, symbol, id: symbol) { session.type(symbol) } }
                }
                .padding(.horizontal, 8)
            }
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in session.paste(strings.joined(separator: "\n")) }
            }
            .labelStyle(.iconOnly).buttonBorderShape(.capsule).controlSize(.small)
            .accessibilityIdentifier("terminal-paste")
            Button { focus.toggle() } label: {
                Image(systemName: focus.isEditing ? "keyboard.chevron.compact.down" : "keyboard")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel(focus.isEditing ? "Hide keyboard" : "Show keyboard")
            .accessibilityIdentifier("terminal-keyboard")
            .padding(.trailing, 8)
        }
        .padding(.vertical, 6)
        .disabled(!session.state.isLive)
        .foregroundStyle(Color(colors.foreground))
        .background(Color(colors.foreground).opacity(0.06))
    }

    private func key(_ title: String, _ label: String, id: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(.callout, design: .monospaced).weight(.medium)).frame(minWidth: 30, minHeight: 32)
        }
        .buttonStyle(CompanionTerminalKeyStyle(selected: selected, colors: colors))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("terminal-key-\(id)")
    }

    private func icon(_ systemImage: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.callout.weight(.medium)).frame(minWidth: 30, minHeight: 32)
        }
        .buttonStyle(CompanionTerminalKeyStyle(selected: false, colors: colors))
        .accessibilityLabel(label)
        .accessibilityIdentifier("terminal-key-\(id)")
    }
}

private struct CompanionTerminalKeyStyle: ButtonStyle {
    let selected: Bool
    let colors: CompanionTerminalColors
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .foregroundStyle(Color(selected ? colors.background : colors.foreground))
            .background(Color(selected ? colors.cursor : colors.foreground).opacity(selected ? 1 : configuration.isPressed ? 0.25 : 0.12),
                        in: .rect(cornerRadius: 8))
    }
}

// MARK: Canvas

/// The screen in a read-only, selectable text view, with a key-input view that sends typing to the PTY.
struct CompanionTerminalCanvas: UIViewRepresentable {
    let session: CompanionTerminalSession
    let colors: CompanionTerminalColors
    /// Read here so SwiftUI redraws on every screen change.
    let revision: Int
    let focus: CompanionTerminalFocus

    func makeUIView(context: Context) -> CompanionTerminalUIView {
        let view = CompanionTerminalUIView(session: session, colors: colors)
        view.onEditingChanged = { [focus] in focus.editingChanged($0) }
        focus.view = view
        // A shell is for typing; an agent's terminal is mostly for watching.
        view.focusWhenShown = session.scope.resizesPTY
        return view
    }

    func updateUIView(_ view: CompanionTerminalUIView, context: Context) {
        view.colors = colors
        view.setNeedsRender()
    }
}

final class CompanionTerminalUIView: UIView, UITextViewDelegate {
    private let session: CompanionTerminalSession
    var colors: CompanionTerminalColors { didSet { if colors != oldValue { applyColors(); setNeedsRender() } } }
    var onEditingChanged: ((Bool) -> Void)?
    private let textView = UITextView(usingTextLayoutManager: false)
    private let keyInput: CompanionTerminalKeyInput
    private var renderScheduled = false
    private var lastRender = Date.distantPast
    private var followsOutput = true
    private var measuredSize = CGSize.zero
    private var resizeWork: DispatchWorkItem?
    private var fontSize: CGFloat = 13
    private static let inset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

    init(session: CompanionTerminalSession, colors: CompanionTerminalColors) {
        self.session = session; self.colors = colors
        keyInput = CompanionTerminalKeyInput(session: session)
        super.init(frame: .zero)
        keyInput.owner = self
        keyInput.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(keyInput)
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = Self.inset
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.delegate = self
        textView.accessibilityIdentifier = "terminal-output"
        textView.accessibilityLabel = "Terminal output"
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor), textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor), textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyColors() {
        keyInput.appearance = colors.background.luminance < 0.4 ? .dark : .light
        backgroundColor = UIColor(colors.background)
        textView.backgroundColor = UIColor(colors.background)
        textView.tintColor = UIColor(colors.cursor)
    }

    @objc private func tapped() {
        // A tap with text selected clears the selection; the next one brings the keyboard back.
        if textView.selectedRange.length == 0, !isFirstResponder { _ = becomeFirstResponder() }
    }

    // MARK: Size

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != measuredSize, bounds.width > 0, bounds.height > 0 else { return }
        measuredSize = bounds.size
        // Rotation and the keyboard animate the size; send the size it settles at.
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fitToSize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        if !session.scope.resizesPTY { fitToSize() }
    }

    private func cellSize(_ size: CGFloat) -> CGSize {
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return CGSize(width: ("M" as NSString).size(withAttributes: [.font: font]).width, height: font.lineHeight)
    }

    private func fitToSize() {
        let width = bounds.width - Self.inset.left - Self.inset.right
        let height = bounds.height - Self.inset.top - Self.inset.bottom
        guard width > 0, height > 0 else { return }
        if session.scope.resizesPTY {
            fontSize = 13
            let cell = cellSize(fontSize)
            session.resize(cols: max(20, Int(width / cell.width)), rows: max(5, Int(height / cell.height)))
        } else {
            // An agent's PTY keeps the desktop's columns: the text shrinks to fit them, down to a readable floor.
            let perPoint = cellSize(100).width / 100
            fontSize = min(13, max(6, (width / CGFloat(session.screen.cols) / perPoint).rounded(.down)))
        }
        setNeedsRender()
    }

    // MARK: Render

    /// Output can arrive hundreds of times a second; the screen redraws at most 30 times.
    func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        let delay = max(0, 1.0 / 30 - Date().timeIntervalSince(lastRender))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    private func render() {
        // Redrawing would clear a selection the user is making; it resumes once they're done.
        guard textView.selectedRange.length == 0 else { return }
        lastRender = Date()
        textView.attributedText = CompanionTerminalRenderer.attributed(session.screen, colors: colors, fontSize: fontSize,
                                                                      showCursor: isFirstResponder || !session.scope.resizesPTY)
        if followsOutput { scrollToBottom() }
    }

    private func scrollToBottom() {
        textView.layoutIfNeeded()
        let bottom = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        textView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let distance = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom - scrollView.contentOffset.y
        followsOutput = distance < 24
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.selectedRange.length == 0 { setNeedsRender() }
    }

    // MARK: Keyboard

    /// Typing goes to a small view of its own, so the output stays an accessible, selectable text view.
    override var isFirstResponder: Bool { keyInput.isFirstResponder }
    override func becomeFirstResponder() -> Bool { keyInput.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { keyInput.resignFirstResponder() }

    fileprivate func editingChanged(_ editing: Bool) {
        if editing { followsOutput = true }
        onEditingChanged?(editing)
        setNeedsRender()
    }

    /// The keyboard comes up as soon as the terminal is on screen, when it should.
    var focusWhenShown = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusWhenShown else { return }
        focusWhenShown = false
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }
}

/// The view that takes the keyboard: typing, Return and Delete, paste, and a hardware keyboard's keys.
final class CompanionTerminalKeyInput: UIView, UIKeyInput {
    private let session: CompanionTerminalSession
    weak var owner: CompanionTerminalUIView?
    var appearance: UIKeyboardAppearance = .dark

    init(session: CompanionTerminalSession) {
        self.session = session
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = "Terminal input"
        accessibilityIdentifier = "terminal-input"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { owner?.editingChanged(true) }
        return became
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.editingChanged(false) }
        return resigned
    }

    var hasText: Bool { true }
    func insertText(_ text: String) { owner?.editingChanged(true); session.type(text) }
    func deleteBackward() { session.press(.backspace) }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var inlinePredictionType: UITextInlinePredictionType { get { .no } set {} }
    var keyboardAppearance: UIKeyboardAppearance { get { appearance } set {} }

    override func paste(_ sender: Any?) { session.paste(UIPasteboard.general.string ?? "") }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) ? UIPasteboard.general.hasStrings : super.canPerformAction(action, withSender: sender)
    }

    /// A hardware keyboard's arrows, Escape and Ctrl-letters.
    override var keyCommands: [UIKeyCommand]? {
        let keys: [(String, CompanionTerminalKey)] = [(UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down),
                                                      (UIKeyCommand.inputLeftArrow, .left), (UIKeyCommand.inputRightArrow, .right),
                                                      (UIKeyCommand.inputEscape, .escape), (UIKeyCommand.inputHome, .home), (UIKeyCommand.inputEnd, .end),
                                                      (UIKeyCommand.inputPageUp, .pageUp), (UIKeyCommand.inputPageDown, .pageDown)]
        var commands = keys.map { input, _ in UIKeyCommand(input: input, modifierFlags: [], action: #selector(hardwareKey(_:))) }
        commands += "abcdefghijklmnopqrstuvwxyz[]\\".map { UIKeyCommand(input: String($0), modifierFlags: .control, action: #selector(hardwareKey(_:))) }
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func hardwareKey(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        if command.modifierFlags.contains(.control) { session.type(CompanionTerminalInput.control(input)); return }
        let keys: [String: CompanionTerminalKey] = [UIKeyCommand.inputUpArrow: .up, UIKeyCommand.inputDownArrow: .down, UIKeyCommand.inputLeftArrow: .left,
                                                    UIKeyCommand.inputRightArrow: .right, UIKeyCommand.inputEscape: .escape, UIKeyCommand.inputHome: .home,
                                                    UIKeyCommand.inputEnd: .end, UIKeyCommand.inputPageUp: .pageUp, UIKeyCommand.inputPageDown: .pageDown]
        if let key = keys[input] { session.press(key) }
    }
}

extension UIColor {
    convenience init(_ rgb: CompanionRGB) { self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
}

/// The screen as styled text: the theme's terminal colors, bold and italic faces, and the cursor as a block.
enum CompanionTerminalRenderer {
    static func attributed(_ screen: CompanionTerminalScreen, colors: CompanionTerminalColors, fontSize: CGFloat, showCursor: Bool) -> NSAttributedString {
        let regular = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        func font(_ style: CompanionTerminalScreen.Style) -> UIFont {
            let base = style.bold ? bold : regular
            guard style.italic, let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
            return UIFont(descriptor: descriptor, size: fontSize)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let result = NSMutableAttributedString()
        let newline = NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: paragraph])
        for (index, line) in screen.renderedLines(showCursor: showCursor).enumerated() {
            if index > 0 { result.append(newline) }
            for run in line {
                var (foreground, background) = colors.colors(for: run.style)
                if run.isCursor { background = colors.cursor; foreground = colors.background }
                var attributes: [NSAttributedString.Key: Any] = [.font: font(run.style), .foregroundColor: UIColor(foreground), .paragraphStyle: paragraph]
                if let background { attributes[.backgroundColor] = UIColor(background) }
                if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        if result.length == 0 { result.append(NSAttributedString(string: " ", attributes: [.font: regular])) }
        return result
    }
}
