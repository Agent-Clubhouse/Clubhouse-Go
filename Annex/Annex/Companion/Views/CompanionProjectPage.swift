import SwiftUI
#if DEBUG && targetEnvironment(simulator)
import Combine
import UIKit
import os
#endif

/// One project, opened from its header on Home: New agent and Wake with a message, the quick agents that
/// finished and wait to be read, the project's agents, and its Changes. The desktop's project start page
/// (Clubhouse `ProjectStartPage.tsx`) with the Changes view beside it (`ProjectChanges.tsx`).
struct CompanionProjectPage: View {
    @Bindable var store: CompanionStore
    var preferences: CompanionPreferences
    let project: CompanionProjectTarget
    var onNewAgent: (CompanionProjectTarget) -> Void
    @State private var waking = false
    @State private var hold: [CompanionTarget]?
    /// The agent and message from Wake with a message, held until the sheet has gone. Opening the chat while the
    /// sheet is still dismissing left its timeline blank on iOS 26.5 until it was scrolled.
    @State private var pendingWake: (target: CompanionTarget, message: String)?
    @State private var changes: CompanionChanges?
    @State private var changesError: String?
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionTerminal) private var terminal

    private var host: CompanionHost? { store.hosts.first { $0.id == project.hostID } }
    private var details: CompanionProject? { host?.projects.first { $0.id == project.projectID } }
    private var canOperate: Bool { host?.connection.canOperate == true }

    var body: some View {
        List {
            if let details {
                actions
                finished
                agents(details)
                changesSection
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder",
                                       description: Text("This project is no longer on its desktop, or the desktop is offline."))
                    .listRowBackground(Color.clear)
            }
        }
        .companionListStyle()
        .onScrollPhaseChange { _, phase in
            if phase == .idle { hold = nil }
            else if hold == nil { hold = agentTree?.all.map(\.id) }
        }
        .navigationTitle(details?.name ?? "Project")
        .toolbar {
            if let host, store.hosts.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { CompanionHostTag(name: host.name) }
            }
        }
        .sheet(isPresented: $waking, onDismiss: {
            guard let wake = pendingWake else { return }
            pendingWake = nil
            Task { await store.wake(wake.target, message: wake.message) }
        }) {
            CompanionWakeSheet(store: store, project: project) { pendingWake = ($0, $1) }
        }
        .task(id: canOperate) { if canOperate { await loadChanges() } }
    }

    // MARK: Sections

    private var actions: some View {
        let sleeping = store.sleepingAgents(in: project)
        return Section {
            HStack(spacing: 10) {
                Button { onNewAgent(project) } label: {
                    Label("New agent", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).companionProminentLabel()
                .disabled(!canOperate || host?.canSpawn != true)
                .accessibilityIdentifier("project-new-agent")
                Button { waking = true } label: {
                    Label("Wake with a message", systemImage: "sun.max").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canOperate || sleeping.isEmpty)
                .accessibilityIdentifier("project-wake")
                .accessibilityHint(sleeping.isEmpty ? "No agent here is asleep." : "Choose a sleeping agent and what it should do.")
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .lineLimit(1).minimumScaleFactor(0.8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            terminalButton
        }
    }

    /// A shell at the project root, as the desktop's Terminal tab opens with the project selected.
    @ViewBuilder private var terminalButton: some View {
        if let terminal, case let availability = terminal.availability(.project(project)), availability.isShown {
            Button { terminal.open(.project(project)) } label: {
                Label("Terminal", systemImage: "terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!availability.isAvailable)
            .accessibilityIdentifier("project-terminal")
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }

    /// The desktop's list: hidden when empty, newest first, each row dismissable, and Clear all.
    @ViewBuilder private var finished: some View {
        let runs = store.finished(in: project)
        if !runs.isEmpty {
            Section {
                ForEach(runs) { run in finishedRow(run) }
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Finished, waiting on you").font(.headline).foregroundStyle(Color(palette.label))
                    Text("\(runs.count)").font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    Spacer()
                    Button("Clear all") { Task { await store.clearFinished(in: project) } }
                        .font(.subheadline)
                        .accessibilityIdentifier("finished-clear-all")
                }
                .textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = store.finishedError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(palette.warning))
                            .accessibilityIdentifier("finished-error")
                    }
                    Text(store.sharesFinished(project) ? "Swipe a run to dismiss it. This list is shared with your desktop."
                                                       : "Swipe a run to dismiss it. This list is kept on your phone.")
                }
            }
        }
    }

    @ViewBuilder private func finishedRow(_ run: CompanionFinishedRun) -> some View {
        let label = TimelineView(.periodic(from: .now, by: 60)) { context in CompanionFinishedRow(run: run, now: context.date) }
        Group {
            // A run the desktop has forgotten has no chat left to open.
            if store.agent(for: run.target) != nil {
                NavigationLink(value: run.target) { label }
            } else {
                label
            }
        }
        .listRowBackground(CompanionCardBackground())
        .accessibilityIdentifier("finished-\(run.target.agentID)")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Dismiss", systemImage: "xmark", role: .destructive) { dismiss(run) }
        }
        .contextMenu {
            Button("Dismiss", systemImage: "xmark") { dismiss(run) }
        }
        .accessibilityAction(named: "Dismiss") { dismiss(run) }
    }

    private func dismiss(_ run: CompanionFinishedRun) {
        Task { await store.dismissFinished(run.target) }
    }

    private var agentTree: CompanionAgentTree? {
        details.map { CompanionAgentTree.build($0.agents.filter { !CompanionFinishedRuns.hasFinished($0) }, sort: preferences.projectSort, held: hold, lastActivity: store.lastActivity(of:)) }
    }

    /// The same forest and sleeping fold as Home; finished quick runs have their own section above.
    @ViewBuilder private func agents(_ details: CompanionProject) -> some View {
        if let tree = agentTree {
            let parentLines = CompanionAgentTree.parentLines(hosts: host.map { [$0] } ?? [])
            Section {
                if tree.active.isEmpty && tree.sleeping.isEmpty {
                    Text("No agents yet").foregroundStyle(Color(palette.secondaryLabel))
                        .listRowBackground(CompanionCardBackground())
                }
                CompanionAgentTreeRows(tree: tree, rows: tree.active, preferences: preferences, parentLines: parentLines)
                if !tree.sleeping.isEmpty {
                    CompanionAgentTreeFold(kind: "sleeping", projectID: "\(project.hostID)-\(project.projectID)",
                                           text: "\(tree.sleeping.count) sleeping", tree: tree, rows: tree.sleeping,
                                           preferences: preferences, parentLines: parentLines)
                }
            } header: {
                Text("Agents").font(.headline).foregroundStyle(Color(palette.label)).textCase(nil)
            }
        }
    }

    private var changesSection: some View {
        Section {
            NavigationLink {
                CompanionChangesView(store: store, project: project, initial: changes)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Changes")
                        Text(changesSummary).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(2)
                    }
                } icon: { Image(systemName: "plusminus") }
            }
            .disabled(!canOperate)
            .accessibilityIdentifier("project-changes")
            .listRowBackground(CompanionCardBackground())
        } footer: {
            Text("The project folder's uncommitted files. Read-only: commit and push on your desktop.")
        }
    }

    private var changesSummary: String {
        guard canOperate else { return "Reconnect to see this project's changes." }
        if let changesError { return changesError }
        guard let changes else { return "Reading…" }
        guard changes.isRepository else { return "Not a git repository" }
        let files = changes.files.isEmpty ? "No uncommitted changes" : "\(changes.files.count) changed file\(changes.files.count == 1 ? "" : "s")"
        return changes.branch.isEmpty ? files : "\(changes.branch) · \(files)"
    }

    private func loadChanges() async {
        do { changes = try await store.changes(for: project); changesError = nil }
        catch { changesError = error.localizedDescription }
    }
}

