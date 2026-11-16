import SwiftUI

// MARK: - 外壳：5 个 Tab
//
// 设计稿 §1：发现 / 搜索 / 识曲 / 下载 / 资料库（设置收进资料库右上角）。
// Mini Player 用 `safeAreaInset` 常驻在 Tab 栏之上（设计稿 §2），点整条打开播放页。
//
// Tab 的选择状态放在 `AppRouter`（不是本地 @State）：App Intents（快捷指令 / Siri）
// 要能把 App 直接带到"识曲"或"搜索"，那条请求在回到前台时由这里消费。
struct RootTabView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var downloads: DownloadManager

    @State private var showNowPlaying = false

    private var activeDownloads: Int {
        downloads.items.filter { $0.status == .downloading || $0.status == .pending }.count
    }

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
            NavigationStack {
                DiscoverView(onPlay: playSingle, onOpenSearch: { router.tab = .search })
                    .paperBackground()
                    .navigationTitle("发现")
            }
            .tabItem { Label("发现", systemImage: "house.fill") }
            .tag(AppRouter.Tab.discover)

            NavigationStack {
                SearchTabView()
                    .paperBackground()
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(AppRouter.Tab.search)

            NavigationStack {
                RecognizeView()
                    .paperBackground()
                    .navigationTitle("识曲")
            }
            .tabItem { Label("识曲", systemImage: "waveform") }
            .tag(AppRouter.Tab.recognize)

            NavigationStack {
                DownloadsTabView()
                    .paperBackground()
                    .navigationTitle("下载")
            }
            .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            .badge(activeDownloads)
            .tag(AppRouter.Tab.downloads)

            NavigationStack {
                LibraryView()
                    .paperBackground()
            }
            .tabItem { Label("资料库", systemImage: "square.stack.fill") }
            .tag(AppRouter.Tab.library)
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
                                    set: { downloadFlow.isPresented = $0 }),
               onDismiss: { downloadFlow.dismiss() }) {
            DownloadSheet()
                .environment(downloadFlow)
                .environment(settings)
                .environment(player)
                .environmentObject(downloads)
        }
        .onAppear { drainIntents() }
        .onChange(of: scenePhase) { _, phase in
            // App Intent 会把 App 拉到前台；回到 active 时消费一次
            if phase == .active { drainIntents() }
        }

    }

    private func playSingle(_ song: Song) {
        player.playSingle(song)
        library.recordPlayed(song)
    }

    // MARK: App Intents

    private func drainIntents() {
        for request in IntentInbox.shared.takeAll() {
            handle(request)
        }
    }

    private func handle(_ request: IntentInbox.Request) {
        switch request {
        case .playFavorites:
            let favorites = library.favorites
            guard !favorites.isEmpty else {
                router.tab = .library
                return
            }
            player.replaceQueue(favorites, shuffle: true)
            library.recordPlayed(favorites.first!)
            router.tab = .library
        case .startRecognition:
            router.tab = .recognize
            router.pendingRecognize = true
        case .search(let keyword):
            router.pendingSearch = keyword
            router.tab = .search
        }
    }
}
