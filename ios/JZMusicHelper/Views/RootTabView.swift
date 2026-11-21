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
    @Environment(DiscoverFeed.self) private var discoverFeed
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var downloads: DownloadManager

    /// 只在第一次进某个 Tab 时才建它的 NavigationStack：
    /// 识曲页里挂着一个跑 wasm 的 WKWebView，启动时不该被顺手建出来。
    @State private var visited: Set<AppRouter.Tab> = [.discover]
    /// **真正在显示的页**（第 42 轮）：与 `router.tab` 分开。
    /// 点 Tab 时 `router.tab` 立刻变（底部栏动画先走），`shownTab` 晚一拍才跟 —— 见 `reveal(_:)`。
    @State private var shownTab: AppRouter.Tab = .discover

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
                .environment(router)
                .environmentObject(downloads)
        }
        .onAppear {
            visited.insert(router.tab)
            drainIntents()
            // 车载自动播放：连上车机 / 车载蓝牙就自动接着放（见 CarAudioAutoPlay）
            CarAudioAutoPlay.shared.attach(player: player, feed: discoverFeed, library: library)
        }
        .onChange(of: router.tab) { _, newValue in
            // tA（第 42 轮打点）：选中态提交，页面还没插 —— "点下去 App 有没有反应"只看这个数
            PerfProbe.tabSelected(newValue.rawValue)
            reveal(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            // App Intent 会把 App 拉到前台；回到 active 时消费一次
            if phase == .active {
                drainIntents()
                // B3（老板 2026-11-20）：回前台自愈。后台被挂起后取源任务可能已经死了，
                // 只靠"任务自己恢复"不够——应该出声却没出声时补一脚（用户自己暂停/来电打断不碰）。
                player.recoverIfStalled()
                // r121：回前台顺便核对一下热歌榜换没换。
                // 发现页的 Tab 是保活的（`RootTabView` 只建一次），`DiscoverView.task` 不会再跑，
                // 所以"App 在后台挂了两天"时榜单会一直停在旧日期——这里补一次（内部有 10 分钟节流）。
                Task { await discoverFeed.loadHotIfNeeded() }
            }
            // 退到后台先落一次播放断点：这时进程随时可能被系统收走，
            // 下次车载连上要靠它"接着上次没播完的接着放"。
            if phase == .background { player.flushSnapshot(force: true) }
            // r65：实时活动已下线，"退出后台还挂着灵动岛"这件事不会再发生，这里不再需要收尾
        }
    }

    // MARK: 五个 Tab 的页面

    private var tabPages: some View {
        ZStack {
            ForEach(AppRouter.Tab.allCases, id: \.self) { tab in
                // 第 42 轮：只看 `visited`（页面真的建好了才显示），不再用 `router.tab == tab` 兜底。
                // 兜底那一句会让"点 Tab 的这一帧"就去建新页 —— 真机 perf.log 里 t0→t1=507–813ms 就是它，
                // 而且 maxGap 676–952ms 说明这一帧连底部栏的动画都一起被冻住了。
                if visited.contains(tab) {
                    page(for: tab)
                        .opacity(tab == shownTab ? 1 : 0)
                        .allowsHitTesting(tab == shownTab)
                        .accessibilityHidden(tab != shownTab)
                        .zIndex(tab == shownTab ? 1 : 0)
                }
            }
        }
        // 第 41 轮 P0-1：这里**不再**挂 `.animation(_:value: router.tab)`。
        //
        // 原来那句会把"新页插入"也算进切 Tab 的动画事务：下载页有几百上千行，
        // 必须在动画第一帧之前建好 → 主线程被整页构建占住，底部栏的按压回弹/胶囊滑动
        // 跟着一起冻住（老板录屏里"点下载那一瞬间按钮变小一下"就是这么来的）。
        // 现在页面切换是即时的；首次进页的淡入仍由 `FirstVisitReveal` 自己负责（独立、很轻）。
        // 底部栏的动画在 JZTabBar 内部按 `selection` 值驱动，只作用于栏自身。
    }

    /// 第 42 轮：**页面插入推迟一拍**。
    ///
    /// 点 Tab 只改选中态（底部栏的胶囊/图标立刻走），先把这一帧提交出去；
    /// 下一拍再 `visited.insert` + `shownTab = tab`，让"建页"发生在用户已经看到栏动之后。
    /// 已经访问过的页不用建，直接切（保活路径，理应接近 0）。
    private func reveal(_ tab: AppRouter.Tab) {
        if visited.contains(tab) {
            shownTab = tab
            PerfProbe.tabCommitted(tab.rawValue)
            return
        }
        DispatchQueue.main.async {
            // 这一拍里又切走了就不插（避免"插了又切走"的瞬时构建）
            guard router.tab == tab else { return }
            visited.insert(tab)
            shownTab = tab
            // 建页发生在这次状态提交里；下一拍才等于"首屏行建完"
            DispatchQueue.main.async {
                PerfProbe.tabCommitted(tab.rawValue)
            }
        }
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
            // 第 42 轮：下载页**不做**首次淡入。
            // FirstVisitReveal 是 0.22s 的 opacity 动画，重页在动画期间会逐帧重算
            // （真机 maxGap 676–952ms 里就有一段来自这里）。这一页要的是"点了就在"。

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
