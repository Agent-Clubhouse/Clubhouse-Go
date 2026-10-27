import SwiftUI
import UIKit

/// The project root's uncommitted files with a status each, as the desktop's Changes view lists them.
/// Read-only: tap a file for its diff. Staging, committing and discarding stay on the desktop.
struct CompanionChangesView: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    @State private var changes: CompanionChanges?
    @State private var error: String?
    @Environment(\.companionPalette) private var palette

    init(store: CompanionStore, project: CompanionProjectTarget, initial: CompanionChanges? = nil) {
        self.store = store
        self.project = project
        _changes = State(initialValue: initial)
    }

    var body: some View {
        List {
            if let changes {
                if !changes.isRepository {
                    ContentUnavailableView("Not a git repository", systemImage: "folder",
                                           description: Text("This project's folder isn't tracked by git, so there are no changes to show."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        if changes.files.isEmpty {
                            Label("No uncommitted changes", systemImage: "checkmark.circle")
                                .foregroundStyle(Color(palette.secondaryLabel))
                                .listRowBackground(CompanionCardBackground())
                        }
                        ForEach(changes.files) { file in
                            NavigationLink {
                                CompanionFileDiffView(store: store, project: project, file: file)
                            } label: {
                                CompanionChangedFileRow(file: file)
                            }
                            .accessibilityIdentifier("changed-file-\(file.path)")
                            .listRowBackground(CompanionCardBackground())
                        }
                    } header: {
                        header(changes)
                    }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Changes unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                }
                .listRowBackground(Color.clear)
            } else {
                ProgressView("Reading changes…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .companionListStyle()
        .navigationTitle("Changes")
        .refreshable { await load() }
        .task { await load() }
    }

    private func header(_ changes: CompanionChanges) -> some View {
        var parts: [String] = []
        if !changes.branch.isEmpty { parts.append(changes.branch) }
        if changes.ahead > 0 { parts.append("\(changes.ahead) ahead") }
        if changes.behind > 0 { parts.append("\(changes.behind) behind") }
        parts.append("\(changes.files.count) uncommitted")
        return VStack(alignment: .leading, spacing: 4) {
            Text(parts.joined(separator: " · ")).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
            if changes.hasConflicts {
                Label("Merge conflicts. Resolve them on your desktop.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(Color(palette.warning))
            }
        }
        .textCase(nil)
    }

    private func load() async {
        do { changes = try await store.changes(for: project); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

extension CompanionChangedFile.Status {
    /// The desktop's `STATUS_TONE`: added green, modified amber, deleted red, renamed blue.
    func color(in palette: CompanionPalette) -> Color {
        switch self {
        case .added: Color(palette.success)
        case .modified: Color(palette.warning)
        case .deleted: Color(palette.error)
        case .renamed: Color(palette.info)
        }
    }
}

/// The status letter in its colour, the file name, then its folder, as on the desktop.
struct CompanionChangedFileRow: View {
    let file: CompanionChangedFile
    @Environment(\.companionPalette) private var palette
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(file.status.letter)
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(file.status.color(in: palette))
                .frame(minWidth: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                if let original = file.originalPath {
                    HStack(spacing: 4) {
                        Text("from").font(.caption)
                        Text(original).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                    }
                    .foregroundStyle(Color(palette.secondaryLabel))
                } else if !file.folder.isEmpty {
                    Text(file.folder).font(.caption.monospaced()).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.staged && !file.untracked {
                Text("Staged").font(.caption).foregroundStyle(Color(palette.secondaryLabel))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
    private var accessibilityText: String {
        var text = "\(file.status.label), \(file.name)"
        if let original = file.originalPath { text += ", from \(original)" } else if !file.folder.isEmpty { text += ", in \(file.folder)" }
        if file.staged && !file.untracked { text += ", staged" }
        return text
    }
}

/// One file's diff, read when it opens.
struct CompanionFileDiffView: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    let file: CompanionChangedFile
    @State private var diff: CompanionFileDiff?
    @State private var error: String?
    @Environment(\.companionPalette) private var palette

    var body: some View {
        Group {
            if let diff {
                switch diff.body {
                case .lines(let lines): CompanionDiffLinesView(lines: lines)
                case .binary:
                    ContentUnavailableView("Binary file", systemImage: "doc", description: Text("There's no diff to show for this file."))
                case .unchanged:
                    ContentUnavailableView("No changes to show", systemImage: "equal", description: Text("The text is the same; only the file's mode or metadata changed."))
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Diff unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView("Reading \(file.name)…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .companionBackground()
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { summary }
        .task { await load() }
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: 8) {
            Text(file.status.letter).font(.footnote.monospaced().weight(.semibold)).foregroundStyle(file.status.color(in: palette))
            Text(file.path).font(.footnote.monospaced()).lineLimit(1).truncationMode(.head)
                .foregroundStyle(Color(palette.secondaryLabel))
            Spacer(minLength: 4)
            if let diff, diff.added + diff.removed > 0 {
                Text("+\(diff.added)").foregroundStyle(Color(palette.success))
                Text("−\(diff.removed)").foregroundStyle(Color(palette.error))
            }
        }
        .font(.footnote.monospaced())
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diff-summary")
    }

    private func load() async {
        do { diff = try await store.diff(of: file, in: project); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

/// Diff lines in a monospaced grid that scrolls both ways, so long lines keep their shape instead of wrapping.
/// Added lines are green, removed red, with old and new line numbers in a gutter.
struct CompanionDiffLinesView: View {
    let lines: [CompanionDiffLine]
    @ScaledMetric(relativeTo: .footnote) private var fontSize: CGFloat = 12
    @Environment(\.companionPalette) private var palette

    /// Characters drawn per line at most. Minified files would otherwise make the grid miles wide.
    static let maximumColumns = 1_000

    var body: some View {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let layout = Layout(lines: lines, font: font)
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        row(lines[index], text: layout.texts[index], gutter: layout.gutter)
                    }
                }
                .padding(.vertical, 8)
                .frame(width: max(geometry.size.width, layout.width), alignment: .leading)
                // A short diff starts at the top rather than floating in the middle.
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .accessibilityIdentifier("diff-lines")
        }
        .font(Font(font))
    }

    private func row(_ line: CompanionDiffLine, text: String, gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            if line.kind == .hunk {
                Text(text).foregroundStyle(Color(palette.secondaryLabel)).padding(.leading, 8)
            } else {
                Text(line.oldNumber.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(marker(line.kind)).foregroundStyle(markerColor(line.kind)).frame(width: gutter / 2)
                Text(text)
            }
        }
        .foregroundStyle(line.kind == .hunk ? Color(palette.secondaryLabel) : Color(palette.label))
        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, line.kind == .hunk ? 4 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(line, text: text))
    }

    private func marker(_ kind: CompanionDiffLine.Kind) -> String {
        switch kind { case .added: "+"; case .removed: "−"; case .context, .hunk: " " }
    }
    private func markerColor(_ kind: CompanionDiffLine.Kind) -> Color {
        switch kind { case .added: Color(palette.success); case .removed: Color(palette.error); default: Color(palette.secondaryLabel) }
    }
    private func background(_ kind: CompanionDiffLine.Kind) -> Color {
        switch kind {
        case .added: Color(palette.success).opacity(palette.isDark ? 0.2 : 0.14)
        case .removed: Color(palette.error).opacity(palette.isDark ? 0.2 : 0.12)
        case .hunk: Color(palette.fill)
        case .context: .clear
        }
    }
    private func accessibilityLabel(_ line: CompanionDiffLine, text: String) -> String {
        let content = text.trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : text
        switch line.kind {
        case .added: return "Added, line \(line.newNumber ?? 0): \(content)"
        case .removed: return "Removed, line \(line.oldNumber ?? 0): \(content)"
        case .context: return "Line \(line.newNumber ?? 0): \(content)"
        case .hunk: return "Changes from line \(line.newNumber ?? line.oldNumber ?? 0)"
        }
    }

    /// Each line as drawn (tabs as four spaces, cut at `maximumColumns`), and how wide the grid must be for the longest.
    struct Layout {
        var texts: [String]
        var gutter: CGFloat
        var width: CGFloat

        init(lines: [CompanionDiffLine], font: UIFont) {
            let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
            texts = lines.map { line in
                let text = line.text.replacingOccurrences(of: "\t", with: "    ")
                return text.count > CompanionDiffLinesView.maximumColumns ? String(text.prefix(CompanionDiffLinesView.maximumColumns)) + "…" : text
            }
            let largest = lines.map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
            gutter = CGFloat(max(3, String(largest).count) + 1) * advance
            // Monospaced ASCII is a column count; anything else (CJK, emoji) is measured.
            let widest = texts.map { text in
                text.allSatisfy(\.isASCII) ? CGFloat(text.count) * advance : (text as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
            width = gutter * 2.5 + widest + 16
        }
    }
}
