import SwiftUI

// MARK: - 外壳：5 个 Tab
//
// 2026-11-16 第二轮（老板反馈 ⑤）：Tab = **发现 / 我的收藏 / 识曲 / 下载**
// （资料库那页整页换成"我的收藏"，并挪到发现与识曲之间）。
// 2026-11-16 第四轮（老板反馈 ③）：**设置从收藏页右上角挪出来，自己占一个 Tab**，
// 齿轮从 FavoritesView 撤掉，设置页就是第五个 Tab。
// 搜索不占 Tab，入口在发现页最上方（上一轮改的）。
//
// 迷你播放条挂在**每个 Tab 的 NavigationStack** 上（`miniPlayerBar`，浮层 + 列表末尾占位），
// 不是挂在 TabView 上——挂在 TabView 上会盖住 Tab 栏。
//
// 播放页是 `fullScreenCover`（③：原来用 sheet，看起来像"拉起一张布"）。
struct RootTabView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var downloads: DownloadManager

    private var activeDownloads: Int {
        downloads.items.filter { $0.status == .downloading || $0.status == .pending }.count
    }

    private var openPlayer: () -> Void {
        { router.showPlayer = true }
    }

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { newValue in
            if router.tab != newValue { Haptics.tabChanged() }
            router.tab = newValue
        })) {
            NavigationStack {
                DiscoverView()
                    .paperBackground()
                    .navigationTitle("发现")
            }
            .miniPlayerBar(onTap: openPlayer)
            .tabItem { Label("发现", systemImage: "house.fill") }
            .tag(AppRouter.Tab.discover)

            NavigationStack {
                FavoritesView()
                    .paperBackground()
            }
            .miniPlayerBar(onTap: openPlayer)
            .tabItem { Label("我的收藏", systemImage: "heart.fill") }
            .tag(AppRouter.Tab.favorites)

            NavigationStack {
                RecognizeView()
                    .paperBackground()
                    .navigationTitle("识曲")
            }
            .miniPlayerBar(onTap: openPlayer)
            .tabItem { Label("识曲", systemImage: "waveform") }
            .tag(AppRouter.Tab.recognize)

            NavigationStack {
                DownloadsTabView()
                    .paperBackground()
                    .navigationTitle("下载")
            }
            .miniPlayerBar(onTap: openPlayer)
            .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            .badge(activeDownloads)
            .tag(AppRouter.Tab.downloads)

            NavigationStack {
                SettingsView()
            }
            .miniPlayerBar(onTap: openPlayer)
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
            .tag(AppRouter.Tab.settings)
        }
        .tint(Tokens.Palette.vermilion)
        .fullScreenCover(isPresented: Binding(get: { router.showPlayer },
                                             set: { router.showPlayer = $0 })) {
            NowPlayingView()
                .environment(player)
                .environment(library)
                .environment(settings)
                .environment(downloadFlow)
                .environment(router)
        }
        // 下载面板挂在 TabView 外壳上：搜索结果、资料库、下载页都往这里送一首歌，
        // 任何一处都不要自己弹 sheet（否则同一时刻能出现两个音质选择）。
        // `!router.showPlayer` 是闸门：播放页是全屏 cover，盖着根视图的时候根视图弹不出 sheet，
        // 那种情况下由播放页自己的 sheet 负责（见 NowPlayingView），两边共用同一个 isPresented。
        .sheet(isPresented: Binding(get: { downloadFlow.isPresented && !router.showPlayer },
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
            // r65：实时活动已下线，"退出后台还挂着灵动岛"这件事不会再发生，这里不再需要收尾
        }
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
                router.tab = .favorites
                return
            }
            player.replaceQueue(favorites, shuffle: true)
            library.recordPlayed(favorites.first!)
            router.tab = .favorites
            router.showPlayer = true
        case .startRecognition:
            router.tab = .recognize
            router.pendingRecognize = true
        case .search(let keyword):
            router.pendingSearch = keyword
            router.tab = .discover
        }
    }
}
