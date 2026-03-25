import SwiftUI

struct FileContentView: View {
    let projectId: String
    let path: String

    @Environment(AppStore.self) private var store
    @State private var content: String?
    @State private var isLoading = true
    @State private var error: String?

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading file...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Unable to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let content {
                ScrollView([.horizontal, .vertical]) {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(store.theme.baseColor)
        .navigationTitle(filename)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
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
            content = try await apiClient.getFileContent(
                projectId: projectId, path: path, token: token
            )
            isLoading = false
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            isLoading = false
        }
    }
}
