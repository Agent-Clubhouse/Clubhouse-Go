import SwiftUI

enum RootTab {
    case dashboard
    case clubhouses
    case projects
    case agents
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

            Tab("Clubhouses", systemImage: "desktopcomputer", value: .clubhouses) {
                AnnexesTabView()
            }

            Tab("Projects", systemImage: "folder.fill", value: .projects) {
                ProjectsTabView()
            }

            Tab("Agents", systemImage: "person.3.fill", value: .agents) {
                AllAgentsView()
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