/// A finished run: its mission, when it finished, and how it ended.
struct CompanionFinishedRow: View {
    let run: CompanionFinishedRun
    let now: Date
    @Environment(\.companionPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(run.title).lineLimit(2)
                Spacer(minLength: 4)
                Text(CompanionFinishedRun.ago(run.completedAt, now: now))
                    .font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            }
            Text(run.detail).font(.subheadline)
                .foregroundStyle(Color(run.failed ? palette.error : palette.secondaryLabel))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The desktop composer's "Wake a sleeping agent": choose one, say what it should do, and its chat opens.
struct CompanionWakeSheet: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    /// Called with the chosen agent and the message as the sheet closes; the page wakes it once the sheet has gone.
    var onWake: (CompanionTarget, String) -> Void
    @State private var selection: CompanionTarget?
    @State private var message = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    #if DEBUG && targetEnvironment(simulator)
    @State private var focusMeasurements = CompanionWakeFocusMeasurements.makeIfEnabled()
    @Environment(\.scenePhase) private var scenePhase
    #endif

    private var sleeping: [CompanionAgent] { store.sleepingAgents(in: project) }
    private var chosen: CompanionAgent? { sleeping.first { $0.id == selection } }
    private var canWake: Bool {
        chosen != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.hosts.first { $0.id == project.hostID }?.connection.canOperate == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Agent", selection: $selection) {
                        ForEach(sleeping) { agent in Text(agent.name).tag(Optional(agent.id)) }
                    }
                    .accessibilityIdentifier("wake-agent-picker")
                }
                Section {
                    TextField("What should \(chosen?.name ?? "it") do?", text: $message, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($focused)
                        #if DEBUG && targetEnvironment(simulator)
                        .background {
                            if let focusMeasurements {
                                CompanionWakeFocusMeasurementHost(controller: focusMeasurements)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        #endif
                        .accessibilityIdentifier("wake-message")
                } footer: {
                    Text("It wakes and starts with this message. Its chat opens so you can follow along.")
                }
            }
            // Let the focus system choose the field when the sheet enters its hierarchy (#246).
            .defaultFocus($focused, true)
            .companionBackground()
            .scrollContentBackground(.hidden)
            .navigationTitle("Wake with a message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Wake") {
                        guard let target = selection else { return }
                        onWake(target, message)
                        dismiss()
                    }
                    .disabled(!canWake)
                    .accessibilityIdentifier("wake-send")
                }
            }
            .interactiveDismissDisabled(!message.isEmpty)
            .onAppear {
                if selection == nil { selection = sleeping.first?.id }
                #if DEBUG && targetEnvironment(simulator)
                focusMeasurements?.record("swiftui-appear", focused: focused)
                #endif
            }
        }
        .presentationDetents([.medium, .large])
        #if DEBUG && targetEnvironment(simulator)
        .onChange(of: focused, initial: true) { _, value in
            focusMeasurements?.record("focus-binding", focused: value)
        }
        .onChange(of: scenePhase, initial: true) { _, value in
            focusMeasurements?.record("swiftui-scene-\(value)", focused: focused)
        }
        .onDisappear { focusMeasurements?.record("swiftui-disappear", focused: focused) }
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Synthetic opt-in observation only. No focus setters, delegates, swizzling, gestures, polling or text reads.
private struct CompanionWakeFocusMeasurementHost: UIViewControllerRepresentable {
    let controller: CompanionWakeFocusMeasurements
    func makeUIViewController(context: Context) -> CompanionWakeFocusMeasurements { controller }
    func updateUIViewController(_ controller: CompanionWakeFocusMeasurements, context: Context) {}
    static func dismantleUIViewController(_ controller: CompanionWakeFocusMeasurements, coordinator: ()) {
        controller.finish()
    }
}

