import SwiftUI

struct FileBrowserView: View {
    let projectId: String
    let projectName: String
    let path: String

    @Environment(AppStore.self) private var store
    @State private var nodes: [FileNode] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchText = ""

    private var isRoot: Bool { path == "." }

    private var breadcrumbs: [String] {
        guard !isRoot else { return [] }
        return path.components(separatedBy: "/").filter { !$0.isEmpty }
    }

    private var filteredNodes: [FileNode] {
        guard !searchText.isEmpty else { return nodes }
        return nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading files...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Unable to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if nodes.isEmpty {
                ContentUnavailableView {
                    Label("Empty Directory", systemImage: "folder")
                } description: {
                    Text("No files found at this path.")
                }
            } else {
                List {
                    if !breadcrumbs.isEmpty {
                        breadcrumbRow
                    }

                    ForEach(filteredNodes) { node in
                        if node.isDirectory {
                            NavigationLink(value: FileBrowserDestination.directory(
                                projectId: projectId,
                                projectName: projectName,
                                path: node.path,
                                name: node.name
                            )) {
                                FileRowView(node: node)
                            }
                            .listRowBackground(store.theme.surface0Color.opacity(0.5))
                        } else {
                            NavigationLink(value: FileBrowserDestination.file(
                                projectId: projectId,
                                path: node.path,
                                name: node.name
                            )) {
                                FileRowView(node: node)
                            }
                            .listRowBackground(store.theme.surface0Color.opacity(0.5))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Filter files")
                .overlay {
                    if filteredNodes.isEmpty && !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
        .background(store.theme.baseColor)
        .navigationTitle(isRoot ? projectName : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: FileBrowserDestination.gitLog(
                        projectId: projectId,
                        projectName: projectName
                    )) {
                        Label("Git Log", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .navigationDestination(for: FileBrowserDestination.self) { dest in
            switch dest {
            case .directory(let projId, let projName, let dirPath, _):
                FileBrowserView(projectId: projId, projectName: projName, path: dirPath)
            case .file(let projId, let filePath, _):
                FileContentView(projectId: projId, path: filePath)
            case .gitLog(let projId, let projName):
                GitLogView(projectId: projId, projectName: projName)
            }
        }
        .task {
            await loadTree()
        }
    }

    private var breadcrumbRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.quaternary)
                    }
                    Text(crumb)
                        .font(.caption)
                        .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .tertiary)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func loadTree() async {
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
            nodes = try await apiClient.getFileTree(
                projectId: projectId, path: path, depth: 1, token: token
            )
            isLoading = false
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Navigation Destinations

enum FileBrowserDestination: Hashable {
    case directory(projectId: String, projectName: String, path: String, name: String)
    case file(projectId: String, path: String, name: String)
    case gitLog(projectId: String, projectName: String)
}

// MARK: - File Row

struct FileRowView: View {
    let node: FileNode

    var body: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: node.isDirectory ? "folder.fill" : iconName(for: node.name))
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
        }
    }

    private func iconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "curlybraces"
        case "json": return "curlybraces.square"
        case "md", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "html", "css": return "globe"
        case "yml", "yaml", "toml": return "gearshape"
        case "sh", "zsh", "bash": return "terminal"
        case "lock": return "lock"
        default: return "doc"
        }
    }
}
