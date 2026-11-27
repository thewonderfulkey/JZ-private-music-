import SwiftUI
import UIKit

// MARK: - 发现（老板反馈 ①②⑥ 的全部改在这里）
//
// 结构（自上而下，第三十轮口径）：
//   ① 搜索框：**搜索入口搬到发现页最上方**（不再占一个 Tab）
//   ② 歌单广场：横滑封面卡（热门歌单，132×132 + 播放量角标）
//   ③ 歌手大全：横滑圆头像（5 个 64，名字 + 粉丝）
//   ④ 最近播放：小封面横排（有播放记录才出现）
//   ⑤ 我的歌单：**导入过歌单才出现**（设置 → 导入歌单），横滑宽卡；无导入时这里什么都没有
//   ⑥ 最新单曲：酷我官方歌单（每日新歌），横滑宽卡（版式对齐网易云「你关注的艺人新动向」）
//   ⑦ 猜你喜欢：三行一页、左右翻页的列表卡（对齐 Android 的 HorizontalPager 口径）；
//      **没有播放记录时整块隐藏**（和「我的歌单」同一套显示逻辑），听了歌再自动出现
//   ⑧ 热门音乐：同一套分页，行内带名次
//
// 第二十九轮起所有数据链都是真数据；第三十轮把「编辑精选」（本地池 + 逐首解析）下线，
// 换成歌单广场 / 歌手大全——点开即播，不再有"占位行 → 正式行"的等待。
struct DiscoverView: View {

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DiscoverFeed.self) private var feed
    @Environment(SquareFeed.self) private var squareFeed
    @Environment(ArtistFeed.self) private var artistFeed
    /// 导入进来的歌单（本地快照）。没有导入时这一整块不渲染，最近播放直接接最新单曲。
    @Environment(MyPlaylistStore.self) private var myPlaylists
    @Environment(AppRouter.self) private var router
    /// 回到前台时按本地日核对一次（见 body 里的 `.onChange(of: scenePhase)`）
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSearch = false
    /// 助眠页（push 进导航栈，不是全屏 cover）
    @State private var showSleep = false
    /// 轻提示（换一批之后的确认）
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                searchEntry
                // 发现页 2.0：BANNER 轮播（网易首页取图，只跳站内歌单；老板 2026-11-27：不提供关闭，当作常驻模块）
                if feed.showsBanner {
                    DiscoverBannerCarousel(banners: feed.banners)
                }
                artistSection
                recentSection
                myPlaylistsSection
                newSongsSection
                guessSection
                hotSection
                // 发现页 2.0：热门音乐的第二行（网易官方热歌榜，与酷我榜并列）
                neteaseHotSection
                // 第三十五轮（老板）：歌单广场放到最下面
                squareSection
                // 迷你播放条是浮层（第五轮反馈 ⑨：它会压住最后一条），末尾显式让出高度
                MiniPlayerSpacer()
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(text: toast)
            }
        }
        .navigationTitle("发现")
        // 侧边栏入口（和网易云一样，发现页左上角三横钮）
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                SidebarMenuButton { router.showSidebar = true }
            }
        }
        // 助眠页：进新页面而不是盖全屏，底部五格栏保持可见
        .navigationDestination(isPresented: $showSleep) { SleepView() }
        .onChange(of: router.pendingSleep) { _, want in
            guard want else { return }
            router.pendingSleep = false
            // 注意：这里**不暂停歌**。以前一进页面就把歌停了，但"打开页面"不等于"要放白噪音"。
            // 真正的互斥放在助眠开口那一刻（SleepAudioEngine.onWillStart → RootTabView）。
            showSleep = true
        }
        .navigationDestination(isPresented: $showSearch) {
            SearchView()
        }
        .refreshable {
            await refreshEverything()
        }
        .task {
            // 第二十一轮（老板 r84："一打开什么都在加载，能不能加载一次就别再加载"）：
            // 每个模块都有**当天缓存**，feed 的 init 里已经同步读盘，所以这里多数情况下第一帧就有内容。
            //
            // 第三十轮：歌单广场 / 歌手大全也并进这一趟——老板要的"同进度、当天只拉一次"，
            // 就是这一层：一个入口进去，四块酷我数据一起加载 / 一起判缓存。
            //
            // 2026-11-27（开屏又开始"时不时顿一下"）：**等开屏退场再发请求**。
            // 首页是在开屏底下照常挂载的，动画那 1.5 秒里同时拉网络/解图，主线程一被抢就顿；
            // 缓存已经在 init 里同步读过，所以动画一退场照样有内容，不会闪骨架。
            // 手上什么都没有（刚装好第一次开）就不等——等完也是骨架，不如让数据先跑。
            if feed.hasPrimedContent {
                await LaunchGate.shared.waitForSplash()
            }
            await loadEverything()
            if !library.recentSongs.isEmpty {
                await feed.refreshGuessIfStale(recent: library.recentSongs)
            }
            openSearchIfIntentAsked()
            // "当天新上架的歌单立刻能看到"：1KB 探测最新歌单首条 id，变了才重取第一页
            Task { await squareFeed.probeNewestIfNeeded() }
        }
        // App 挂着跨过 0 点（或第二天从后台回来）：TabView 不会重建这一页，
        // `.task` 也不会再跑，所以回到前台时自己按本地日核对一次——
        // 当天已加载过的话这里就是几次缓存判断，一个请求都不发。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await loadEverything()
                await squareFeed.probeNewestIfNeeded()
            }
        }
        .onChange(of: router.pendingSearch) { _, _ in openSearchIfIntentAsked() }
        // 新用户第一次听完一首歌：猜你喜欢从"整块隐藏"变成"该出现了"——立刻算第一轮，
        // 否则要等下次进发现页才长出来（`root` 的 Tab 是保活的，`.task` 不会重跑）。
        .onChange(of: library.recentSongs.isEmpty) { _, isEmpty in
            guard !isEmpty else { return }
            Task { await feed.refreshGuessIfStale(recent: library.recentSongs) }
        }
    }

    /// 首屏这一趟：热门 + 最新单曲（`feed`）+ 歌单广场 + 歌手大全，四块并发
    private func loadEverything() async {
        async let daily: Void = feed.loadDaily()
        async let square: Void = squareFeed.loadIfNeeded()
        async let artists: Void = artistFeed.loadIfNeeded()
        _ = await (daily, square, artists)
    }

    /// 下拉刷新：四块一起重取（都强制，不吃缓存）
    private func refreshEverything() async {
        async let daily: Void = feed.refreshAll(recent: library.recentSongs)
        async let square: Void = squareFeed.refreshAll()
        async let artists: Void = artistFeed.refresh()
        _ = await (daily, square, artists)
    }

    /// 快捷指令「搜索歌曲」把词塞进 router，回到发现页时自动把搜索页推到前台
    private func openSearchIfIntentAsked() {
        guard router.pendingSearch != nil else { return }
        showSearch = true
    }

    /// 轻提示：1.4 秒后自动消失（连点会重置计时，不会提前消失）
    private func flash(_ text: String) {
        Haptics.success()
        withAnimation(Tokens.Motion.stateChange) { toast = text }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }

    // MARK: 顶部搜索入口（反馈 ⑥）

    /// r66（老板反馈 ②"点搜索会卡一下非常明显"）：这里从 `Button { showSearch = true }` 改成
    /// **NavigationLink**。`showSearch` 是发现页自己的 State，一点就整个发现页 body 重算一遍——
    /// 而这一页里有两组 `TabView(.page)` 分页器（UIKit 背书的翻页容器），跟着重建就会卡一下。
    /// NavigationLink 由导航栈自己处理 push，发现页的状态不变，也就不重算。
    /// `showSearch` 只留给快捷指令（App Intent）走"程序化 push"。
    private var searchEntry: some View {
        NavigationLink {
            SearchView()
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("搜索歌曲、歌手、专辑")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("四家一起找")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(minHeight: 42)
            // r78（老板："发现页每一个模块的边框太重，切深色特别丑"）：**去掉描边**，
            // 只留纸卡底。功能与命中区不变（contentShape 还是整个胶囊）。
            .background(Capsule().fill(Tokens.Palette.paperElevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityLabel("搜索歌曲、歌手、专辑")
        .accessibilityHint("打开搜索页")
    }

    // MARK: 歌单广场（第三十轮：替换编辑精选）

    private var squareSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Text("歌单广场")
                    .font(FontRole.sectionTitle)
                Text(squareFeed.hotTotal > 0 ? "\(squareFeed.hotTotal) 张" : "每日更新")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !squareFeed.hot.isEmpty {
                    NavigationLink("查看全部") { PlaylistSquareView() }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            Group {
                switch squareFeed.hotState {
                case .idle, .loading:
                    SquareSkeletonRow()
                case .failed:
                    retryBlock("歌单广场暂时取不到，稍后再试") {
                        Task { await squareFeed.refresh(.hot) }
                    }
                case .loaded:
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Tokens.Spacing.s) {
                            ForEach(squareFeed.hot.prefix(8)) { summary in
                                NavigationLink {
                                    PlaylistDetailView(summary: summary)
                                } label: {
                                    PlaylistCoverCard(summary: summary)
                                }
                                .buttonStyle(.pressSubtle)
                            }
                        }
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: 歌手大全（第三十轮：替换编辑精选）

    private var artistSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Text("歌手大全")
                    .font(FontRole.sectionTitle)
                Text(artistFeed.total > 0 ? "\(artistFeed.total) 位" : "热门歌手")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !artistFeed.items.isEmpty {
                    NavigationLink("查看全部") { ArtistDirectoryView() }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            Group {
                switch artistFeed.state {
                case .idle, .loading:
                    ArtistSkeletonRow()
                case .failed:
                    retryBlock("歌手列表暂时取不到，稍后再试") {
                        Task { await artistFeed.refresh() }
                    }
                case .loaded:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Tokens.Spacing.xs) {
                            // 2026-11-27（老板）：一行只放 5 个太少 → 露 12 个，横滑看，再点「查看全部」
                            ForEach(artistFeed.items.prefix(12)) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist)
                                } label: {
                                    ArtistCircleCell(artist: artist)
                                }
                                .buttonStyle(.pressSubtle)
                            }
                        }
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: 最近播放

    @ViewBuilder
    private var recentSection: some View {
        if !library.recentSongs.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                DiscoverSectionHeader(title: "最近播放", meta: "\(library.recentSongs.count) 首")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Spacing.s) {
                        // r63（老板反馈 ④）：点最近播放里的一首，**整列最近播放**就是队列——
                        // 原来只把这一首塞进队列，播完列表循环还是它自己，听着像"永远只有一首"。
                        ForEach(Array(library.recentSongs.prefix(8).enumerated()),
                                id: \.element.id) { index, song in
                            MediaCard(title: song.name,
                                      subtitle: song.singer,
                                      artwork: AnyView(SongArtwork(song: song, size: 104,
                                                                   radius: Tokens.Radius.artworkSmall)),
                                      size: 104,
                                      onTap: {
                                          play(library.recentSongs, at: index)
                                      })
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                }
            }
        }
    }

    // MARK: 我的歌单（导入过才有；版式对齐「最新单曲」的横滑宽卡）
    //
    // 老板 2026-11-19：模块**只在导入过歌单以后存在**。没导入时这里返回 EmptyView，
    // 最近播放下面直接就是最新单曲——不占位、不留标题、不加"去导入"的引导条。
    // 入口在设置页（`ImportPlaylistView`），发现页自己不提供导入按钮。
    @ViewBuilder
    private var myPlaylistsSection: some View {
        if !myPlaylists.playlists.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text("我的歌单")
                        .font(FontRole.sectionTitle)
                    Text("\(myPlaylists.playlists.count) 个")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: Tokens.Spacing.xxs)
                    NavigationLink("查看全部") { MyPlaylistsView() }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Tokens.Spacing.s) {
                        // 点歌单是"进去看"，不是"立刻播"——播放动作在详情页的「播放全部」/行点击上
                        ForEach(myPlaylists.playlists) { playlist in
                            NavigationLink {
                                MyPlaylistDetailView(playlistID: playlist.id)
                            } label: {
                                MyPlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.pressSubtle)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: 最新单曲（第二十九轮：版式对齐网易云「你关注的艺人新动向」）
    //
    // 老板给的参照是飞书开发群那段录屏（网易云「推荐」页）：标题左边一叠圆形头像、
    // 右边一排**横滑宽卡**——左半是方形封面，右半是同一张封面糊开的底色，卡上依次是
    // 「新单曲」角标、歌名、歌手、「收录于《专辑》」、右下播放三角。
    //
    // 我们没有人家的"关注关系"，所以：
    //   · 标题左边那叠圆头像用**前三首的封面**代替（都是图，视觉上是同一件事）；
    //   · 卡片里每一条都是真歌（rid + 封面 + 发行日），点卡就播，队列是这一排新歌。
    private var newSongsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.xs) {
                newSongsAvatars
                Text("最新单曲")
                    .font(FontRole.sectionTitle)
                Text("每日更新")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: Tokens.Spacing.xxs)
                if feed.newState == .loaded, !feed.newReleases.isEmpty {
                    NavigationLink("查看全部") { NewSongsView() }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            Group {
                switch feed.newState {
                case .idle, .loading:
                    NewReleaseCardSkeleton()
                case .failed:
                    retryBlock("新歌暂时取不到，稍后再试") {
                        Task { await feed.refreshNewSongs() }
                    }
                case .loaded:
                    newSongsRow
                }
            }
        }
    }

    /// 标题左边那叠圆头像（网易云是"你关注的艺人"，我们取前三首的封面）
    private var newSongsAvatars: some View {
        HStack(spacing: -8) {
            ForEach(newSongs.prefix(3)) { release in
                SongArtwork(song: release.song, size: 22, radius: 11)
                    .overlay(Circle().strokeBorder(Tokens.Palette.paper, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }

    private var newSongsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Tokens.Spacing.s) {
                ForEach(Array(newSongs.enumerated()), id: \.element.id) { index, release in
                    NewReleaseCard(release: release) {
                        // 点哪张卡，这一排新歌就是队列（与最近播放同一口径）
                        play(newSongs.map(\.song), at: index)
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.vertical, 2)
        }
    }

    /// 模块里这一排：接口一页 100 首，只露前 12 张卡
    ///
    /// 2026-11-27（发现页 2.0 Task 7）：这里是**酷我 + 网易交替合并**的结果
    /// （酷我「每日最新单曲推荐」+ 网易「新歌榜」），去重与交替顺序在 `DiscoverLatestRules`。
    private var newSongs: [KuwoPlaylist.Release] {
        Array(feed.latestReleases.prefix(KuwoPlaylist.moduleCards))
    }

    // MARK: 猜你喜欢（反馈 ②：三行一页的列表卡）
    //
    // 第四十三轮（老板 2026-11-19）：显示逻辑对齐「我的歌单」——**新用户没有历史数据时整块隐藏**，
    // 不占位、不留标题、也不再给"多听几首会长出来"的空态条；有了播放记录再自动出现。
    // 判断依据就是 `recentSongs`：猜你喜欢的输入（歌手关键词）只从最近播放里抽，
    // 没有最近播放就注定一条也长不出来。
    @ViewBuilder
    private var guessSection: some View {
        if !library.recentSongs.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                DiscoverSectionHeader(
                    title: "猜你喜欢",
                    meta: "根据你的播放",
                    actionTitle: feed.guessState == .loading ? nil : "换一批",
                    action: {
                        Haptics.refresh()
                        Task {
                            await feed.nextGuessRound(recent: library.recentSongs)
                            flash("猜你喜欢已换一批")
                        }
                    })

                Group {
                    if feed.guessState == .loading {
                        SkeletonRows(count: 3)
                    } else if feed.guessState == .failed {
                        retryBlock("推荐暂时取不到，稍后再试") {
                            Task { await feed.refreshGuess(recent: library.recentSongs) }
                        }
                    } else if feed.guessSongs.isEmpty {
                        // 有历史但这一轮没挑出歌（搜索全失败）：给一句实话，不显示空态引导
                        StatusLine(kind: .info("暂时没有合适的推荐"))
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                    } else {
                        songListCard(count: feed.guessSongs.count) { index in
                            let song = feed.guessSongs[index]
                            Button {
                                play(feed.guessSongs, at: index)
                            } label: {
                                DiscoverSongRow(song: song,
                                                reason: guessReason(for: song),
                                                showReason: true,
                                                rank: nil)
                            }
                            .buttonStyle(.press)
                        }
                    }
                }
            }
        }
    }

    /// 推荐理由：能对上最近播放的歌手就写「因为你在听 X」，否则退一句实话
    private func guessReason(for song: Song) -> String {
        if let hit = library.recentSongs.first(where: {
            !$0.singer.isEmpty && NameMatch.singerMatches($0.singer, song.singer)
        }) {
            return "因为你在听 \(hit.singer)"
        }
        return "根据你的播放记录"
    }

    // MARK: 热门音乐（榜单优先，种子词兜底；与猜你喜欢同一套分页）

    /// 第二十轮（老板）：数据源改成「酷我热歌榜优先」，原种子词逻辑做兜底；
    /// **样式和页数一律不动**（3 行一页、共 7 页、行样式 `DiscoverSongRow`），
    /// 只有「查看全部」进榜单页看完整 100 首。
    private var hotSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Text("热门音乐")
                    .font(FontRole.sectionTitle)
                // 副标题说实话：真榜就写「酷我热歌榜」，回落时就写「四平台合并」，
                // 不把兜底结果也标成官方榜；还没加载完只写"每日更新"，别抢着报来源。
                Text(hotMeta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !feed.hotSongs.isEmpty {
                    NavigationLink("查看全部") { ChartSongsView(chart: .hot) }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            Group {
                switch feed.hotState {
                case .idle, .loading:
                    SkeletonRows(count: 3)
                case .failed:
                    retryBlock("榜单暂时取不到，稍后再试") {
                        Task { await feed.refreshHot() }
                    }
                case .loaded:
                    songListCard(count: min(feed.hotSongs.count, 21)) { index in
                        let song = feed.hotSongs[index]
                        Button {
                            play(Array(feed.hotSongs.prefix(21)), at: index)
                        } label: {
                            DiscoverSongRow(song: song,
                                            reason: song.singer,
                                            showReason: false,
                                            rank: index + 1)
                        }
                        .buttonStyle(.press)
                    }
                }
            }
        }
    }

    /// 热门音乐的副标题：加载中只说"每日更新"，加载完再报来源（真榜 / 四平台兜底）
    private var hotMeta: String {
        guard feed.hotState == .loaded else { return "每日更新" }
        return feed.hotFromChart ? "酷我热歌榜 · 每日更新" : "四平台合并 · 每日更新"
    }

    // MARK: 网易热歌榜（发现页 2.0 Task 7：热门音乐的第二行，与酷我榜并列）
    //
    // 为什么单独一块而不是把两个榜都塞进「热门音乐」：老板认过的是原来那块版式
    // （3 行一页、7 页），塞两遍会把模块撑成两倍高；并列成"第二行独立模块"更清楚，
    // 副标题也说实话（这是网易官方榜，不是四平台合并）。
    private var neteaseHotSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Text("网易热歌榜")
                    .font(FontRole.sectionTitle)
                Text("每日更新")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !feed.neteaseHot.isEmpty {
                    NavigationLink("查看全部") { NeteaseChartSongsView() }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            Group {
                switch feed.neteaseHotState {
                case .idle, .loading:
                    SkeletonRows(count: 3)
                case .failed:
                    retryBlock("网易热歌榜暂时取不到，稍后再试") {
                        Task { await feed.refreshNeteaseHot() }
                    }
                case .loaded:
                    songListCard(count: min(feed.neteaseHot.count, DiscoverSourceIDs.hotRowLimit)) { index in
                        let song = feed.neteaseHot[index]
                        Button {
                            play(Array(feed.neteaseHot.prefix(DiscoverSourceIDs.hotRowLimit)), at: index)
                        } label: {
                            DiscoverSongRow(song: song,
                                            reason: song.singer,
                                            showReason: false,
                                            rank: index + 1)
                        }
                        .buttonStyle(.press)
                    }
                }
            }
        }
    }

    // MARK: 卡片外壳

    /// 三行一页的列表：分页控件 + 行
    ///
    /// r78：去掉 0.5pt 描边。
    /// r79（老板："我们每个模块后面还带着阴影，不够纯粹，就是纯色的背景"）：
    /// 连**纸卡底也去掉**——模块直接落在页面纯色背景上，和网易云那种"标题 + 行"的版式一致。
    /// 分页器、行、点击行为一律不动，行本身仍靠行距和封面来分区。
    private func songListCard<Row: View>(count: Int,
                                         @ViewBuilder row: @escaping (Int) -> Row) -> some View {
        PagedRows(count: count, perPage: 3, content: row)
            .padding(.vertical, Tokens.Spacing.xxs)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    private func retryBlock(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            StatusLine(kind: .error(message))
            Button("重试", action: retry)
                .font(.footnote)
                .foregroundStyle(Tokens.Palette.vermilion)
                .buttonStyle(.press)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    // MARK: 播放

    private func play(_ songs: [Song], at index: Int) {
        guard songs.indices.contains(index) else { return }
        // 第三十九轮：让行高亮先铺满，再起播/弹悬浮栏/开播放页
        RowTap.afterHighlight {
            player.play(queue: songs, startAt: index)
            library.recordPlayed(songs[index])
            router.showPlayer = true
        }
    }
}

// MARK: - 区块标题

struct DiscoverSectionHeader: View {
    let title: String
    var meta: String?
    var actionTitle: String?
    var action: (() -> Void)?

    /// 显式 init：可选参数的默认值不依赖 memberwise 的推断，读起来也明确
    init(title: String, meta: String? = nil, actionTitle: String? = nil,
         action: (() -> Void)? = nil) {
        self.title = title
        self.meta = meta
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
            Text(title)
                .font(FontRole.sectionTitle)
            if let meta {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .buttonStyle(.press)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }
}

// MARK: - 最新单曲卡（网易云「艺人新动向」式横滑宽卡）
//
// 版式（对着群里录屏那一帧量的，按 390pt 宽折算）：
//   · 整卡 ≈ 300×100，圆角 12，卡片间距 12，整排可横滑；
//   · 左半是 100×100 方形封面（撑满卡高），右半是同一张封面**糊开**当底色 + 黑色 42% 压暗，
//     保证白字在亮封面上也读得清；
//   · 卡上：左上「新单曲」角标 → 歌名（白色半粗）→ 歌手（白 72%）→「收录于《专辑》」（白 55%），
//     右下播放三角。
//
// 尺寸用 `@ScaledMetric` 跟着 Dynamic Type 长（宽 = 高 × 3），不写死 pt：
// AX5 下整卡会变大，但仍然只是"一张大卡"，不会把文字截掉。
struct NewReleaseCard: View {

    let release: KuwoPlaylist.Release
    let onPlay: () -> Void

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 100
    /// 封面自己拉一份：卡片右半要用**同一张图**糊成底，`SongArtwork` 拿不到原图
    @State private var cover: UIImage?

    private var cardWidth: CGFloat { max(cardHeight * 3, 1) }
    private var panelWidth: CGFloat { max(cardWidth - cardHeight, 1) }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 0) {
                artwork
                panel
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.pressSubtle)
        .task(id: release.id) {
            let loaded = await CoverImageCache.shared.image(for: release.song)
            guard !Task.isCancelled else { return }
            cover = loaded
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("轻点播放，后面一排新歌会接着播")
    }

    private var artwork: some View {
        Group {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    // 卡片整块是深底白字（照片卡），缺图占位也用深底，别跟着浅色主题变白
                    Color.black.opacity(0.55)
                    Image(systemName: "music.note")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .frame(width: cardHeight, height: cardHeight)
        .clipped()
    }

    private var panel: some View {
        ZStack(alignment: .bottomTrailing) {
            background
            VStack(alignment: .leading, spacing: 2) {
                Text("新单曲")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(0.22))
                    )
                Spacer(minLength: 2)
                Text(release.song.name)
                    .font(FontRole.songTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(release.song.singer.isEmpty ? "未知歌手" : release.song.singer)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                if !release.albumLine.isEmpty {
                    Text(release.albumLine)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.leading, Tokens.Spacing.s)
            // 右下播放三角的位置让出来，长歌名宁可省略也不压到三角上
            .padding(.trailing, Tokens.Spacing.xxl)
            .padding(.vertical, Tokens.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(Tokens.Spacing.s)
        }
        .frame(width: panelWidth, height: cardHeight)
        .clipped()
    }

    /// 右半的底色：同一张封面糊开 + 压暗；没有封面就用深色兜底（仍然是深底白字）
    ///
    /// `scaleEffect(1.2)` 是为了让模糊的软边落到裁切框外——不放大时，blur 会在卡片接缝处
    /// 透出一条纸色，看起来像卡片裂了。
    @ViewBuilder
    private var background: some View {
        if let cover {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .frame(width: panelWidth, height: cardHeight)
                .scaleEffect(1.2)
                .blur(radius: 16)
                .overlay(Color.black.opacity(0.42))
        } else {
            Color.black.opacity(0.72)
        }
    }

    private var accessibilityText: String {
        var parts = ["新单曲", release.song.name]
        if !release.song.singer.isEmpty { parts.append(release.song.singer) }
        if !release.albumLine.isEmpty { parts.append(release.albumLine) }
        if !release.releaseDate.isEmpty { parts.append(release.releaseDate) }
        return parts.joined(separator: "，")
    }
}

/// 卡片骨架：只占位不出字（高度跟随 Dynamic Type，避免 AX5 时和真卡拉不齐）
struct NewReleaseCardSkeleton: View {

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 100

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: cardHeight * 3, height: cardHeight)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .accessibilityHidden(true)
    }
}

// MARK: - 列表行（猜你喜欢 / 热门音乐共用）

struct DiscoverSongRow: View {
    let song: Song
    var reason: String
    /// 猜你喜欢：副行显示推荐理由；热门：副行只显示歌手
    var showReason: Bool
    /// 热门音乐的名次（从 1 开始）；猜你喜欢传 nil
    var rank: Int?

    init(song: Song, reason: String, showReason: Bool, rank: Int? = nil) {
        self.song = song
        self.reason = reason
        self.showReason = showReason
        self.rank = rank
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            if let rank {
                Text(String(format: "%02d", rank))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(rank <= 3 ? Tokens.Palette.vermilion : Color.secondary)
                    .frame(width: 26, alignment: .trailing)
            }

            SongArtwork(song: song, size: 46, radius: Tokens.Radius.artworkSmall)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if showReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Tokens.Palette.vermilion)
                            .lineLimit(1)
                    }
                    Text(song.singer.isEmpty ? "未知歌手" : song.singer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Tokens.Spacing.xxs)

            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 56)
        // r79：卡片底撤掉之后，行里那 8pt 内缩会让文字比区块标题多缩 8pt（看着歪），
        // 所以内缩交给外层统一给 `pageMargin`——发现页和热门榜单两处都对齐标题。
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("轻点播放")
    }

    private var accessibilityText: String {
        let prefix = rank.map { "第 \($0) 名，" } ?? ""
        let lead = showReason ? "\(reason)，" : ""
        return "\(prefix)\(song.name)，\(lead)\(song.singer)"
    }
}