/// Retains MainActor teardown: UIViewController owns UIKit state and Combine cancellation resources.
@MainActor private final class CompanionWakeFocusMeasurements: UIViewController {
    private static let logger = Logger(subsystem: "com.Agent-Clubhouse.Go.wake-focus", category: "measurements")
    private var subscriptions = Set<AnyCancellable>()
    private var started: TimeInterval?
    private var sequence = 0
    private var layouts = 0
    private var lastFocus: Bool?
    private var finished = false

    static func makeIfEnabled() -> CompanionWakeFocusMeasurements? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"), arguments.contains("--wake-focus-measurements") else { return nil }
        return CompanionWakeFocusMeasurements()
    }

    override func loadView() {
        let anchor = CompanionWakeFocusMeasurementAnchor()
        anchor.measurements = self
        anchor.isUserInteractionEnabled = false
        anchor.accessibilityElementsHidden = true
        view = anchor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let names: [Notification.Name] = [
            UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification,
            UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification,
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
            UIScene.didActivateNotification, UIScene.willDeactivateNotification
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                MainActor.assumeIsolated { self?.record(notification.name.rawValue, notification: notification) }
            }.store(in: &subscriptions)
        }
        record("controller-loaded")
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); record("controller-will-appear") }
    override func viewIsAppearing(_ animated: Bool) { super.viewIsAppearing(animated); record("controller-is-appearing") }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); record("controller-did-appear") }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); record("controller-will-disappear") }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); record("controller-did-disappear") }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Layout is noisy; retain four boundaries without changing layout or scheduling another pass.
        if layouts < 4 { layouts += 1; record("controller-layout-\(layouts)") }
    }

    func finish() {
        record("dismantle")
        finished = true
        subscriptions.removeAll()
    }

    func record(_ event: String, focused: Bool? = nil, notification: Notification? = nil) {
        guard !finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if started == nil { started = now }
        if let focused { lastFocus = focused }
        // Event-driven only: no timer or work is scheduled to extend the 20-second/96-snapshot budget.
        guard sequence < 96, now - (started ?? now) <= 20 else {
            finished = true
            subscriptions.removeAll()
            print("[wake-focus] trace-limit")
            Self.logger.notice("trace-limit")
            return
        }
        sequence += 1
        var payload: [String: Any] = [
            "sequence": sequence, "seconds": now - (started ?? now), "uptime": now, "event": event,
            "focusBinding": lastFocus.map { $0 as Any } ?? NSNull(),
            "animationsEnabled": UIView.areAnimationsEnabled,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "anchorWindow": token(viewIfLoaded?.window)
        ]
        if let object = notification?.object as AnyObject? { payload["notificationObject"] = token(object) }
        if let frame = notification?.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            payload["keyboardEndFrame"] = rect(frame.cgRectValue)
        }
        let allScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scenes = allScenes.prefix(4)
        payload["sceneScanTruncated"] = allScenes.count > scenes.count
        payload["scenes"] = scenes.map { ["id": token($0), "activationState": $0.activationState.rawValue] as [String: Any] }
        let allWindows = scenes.flatMap(\.windows)
        let windows = allWindows.prefix(8)
        payload["windowScanTruncated"] = allWindows.count > windows.count
        payload["windows"] = windows.map { window in
            ["id": token(window), "scene": token(window.windowScene), "key": window.isKeyWindow,
             "hidden": window.isHidden, "level": window.windowLevel.rawValue,
             "presented": controllers(from: window.rootViewController, presented: true)] as [String: Any]
        }
        payload["anchorParents"] = controllers(from: parent, presented: false)
        var budget = 1024
        var inputs: [[String: Any]] = []
        var responders: [[String: Any]] = []
        for window in windows {
            var pending: [UIView] = [window]
            while budget > 0, let candidate = pending.popLast() {
                budget -= 1
                if candidate.isFirstResponder, responders.count < 8 {
                    responders.append(["id": token(candidate), "class": String(describing: type(of: candidate)), "window": token(candidate.window)])
                }
                if (candidate is UITextField || candidate is UITextView), inputs.count < 8 {
                    var value: [String: Any] = [
                        "id": token(candidate), "class": String(describing: type(of: candidate)),
                        "window": token(candidate.window), "firstResponder": candidate.isFirstResponder,
                        "canBecomeFirstResponder": candidate.canBecomeFirstResponder,
                        "hidden": candidate.isHidden, "alpha": candidate.alpha,
                        "interactive": candidate.isUserInteractionEnabled,
                        "frameInWindow": rect(candidate.convert(candidate.bounds, to: window))
                    ]
                    var ancestors: [[String: Any]] = []
                    var ancestor: UIView? = candidate
                    for _ in 0..<16 {
                        guard let current = ancestor else { break }
                        ancestors.append(["id": token(current), "class": String(describing: type(of: current)),
                                          "wakeIdentifier": current.accessibilityIdentifier == "wake-message", "hidden": current.isHidden])
                        ancestor = current.superview
                    }
                    value["ancestors"] = ancestors
                    if let field = candidate as? UITextField {
                        value["enabled"] = field.isEnabled
                        value["editing"] = field.isEditing
                        value["hasMarkedText"] = field.markedTextRange != nil
                    }
                    if let field = candidate as? UITextView {
                        value["editable"] = field.isEditable
                        value["selectable"] = field.isSelectable
                        value["hasMarkedText"] = field.markedTextRange != nil
                    }
                    inputs.append(value)
                }
                pending.append(contentsOf: candidate.subviews)
            }
        }
        payload["nativeInputs"] = inputs
        payload["firstResponders"] = responders
        payload["viewScanTruncated"] = budget == 0
        payload["nativeInputLimitReached"] = inputs.count == 8
        payload["responderLimitReached"] = responders.count == 8
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("[wake-focus] \(line)")
        Self.logger.notice("\(line, privacy: .public)")
    }

    private func controllers(from root: UIViewController?, presented: Bool) -> [[String: Any]] {
        var controller = root
        var values: [[String: Any]] = []
        for _ in 0..<12 {
            guard let current = controller else { break }
            values.append(["id": token(current), "class": String(describing: type(of: current)),
                           "window": token(current.viewIfLoaded?.window), "presenting": token(current.presentingViewController),
                           "beingPresented": current.isBeingPresented, "beingDismissed": current.isBeingDismissed,
                           "firstResponder": current.isFirstResponder,
                           "transitionAnimated": current.transitionCoordinator?.isAnimated ?? false,
                           "transitionInteractive": current.transitionCoordinator?.isInteractive ?? false])
            controller = presented ? current.presentedViewController : current.parent
        }
        return values
    }
    private func token(_ object: AnyObject?) -> String { object.map { String(describing: ObjectIdentifier($0)) } ?? "none" }
    private func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
}

/// Retains MainActor UIView teardown; the reverse link is weak and cannot keep the controller alive.
@MainActor private final class CompanionWakeFocusMeasurementAnchor: UIView {
    weak var measurements: CompanionWakeFocusMeasurements?
    override func didMoveToWindow() { super.didMoveToWindow(); measurements?.record("anchor-window") }
    override func didMoveToSuperview() { super.didMoveToSuperview(); measurements?.record("anchor-superview") }
}
#endif
