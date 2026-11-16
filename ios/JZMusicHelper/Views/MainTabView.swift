import SwiftUI

struct MainTabView: View {

    /// 全局播放引擎（@Observable，经 .environment 注入到各页与迷你播放条）
    /// View 的 `@State` 默认值在非隔离上下文里求值；引擎是 @MainActor 的，
    /// 用 assumeIsolated 桥一下（View 构造一定在主线程，这里不会触发断言）
    @State private var player = MainActor.assumeIsolated { PlayerEngine() }
    @State private var showNowPlaying = false

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
        .environment(player)
        .safeAreaInset(edge: .bottom) {
            if player.hasCurrentSong {
                MiniPlayerBar(onTap: { showNowPlaying = true })
                    .environment(player)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environment(player)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }
}

#Preview {
    MainTabView()
}