// MARK: - 三行一页的横向分页列表

/// 与 Android「猜你喜欢 / 热门音乐」同一套翻页口径：一页 3 行、左右滑、翻页指示做成一排小胶囊。
/// 高度必须给死（TabView 的分页容器没有固有高度），所以行高走 `@ScaledMetric` 跟随 Dynamic Type。
struct PagedRows<Content: View>: View {

    let count: Int
    let perPage: Int
    let content: (Int) -> Content

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 60
    @State private var page = 0

    /// 显式写 init 而不是靠 memberwise：`@ViewBuilder` 要落到参数上，
    /// 属性上的 result builder 到底传不传给 memberwise init 这件事，不同 Swift 版本表现不一样。
    init(count: Int, perPage: Int, @ViewBuilder content: @escaping (Int) -> Content) {
        self.count = count
        self.perPage = perPage
        self.content = content
    }

    private var pageCount: Int { max(1, (count + perPage - 1) / perPage) }

    var body: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            TabView(selection: $page) {
                ForEach(0..<pageCount, id: \.self) { p in
                    VStack(spacing: 0) {
                        ForEach(0..<perPage, id: \.self) { i in
                            let index = p * perPage + i
                            Group {
                                if index < count {
                                    content(index)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .tag(p)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: rowHeight * CGFloat(perPage))

            if pageCount > 1 {
                pageDots
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<pageCount, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Color.primary.opacity(0.55) : Color.primary.opacity(0.15))
                    .frame(width: i == page ? 14 : 5, height: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Tokens.Spacing.s)
        .padding(.bottom, 2)
        .animation(.easeInOut(duration: 0.2), value: page)
        .accessibilityHidden(true)
    }
}

// MARK: - 十六进制色

extension Color {
    /// `Color(hex: 0xF0B45A)`——只给发现页的分类主题色用（设计令牌之外唯一的例外，
    /// 因为类别色本身是数据，不属于主题）
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
