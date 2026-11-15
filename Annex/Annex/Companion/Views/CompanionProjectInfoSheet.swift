import SwiftUI

/// Read-only project information. Paths come from the catalog; defaults use the existing create-options read.
struct CompanionProjectInfoSheet: View {
    @Bindable var store: CompanionStore
    let project: CompanionProjectTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette

    var body: some View {
        NavigationStack {
            Group {
                if let entry = store.projectEntry(containing: project) {
                    List {
                        Section {
                            LabeledContent("Project", value: entry.project.name)
                            if entry.isLinked {
                                let count = Set(entry.members.map { $0.host.id }).count
                                Text("\(count) linked desktop\(count == 1 ? "" : "s")")
                                    .foregroundStyle(Color(palette.secondaryLabel))
                            }
                        }
                        .listRowBackground(CompanionCardBackground())
                        ForEach(entry.members) { member in
                            CompanionProjectInfoMemberSection(store: store, member: member, title: entry.label(for: member))
                        }
                        Section {} footer: { Text("Change these project settings on your desktop.") }
                    }
                    .companionListStyle()
                } else {
                    ContentUnavailableView("Project unavailable", systemImage: "folder",
                                           description: Text("This project is no longer in the desktop catalog."))
                }
            }
            .navigationTitle("Project info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .accessibilityIdentifier("project-info-sheet")
    }
}

private struct CompanionProjectInfoReadContext: Equatable {
    let project: CompanionProjectTarget
    let endpoint: String
    let epoch: String?
    let canRead: Bool
    let attempt: Int
}

private struct CompanionProjectInfoMemberSection: View {
    let store: CompanionStore
    let member: CompanionProjectMember
    let title: String
    @State private var defaults: CompanionProjectInfoDefaults?
    @State private var loading = false
    @State private var error: String?
    @State private var attempt = 0

    private var context: CompanionProjectInfoReadContext {
        .init(project: member.id, endpoint: member.host.endpoint, epoch: member.host.controlEpoch,
              canRead: member.host.connection.canOperate && member.host.canCreateDurable, attempt: attempt)
    }

    var body: some View {
        Section {
            CompanionProjectInfoRows(member: member, defaults: defaults, loading: loading, error: error) { attempt += 1 }
        } header: { Text(title) }
        .task(id: context) { await load() }
    }

    private func load() async {
        defaults = nil
        error = nil
        loading = false
        guard context.canRead else { return }
        loading = true
        do {
            let options = try await store.createOptions(for: member.id)
            guard !Task.isCancelled else { return }
            defaults = CompanionProjectInfoDefaults(options: options)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Shared by the live sheet and hosted visual checks. No row can mutate project settings.
struct CompanionProjectInfoRows: View {
    let member: CompanionProjectMember
    var defaults: CompanionProjectInfoDefaults?
    var loading = false
    var error: String?
    var retry: () -> Void = {}
    @Environment(\.companionPalette) private var palette

    var body: some View {
        Group {
            if let path = member.project.path, !path.isEmpty {
                LabeledContent("Path") {
                    Text(path).font(.subheadline.monospaced()).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .accessibilityIdentifier("project-info-path-\(member.host.id)-\(member.project.id)")
            }
            if let access = defaults?.access {
                LabeledContent("Default access", value: access)
                    .accessibilityIdentifier("project-info-access-\(member.host.id)-\(member.project.id)")
            }
            if let servers = defaults?.mcpServers {
                LabeledContent("MCP defaults") {
                    Text(servers.isEmpty ? "None" : servers.joined(separator: "\n"))
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("project-info-mcp-\(member.host.id)-\(member.project.id)")
            }
            if loading {
                HStack { ProgressView(); Text("Reading project defaults…") }.foregroundStyle(Color(palette.secondaryLabel))
            } else if let error {
                Text(error).foregroundStyle(Color(palette.warning))
                Button("Try again", action: retry)
            } else if !member.host.connection.canOperate {
                Text("Connect to this desktop to read its project defaults.").foregroundStyle(Color(palette.secondaryLabel))
            } else if !member.host.canCreateDurable {
                Text("This desktop doesn't offer project defaults to the phone.").foregroundStyle(Color(palette.secondaryLabel))
            } else if (member.project.path?.isEmpty ?? true), defaults?.access == nil, defaults?.mcpServers == nil {
                Text("No project details were supplied by this desktop.").foregroundStyle(Color(palette.secondaryLabel))
            }
        }
        .listRowBackground(CompanionCardBackground())
    }
}
