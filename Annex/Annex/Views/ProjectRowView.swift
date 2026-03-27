import SwiftUI

struct ProjectRowView: View {
    let project: Project
    let agentCount: Int
    @Environment(AppStore.self) private var store

    private var projectColor: Color {
        AgentColor.color(for: project.color)
    }

    private var runningCount: Int {
        store.agents(for: project).filter { $0.status == .running }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            // Color accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(projectColor)
                .frame(width: 4, height: 40)

            ProjectIconView(
                name: project.name,
                displayName: project.displayName,
                iconData: store.projectIcons[project.id]
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(project.label)
                    .font(.body.weight(.medium))

                HStack(spacing: 6) {
                    Text("\(agentCount) agent\(agentCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if runningCount > 0 {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                            Text("\(runningCount) running")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return List {
        ProjectRowView(project: MockData.projects[0], agentCount: 2)
        ProjectRowView(project: MockData.projects[1], agentCount: 3)
    }
    .environment(store)
}
