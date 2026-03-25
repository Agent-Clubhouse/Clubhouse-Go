import SwiftUI

enum RootTab {
    case dashboard
    case projects
    case agents
    case canvas
    case instances
}

struct RootNavigationView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedTab: RootTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "house.fill", value: .dashboard) {
                DashboardView()
            }
            .badge(store.allPendingPermissions.count)

            Tab("Projects", systemImage: "folder.fill", value: .projects) {
                ProjectsTabView()
            }

            Tab("Agents", systemImage: "person.3.fill", value: .agents) {
                AllAgentsView()
            }

            Tab("Canvas", systemImage: "rectangle.on.rectangle.angled", value: .canvas) {
                CanvasTabView()
            }

            Tab("Instances", systemImage: "desktopcomputer", value: .instances) {
                InstancesView()
            }
        }
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return RootNavigationView()
        .environment(store)
}
