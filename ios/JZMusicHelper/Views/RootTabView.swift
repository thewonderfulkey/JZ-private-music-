import SwiftUI

// MARK: - 外壳：5 个 Tab
//
// 设计稿 §1：发现 / 搜索 / 识曲 / 下载 / 资料库（设置收进资料库右上角）。
// Mini Player 用 `safeAreaInset` 常驻在 Tab 栏之上（设计稿 §2），点整条打开播放页。
struct RootTabView: View {

    enum AppTab: Hashable {
        case discover, search, recognize, downloads, library
    }

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @EnvironmentObject private var downloads: DownloadManager

    @State private var selection: AppTab = .discover
    @State private var showNowPlaying = false

    private var activeDownloads: Int {
        downloads.items.filter { $0.status == .downloading || $0.status == .pending }.count
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DiscoverView(onPlay: playSingle)
                    .paperBackground()
                    .navigationTitle("发现")
            }
            .tabItem { Label("发现", systemImage: "house.fill") }
            .tag(AppTab.discover)

            NavigationStack {
                SearchTabView()
                    .paperBackground()
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(AppTab.search)

            NavigationStack {
                RecognizeView()
                    .paperBackground()
                    .navigationTitle("识曲")
            }
            .tabItem { Label("识曲", systemImage: "waveform") }
            .tag(AppTab.recognize)

            NavigationStack {
                DownloadsTabView()
                    .paperBackground()
                    .navigationTitle("下载")
            }
            .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            .badge(activeDownloads)
            .tag(AppTab.downloads)

            NavigationStack {
                LibraryView()
                    .paperBackground()
            }
            .tabItem { Label("资料库", systemImage: "square.stack.fill") }
            .tag(AppTab.library)
        }
        .tint(Tokens.Palette.vermilion)
        .safeAreaInset(edge: .bottom) {
            if player.hasCurrentSong {
                MiniPlayerBar(onTap: { showNowPlaying = true })
                    .environment(player)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .padding(.bottom, 2)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environment(player)
                .environment(library)
                .environment(settings)
                .environment(downloadFlow)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        // 下载面板挂在 TabView 外壳上：播放页、搜索结果、资料库都往这里送一首歌，
        // 任何一处都不要自己弹 sheet（否则同一时刻能出现两个音质选择）。
        .sheet(isPresented: Binding(get: { downloadFlow.isPresented },
                                    set: { downloadFlow.isPresented = $0 })) {
            DownloadSheet()
                .environment(downloadFlow)
                .environment(settings)
                .environment(player)
                .environmentObject(downloads)
        }

    }

    private func playSingle(_ song: Song) {
        player.playSingle(song)
        library.recordPlayed(song)
    }
}
