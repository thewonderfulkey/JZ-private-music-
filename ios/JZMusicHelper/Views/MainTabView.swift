import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            SearchView()
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
            DownloadsView()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }
            HistoryView()
                .tabItem {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                }
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    MainTabView()
}
