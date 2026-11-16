import SwiftUI

// MARK: - 发现（老板反馈 ①②⑥ 的全部改在这里）
//
// 结构（自上而下，v2.2 口径）：
//   ① 搜索框：**搜索入口搬到发现页最上方**（不再占一个 Tab）
//   ② 编辑精选：横向长方形纸卡（对齐 Android `EditorCard` 150×66dp 的比例），不再是 160×160 大方块
//   ③ 最近播放：小封面横排（有播放记录才出现）
//   ④ 猜你喜欢：三行一页、左右翻页的列表卡（对齐 Android 的 HorizontalPager 口径）
//   ⑤ 热门音乐：同一套分页，行内带名次
//
// 三条数据链都是真数据（与 Android 同口径）：编辑精选是内置池按天轮换、热门是种子词实时搜索、
// 猜你喜欢从最近播放抽歌手再搜——搜不到就显示失败态 + 重试，不放假歌糊页面。
struct DiscoverView: View {

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DiscoverFeed.self) private var feed
    @Environment(AppRouter.self) private var router

    /// 编辑精选「换一批」的轮次：只在本次会话内叠加，不写盘（跨天本来就会换）
    @State private var rotation = 0
    @State private var showSearch = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                searchEntry
                editorSection
                recentSection
                guessSection
                hotSection
                // 迷你播放条是浮层（第五轮反馈 ⑨：它会压住最后一条），末尾显式让出高度
                MiniPlayerSpacer()
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .navigationTitle("发现")
        .navigationDestination(isPresented: $showSearch) {
            SearchView()
        }
        .refreshable {
            await feed.refreshHot()
            await feed.refreshGuess(recent: library.recentSongs)
        }
        .task {
            await feed.loadHotIfNeeded()
            if feed.guessState == .idle, !library.recentSongs.isEmpty {
                await feed.refreshGuess(recent: library.recentSongs)
            }
            openSearchIfIntentAsked()
        }
        .onChange(of: router.pendingSearch) { _, _ in openSearchIfIntentAsked() }
    }

    /// 快捷指令「搜索歌曲」把词塞进 router，回到发现页时自动把搜索页推到前台
    private func openSearchIfIntentAsked() {
        guard router.pendingSearch != nil else { return }
        showSearch = true
    }

    // MARK: 顶部搜索入口（反馈 ⑥）

    private var searchEntry: some View {
        Button {
            showSearch = true
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
            .background(Capsule().fill(Tokens.Palette.paperElevated))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.press)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityLabel("搜索歌曲、歌手、专辑")
        .accessibilityHint("打开搜索页")
    }

    // MARK: 编辑精选（反馈 ①：长方形卡）

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            DiscoverSectionHeader(title: "编辑精选", meta: "每日换一批",
                                  actionTitle: "换一批",
                                  action: {
                                      Haptics.refresh()
                                      withAnimation(Tokens.Motion.stateChange) { rotation += 1 }
                                  })

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.xs) {
                    ForEach(DiscoverCatalog.playlists) { playlist in
                        NavigationLink {
                            EditorPlaylistView(playlist: playlist, rotation: rotation)
                        } label: {
                            EditorPlaylistCard(playlist: playlist)
                        }
                        .buttonStyle(.press)
                        .accessibilityLabel("\(playlist.title)，20 首，每日换一批")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
                .padding(.vertical, 2)
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
                                          Haptics.tap()
                                          play(library.recentSongs, at: index)
                                      })
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                }
            }
        }
    }

    // MARK: 猜你喜欢（反馈 ②：三行一页的列表卡）

    private var guessSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            DiscoverSectionHeader(
                title: "猜你喜欢",
                meta: library.recentSongs.isEmpty ? nil : "根据你的播放",
                actionTitle: (library.recentSongs.isEmpty || feed.guessState == .loading) ? nil : "换一批",
                action: {
                    Haptics.refresh()
                    Task { await feed.nextGuessRound(recent: library.recentSongs) }
                })

            Group {
                if library.recentSongs.isEmpty {
                    GuessEmptyGuide()
                } else if feed.guessState == .loading {
                    SkeletonRows(count: 3)
                } else if feed.guessState == .failed || feed.guessSongs.isEmpty {
                    if feed.guessState == .failed {
                        retryBlock("推荐暂时取不到，稍后再试") {
                            Task { await feed.refreshGuess(recent: library.recentSongs) }
                        }
                    } else {
                        GuessEmptyGuide()
                    }
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

    /// 推荐理由：能对上最近播放的歌手就写「因为你在听 X」，否则退一句实话
    private func guessReason(for song: Song) -> String {
        if let hit = library.recentSongs.first(where: {
            !$0.singer.isEmpty && NameMatch.singerMatches($0.singer, song.singer)
        }) {
            return "因为你在听 \(hit.singer)"
        }
        return "根据你的播放记录"
    }

    // MARK: 热门音乐（反馈 ②：与猜你喜欢同一套分页）

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                Text("热门音乐")
                    .font(FontRole.sectionTitle)
                Text("每日更新")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !feed.hotSongs.isEmpty {
                    NavigationLink("查看全部") { HotChartView() }
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

    // MARK: 卡片外壳

    /// 三行一页的列表卡：分页控件 + 纸卡底 + 细描边
    private func songListCard<Row: View>(count: Int,
                                         @ViewBuilder row: @escaping (Int) -> Row) -> some View {
        PagedRows(count: count, perPage: 3, content: row)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.paperElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
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
        Haptics.tap()
        player.play(queue: songs, startAt: index)
        library.recordPlayed(songs[index])
        router.showPlayer = true
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

// MARK: - 编辑精选卡（长方形，对齐 Android `EditorCard`）

/// Android 是 150×66dp 的白卡：左边色条 + 歌单名 + 首数 + 右箭头。
/// iOS 这边按 170×64 走（iPhone 上 150 会显得太窄，字号又得跟着缩）。
struct EditorPlaylistCard: View {

    let playlist: DiscoverCatalog.Playlist

    private var accent: Color { Color(hex: playlist.accentHex) }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("20 首 · 每日换一批")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, Tokens.Spacing.xs)
        .frame(width: 170, alignment: .leading)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.paperElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
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
                    .foregroundStyle(rank <= 3 ? Tokens.Palette.vermilion : Color.secondary)
                    .frame(width: 20, alignment: .trailing)
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
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(minHeight: 56)
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

// MARK: - 猜你喜欢空态（纯新用户）

struct GuessEmptyGuide: View {
    var body: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            Text("猜你喜欢")
                .font(.subheadline.weight(.semibold))
            Text("多听几首，这里会根据你的播放记录长出来")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.paperElevated.opacity(0.6))
        )
        .padding(.horizontal, Tokens.Spacing.pageMargin)
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
