import SwiftUI

// MARK: - 发现（设计稿 §3.1）
//
// 上一版这里只有"最近播放 + 猜你喜欢"（都由本地历史派生），新用户打开就是三个静态分类 + 一行
// "随 P1 接入"的占位——表现出来就是"发现页什么都没有"。这一版把三块都接上真数据：
//   ① 编辑精选：内置池（DiscoverCatalog）按天轮换 20 首 → 点开歌单页，点单曲才去搜真实音源
//   ② 猜你喜欢：从最近播放抽歌手 → 搜他们的歌 → 剔掉听过的（真数据派生，不是假推荐）
//   ③ 热门音乐：种子词四平台并发搜索 → DiscoverRules.pick 选出 21 首 → 当天缓存
struct DiscoverView: View {

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DiscoverFeed.self) private var feed

    let onPlay: (Song) -> Void
    var onOpenSearch: (() -> Void)? = nil

    /// 编辑精选「换一批」的轮次：只在本次会话内叠加，不写盘（跨天本来就会换）
    @State private var rotation = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                brandRow
                editorSection
                recentSection
                guessSection
                hotSection
            }
            .padding(.top, Tokens.Spacing.xs)
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("发现")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onOpenSearch?()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("去搜索")
            }
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
        }
    }

    // MARK: 品牌行

    private var brandRow: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            // 印章只作装饰（设计稿 §2），无障碍隐藏
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Tokens.Palette.vermilion)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(-4))
                .accessibilityHidden(true)
            Text("发现音乐")
                .font(.footnote.weight(.medium))
                .tracking(4)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("发现音乐")
    }

    // MARK: 编辑精选

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(title: "编辑精选", actionTitle: "换一批") {
                Haptics.refresh()
                withAnimation(Tokens.Motion.stateChange) { rotation += 1 }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(DiscoverCatalog.playlists) { playlist in
                        NavigationLink {
                            EditorPlaylistView(playlist: playlist, rotation: rotation)
                        } label: {
                            playlistCard(playlist)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(playlist.title)，20 首，今日精选")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            }
        }
    }

    private func playlistCard(_ playlist: DiscoverCatalog.Playlist) -> some View {
        let accent = Color(hex: playlist.accentHex)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(
                        LinearGradient(colors: [accent.opacity(0.34), accent.opacity(0.10)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(accent.opacity(0.85))
            }
            .frame(width: 160, height: 160)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 26, height: 3)
                    .padding(Tokens.Spacing.s)
            }

            Text(playlist.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.top, Tokens.Spacing.xs)
            Text("20 首 · 每日换一批")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: 160, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: 最近播放

    @ViewBuilder
    private var recentSection: some View {
        if !library.recentSongs.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader(title: "最近播放")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Spacing.s) {
                        ForEach(library.recentSongs.prefix(8)) { song in
                            MediaCard(title: song.name,
                                      subtitle: song.singer,
                                      artwork: AnyView(SongArtwork(song: song, size: 112,
                                                                   radius: Tokens.Radius.artworkSmall)),
                                      size: 112,
                                      onTap: { onPlay(song) })
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                }
            }
        }
    }

    // MARK: 猜你喜欢

    @ViewBuilder
    private var guessSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("猜你喜欢")
                    .font(FontRole.sectionTitle)
                Spacer()
                if !library.recentSongs.isEmpty, feed.guessState != .loading {
                    Button("换一批") {
                        Haptics.refresh()
                        Task { await feed.nextGuessRound(recent: library.recentSongs) }
                    }
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            if library.recentSongs.isEmpty {
                // 首启（纯新用户）：不放假推荐，只说明这里会长出来什么
                PendingFeatureRow(title: "还没有推荐",
                                  note: "多听几首，这里会根据你的播放记录长出来")
            } else if feed.guessState == .loading {
                SkeletonRows(count: 3)
            } else if feed.guessState == .failed {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    StatusLine(kind: .error("推荐暂时取不到，稍后再试"))
                    Button("重试") {
                        Task { await feed.refreshGuess(recent: library.recentSongs) }
                    }
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(feed.guessSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.play(queue: Array(feed.guessSongs.prefix(5)), startAt: index)
                            library.recordPlayed(song)
                        } label: {
                            SongRow(song: song,
                                    subtitle: "\(song.singer) · 根据你最近的播放")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        Divider().padding(.leading, Tokens.Spacing.pageMargin + 48 + Tokens.Spacing.s)
                    }
                }
            }
        }
    }

    // MARK: 热门音乐

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("热门音乐")
                    .font(FontRole.sectionTitle)
                Spacer()
                if !feed.hotSongs.isEmpty {
                    NavigationLink("查看全部") { HotChartView() }
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)

            switch feed.hotState {
            case .idle, .loading:
                SkeletonRows(count: 3)
            case .failed:
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    StatusLine(kind: .error("榜单暂时取不到，稍后再试"))
                    Button("重试") {
                        Task { await feed.refreshHot() }
                    }
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            case .loaded:
                VStack(spacing: 0) {
                    ForEach(Array(feed.hotSongs.prefix(7).enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.play(queue: feed.hotSongs, startAt: index)
                            library.recordPlayed(song)
                        } label: {
                            ChartRow(rank: index + 1, song: song)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        Divider().padding(.leading, Tokens.Spacing.pageMargin + 36)
                    }
                }
            }
        }
    }
}

// MARK: - 榜单行（发现页用前 7 行，榜单页用全部）

struct ChartRow: View {
    let rank: Int
    let song: Song

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text("\(rank)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(rank <= 3 ? Tokens.Palette.vermilion : Color.secondary)
                .frame(width: 20, alignment: .trailing)

            SongArtwork(song: song, size: 44, radius: Tokens.Radius.artworkSmall)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(song.singer)
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Spacing.xs)

            Text(song.durationText)
                .font(FontRole.metadata)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .frame(height: Tokens.Size.songRowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(rank) 名，\(song.name)，\(song.singer)，\(song.durationText)")
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
