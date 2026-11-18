import SwiftUI

// MARK: - 外壳：5 个 Tab + 自绘底部栏
//
// 2026-11-16 第二轮（老板反馈 ⑤）：Tab = **发现 / 我的收藏 / 识曲 / 下载**
// （资料库那页整页换成"我的收藏"，并挪到发现与识曲之间）。
// 2026-11-16 第四轮（老板反馈 ③）：**设置从收藏页右上角挪出来，自己占一个 Tab**，
// 齿轮从 FavoritesView 撤掉，设置页就是第五个 Tab。
// 搜索不占 Tab，入口在发现页最上方（上一轮改的）。
//
// 第三十二轮（2026-11-18，老板发来 Light Player 录屏）：
// 系统 TabView 的选中态只是 tint 变色，做不出"胶囊滑过去 + 文字长出来"，
// 所以这里换成**自绘容器**：导航状态仍由 AppRouter.tab 持有，但五个 NavigationStack
// 放进一个 ZStack 里按 visited 懒加载、一直保活——切回来时滚动位置、push 栈都还在。
// 底部栏是 JZTabBar（见 JZTabBar.swift），不占内容安全区，内容底边正好停在栏上沿，
// 迷你条 overlay 因此仍然"贴住底层栏"，r78 修过的那道缝不会再出现。
struct RootTabView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var downloads: DownloadManager

    /// 只在第一次进某个 Tab 时才建它的 NavigationStack：
    /// 识曲页里挂着一个跑 wasm 的 WKWebView，启动时不该被顺手建出来。
    @State private var visited: Set<AppRouter.Tab> = [.discover]

    private var activeDownloads: Int {
        downloads.items.filter { $0.status == .downloading || $0.status == .pending }.count
    }

    private var openPlayer: () -> Void {
        { router.showPlayer = true }
    }

    private var tabBinding: Binding<AppRouter.Tab> {
        Binding(get: { router.tab }, set: { newValue in
            if router.tab != newValue { router.tab = newValue }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPages
            JZTabBar(selection: tabBinding, downloadBadge: activeDownloads)
        }
        .tint(Tokens.Palette.vermilion)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .fullScreenCover(isPresented: Binding(get: { router.showPlayer },
                                             set: { router.showPlayer = $0 })) {
            NowPlayingView()
                .environment(player)
                .environment(library)
                .environment(settings)
                .environment(downloadFlow)
                .environment(router)
        }
        // 下载面板挂在根外壳上：搜索结果、资料库、下载页都往这里送一首歌，
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
        .onAppear {
            visited.insert(router.tab)
            drainIntents()
        }
        .onChange(of: router.tab) { _, newValue in
            visited.insert(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            // App Intent 会把 App 拉到前台；回到 active 时消费一次
            if phase == .active { drainIntents() }
            // r65：实时活动已下线，"退出后台还挂着灵动岛"这件事不会再发生，这里不再需要收尾
        }
    }

    // MARK: 五个 Tab 的页面

    private var tabPages: some View {
        ZStack {
            ForEach(AppRouter.Tab.allCases, id: \.self) { tab in
                if visited.contains(tab) {
                    page(for: tab)
                        .opacity(router.tab == tab ? 1 : 0)
                        .scaleEffect(router.tab == tab || reduceMotion ? 1 : 0.985)
                        .allowsHitTesting(router.tab == tab)
                        .accessibilityHidden(router.tab != tab)
                        .zIndex(router.tab == tab ? 1 : 0)
                }
            }
        }
        // 交叉淡变：新页 0.985 → 1，旧页 1 → 0。不左右滑，避免 Android 味。
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Tokens.Motion.tabContent,
                   value: router.tab)
    }

    @ViewBuilder
    private func page(for tab: AppRouter.Tab) -> some View {
        switch tab {
        case .discover:
            NavigationStack {
                DiscoverView()
                    .paperBackground()
                    .navigationTitle("发现")
            }
            .miniPlayerBar(onTap: openPlayer)
            .modifier(FirstVisitReveal())

        case .favorites:
            NavigationStack {
                FavoritesView()
                    .paperBackground()
            }
            .miniPlayerBar(onTap: openPlayer)
            .modifier(FirstVisitReveal())

        case .recognize:
            NavigationStack {
                RecognizeView()
                    .paperBackground()
                    .navigationTitle("识曲")
            }
            .miniPlayerBar(onTap: openPlayer)
            .modifier(FirstVisitReveal())

        case .downloads:
            NavigationStack {
                DownloadsTabView()
                    .paperBackground()
                    .navigationTitle("下载")
            }
            .miniPlayerBar(onTap: openPlayer)
            .modifier(FirstVisitReveal())

        case .settings:
            NavigationStack {
                SettingsView()
            }
            .miniPlayerBar(onTap: openPlayer)
            .modifier(FirstVisitReveal())
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

// MARK: - 首次进入时的淡入

/// 第一次插进 ZStack 的 Tab：从 0 淡到 1（后面的切换由外层交叉淡变负责）。
/// 不套这一层的话，首个渲染就是 opacity 1，"切过去"会显得硬。
private struct FirstVisitReveal: ViewModifier {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    revealed = true
                } else {
                    withAnimation(.easeOut(duration: 0.22)) { revealed = true }
                }
            }
    }
}
