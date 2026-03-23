import SwiftUI

enum RootTab {
    case dashboard
    case agents
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

            Tab("Agents", systemImage: "person.3.fill", value: .agents) {
                AllAgentsView()
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
