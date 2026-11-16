import SwiftUI

// MARK: - 外壳：4 个 Tab
//
// 2026-11-16 改版（老板反馈 ⑥）：**搜索不再占一个 Tab**，入口放到发现页最上方 →
// 所以 Tab 收回 4 个：发现 / 识曲 / 下载 / 资料库（设置仍在资料库右上角）。
//
// 迷你播放条挂在**每个 Tab 的 NavigationStack** 上（`miniPlayerInset`），
// 不是挂在 TabView 上——挂在 TabView 上会盖住 Tab 栏（反馈 ⑤ 的后半句）。
//
// 播放页是 `fullScreenCover`（反馈 ③：原来用 sheet，看起来像"拉起一张布"，底下页面还露着）。
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

    private var activeDownloads: Int {
        downloads.items.filter { $0.status == .downloading || $0.status == .pending }.count
    }

    private var openPlayer: () -> Void {
        { router.showPlayer = true }
    }

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
            NavigationStack {
                DiscoverView()
                    .paperBackground()
                    .navigationTitle("发现")
            }
            .miniPlayerInset(onTap: openPlayer)
            .tabItem { Label("发现", systemImage: "house.fill") }
            .tag(AppRouter.Tab.discover)

            NavigationStack {
                RecognizeView()
                    .paperBackground()
                    .navigationTitle("识曲")
            }
            .miniPlayerInset(onTap: openPlayer)
            .tabItem { Label("识曲", systemImage: "waveform") }
            .tag(AppRouter.Tab.recognize)

            NavigationStack {
                DownloadsTabView()
                    .paperBackground()
                    .navigationTitle("下载")
            }
            .miniPlayerInset(onTap: openPlayer)
            .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            .badge(activeDownloads)
            .tag(AppRouter.Tab.downloads)

            NavigationStack {
                LibraryView()
                    .paperBackground()
            }
            .miniPlayerInset(onTap: openPlayer)
            .tabItem { Label("资料库", systemImage: "square.stack.fill") }
            .tag(AppRouter.Tab.library)
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
