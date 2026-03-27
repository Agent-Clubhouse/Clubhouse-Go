import SwiftUI

// MARK: - GitFileStatus Display

extension GitFileStatus {
    var icon: String {
        switch self {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .unknown: "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        case .unknown: .secondary
        }
    }
}

// MARK: - Git Log View

/// Displays a list of recent git commits for a project.
struct GitLogView: View {
    let projectId: String
    let projectName: String

    @Environment(AppStore.self) private var store
    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading git history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ErrorRetryView(
                    title: "Unable to Load",
                    message: error,
                    onRetry: { Task { await loadLog() } }
                )
            } else if commits.isEmpty {
                ContentUnavailableView {
                    Label("No Commits", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("No git history found for this project.")
                }
            } else {
                commitList
            }
        }
        .background(store.theme.baseColor)
        .navigationTitle("Git Log")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: GitCommit.self) { commit in
            CommitDetailView(projectId: projectId, commit: commit)
        }
        .task {
            await loadLog()
        }
    }

    private var commitList: some View {
        List(commits) { commit in
            NavigationLink(value: commit) {
                CommitRowView(commit: commit)
            }
            .listRowBackground(store.theme.surface0Color.opacity(0.5))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func loadLog() async {
        guard let instance = store.instance(forProject: projectId) else {
            error = "Not connected"
            isLoading = false
            return
        }
        guard let apiClient = instance.apiClient,
              let token = instance.token else {
            error = "Not connected"
            isLoading = false
            return
        }
        do {
            commits = try await apiClient.getGitLog(
                projectId: projectId, maxCommits: 50, token: token
            )
            isLoading = false
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Commit Row

private struct CommitRowView: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.shortMessage)
                .font(.body.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(commit.author, systemImage: "person")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(commit.displayHash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text(compactRelativeTime(from: commit.timestamp))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Commit Detail View

/// Shows the full diff for a single git commit.
struct CommitDetailView: View {
    let projectId: String
    let commit: GitCommit

    @Environment(AppStore.self) private var store
    @State private var diff: GitDiffResponse?
    @State private var isLoading = true
    @State private var error: String?
    @State private var expandedFiles: Set<String> = []

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading diff...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ErrorRetryView(
                    title: "Unable to Load",
                    message: error,
                    onRetry: { Task { await loadDiff() } }
                )
            } else if let diff {
                diffContent(diff)
            }
        }
        .background(store.theme.baseColor)
        .navigationTitle(commit.displayHash)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDiff()
        }
    }

    private func diffContent(_ diff: GitDiffResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                commitHeader

                if let stats = diff.stats {
                    statsRow(stats)
                }

                ForEach(diff.files) { file in
                    diffFileSection(file)
                }
            }
            .padding()
        }
    }

    private var commitHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.message)
                .font(.body)

            HStack(spacing: 12) {
                Label(commit.author, systemImage: "person")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(commit.hash)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(store.theme.surface0Color.opacity(0.5))
        )
    }

    private func statsRow(_ stats: GitDiffStats) -> some View {
        HStack(spacing: 16) {
            Label("\(stats.filesChanged) files", systemImage: "doc.on.doc")
                .font(.caption.weight(.medium))
            HStack(spacing: 4) {
                Text("+\(stats.totalAdditions)")
                    .foregroundStyle(.green)
                Text("-\(stats.totalDeletions)")
                    .foregroundStyle(.red)
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private func diffFileSection(_ file: GitDiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedFiles.contains(file.path) {
                        expandedFiles.remove(file.path)
                    } else {
                        expandedFiles.insert(file.path)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: file.status.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(file.status.color)

                    Text(file.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    if let additions = file.additions, let deletions = file.deletions {
                        HStack(spacing: 2) {
                            Text("+\(additions)")
                                .foregroundStyle(.green)
                            Text("-\(deletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.system(.caption2, design: .monospaced))
                    }

                    Image(systemName: expandedFiles.contains(file.path)
                          ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
            }
            .buttonStyle(.plain)
            .background(store.theme.surface1Color.opacity(0.5))

            if expandedFiles.contains(file.path), let patch = file.patch {
                DiffPatchView(patch: patch)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadDiff() async {
        guard let instance = store.instance(forProject: projectId) else {
            error = "Not connected"
            isLoading = false
            return
        }
        guard let apiClient = instance.apiClient,
              let token = instance.token else {
            error = "Not connected"
            isLoading = false
            return
        }
        do {
            diff = try await apiClient.getGitDiff(
                projectId: projectId, commitHash: commit.hash, token: token
            )
            isLoading = false
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Diff Patch View

/// Renders a unified diff patch with color-coded additions/deletions.
private struct DiffPatchView: View {
    let patch: String

    private var lines: [String] {
        patch.components(separatedBy: .newlines)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(lineColor(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(lineBackground(for: line))
            }
        }
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary.opacity(0.7)
    }

    private func lineBackground(for line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.08) }
        if line.hasPrefix("-") { return .red.opacity(0.08) }
        if line.hasPrefix("@@") { return .blue.opacity(0.05) }
        return .clear
    }
}
