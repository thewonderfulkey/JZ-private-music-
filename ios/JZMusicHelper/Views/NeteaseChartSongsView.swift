import SwiftUI

// MARK: - 网易热歌榜整页（2026-11-27，发现页 2.0 Task 7）
//
// 与 `ChartSongsView`（酷我榜）同一个骨架：这里的每首歌都带着**网易 song id**，
// 点开不需要再四平台搜索，整榜可以直接进队列。
//
// 数据来自 `NeteaseDiscover.playlistDetail`（v3 端点，带真实时长）。
// 为什么不在同一个页面里做"来源切换"：两条榜的数据形状、页数、刷新节奏都不一样，
// 合成一页要写一层适配；两页各自简单、互不影响，入口就写在各自模块标题右边。
struct NeteaseChartSongsView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    @State private var page: NeteaseTrackPage?
    @State private var loading = false
    @State private var failed = false

    private var songs: [Song] { page?.songs ?? [] }

    /// 2026-11-27（老板）：本页搜索——只筛这一页，队列仍是整榜
    @State private var query = ""
    private var visibleSongs: [Song] {
        SongListFilter.filter(songs, query: query)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0,
                       pinnedViews: [.sectionHeaders]) {
                // 2026-11-27（老板）：头部三件套吸顶（播放全部/随机原有 + 本页搜索新加）
                Section {
                if let page, !page.songs.isEmpty {
                    ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            // 队列仍是整榜（搜索只筛显示）
                            play(page.songs, at: page.songs.firstIndex(of: song) ?? index)
                        } label: {
                            SongRow(song: song,
                                    showsFavorite: true,
                                    isFavorite: library.isFavorite(song),
                                    onFavorite: {
                                        Haptics.favorite()
                                        withAnimation(Tokens.Motion.favorite) {
                                            library.toggleFavorite(song)
                                        }
                                    },
                                    leadingRank: index + 1)
                                .padding(.horizontal, Tokens.Spacing.pageMargin)
                        }
                        .buttonStyle(.rowPress)
                        .accessibilityLabel("第 \(index + 1) 名，\(song.name)，\(song.singer)")
                    }
                    MiniPlayerSpacer()
                } else if loading {
                    SkeletonRows(count: 10)
                        .padding(.top, Tokens.Spacing.xs)
                } else if failed {
                    EmptyStateView(title: "榜单暂时取不到",
                                   systemImage: "chart.bar",
                                   description: "换个网络或稍后再试",
                                   actionTitle: "重试") {
                        Task { await load(force: true) }
                    }
                    .padding(.top, Tokens.Spacing.xl)
                }
                } header: {
                    if let page, !page.songs.isEmpty {
                        SongListHeader(songCount: page.songs.count,
                                       query: $query,
                                       showsPlayAll: false,
                                       shownCount: visibleSongs.count) {
                            header(page)
                        }
                    }
                }
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
    }

    private var navTitle: String {
        if let name = page?.name, !name.isEmpty { return name }
        return "网易热歌榜"
    }

    private func header(_ page: NeteaseTrackPage) -> some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(page.name.isEmpty ? "网易热歌榜" : page.name)
                    .font(FontRole.sectionTitle)
                    .lineLimit(1)
                Text("\(page.songs.count) 首 · 网易官方榜 · 每日更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PlayAllButtons(isEnabled: !page.songs.isEmpty) {
                play(page.songs, at: 0)
            } onShuffle: {
                player.replaceQueue(page.songs, shuffle: true)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private func play(_ songs: [Song], at index: Int) {
        guard songs.indices.contains(index) else { return }
        RowTap.afterHighlight {
            player.play(queue: songs, startAt: index)
            library.recordPlayed(songs[index])
            router.showPlayer = true
        }
    }

    private func load(force: Bool) async {
        if loading { return }
        if !force, page != nil { return }
        loading = true
        failed = false
        if let result = await NeteaseDiscover.playlistDetail(id: DiscoverSourceIDs.neteaseHotChartID),
           !result.songs.isEmpty {
            page = result
        } else {
            // 已经有内容时不清空：刷新失败不把用户正在看的榜单抽走
            failed = page == nil
        }
        loading = false
    }
}
