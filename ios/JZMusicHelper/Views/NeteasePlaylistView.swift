import SwiftUI

// MARK: - 通用歌单页（2026-11-27，发现页 2.0 Task 5b）
//
// 为什么需要它：实测（2026-11-26）网易首页 banner 8 条里 4 条是**歌单**（targetType 1000）、
// 4 条是演出/外链（3000），**一条单曲都没有**。所以"banner 只跳歌曲"根本跳不了；
// 要让 banner 点进去真能听歌，落点只能是歌单页。
//
// 这一页不只为 banner 存在：网易榜单、以后广场卡片都能复用同一页（同一个接口 `trackPage`）。
// 曲目来自 `NeteaseDiscover.playlistDetail`（v3 端点，带真实时长），点开就是整页为队列起播。
struct NeteasePlaylistView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    let playlistID: String
    /// 进页面时先用 banner 的文案占标题，数据回来再换成歌单真名（避免导航栏空一截）
    var fallbackTitle: String = ""

    @State private var page: NeteaseTrackPage?
    @State private var loading = false
    @State private var failed = false
    /// 2026-11-27（老板）：本页搜索——只筛这一页的歌，不打网络
    @State private var query = ""

    /// 播放范围口径（老板 2026-11-27 确认）：**播放全部 / 随机 / 点行起播 都用这一份**——
    /// 有搜索词时 = 筛选结果；没有搜索词时它 == 整页，所以行为与加搜索之前一致。**不要改回整页。**
    /// 搜索过滤后的曲目（队列仍是整页，搜索只改显示）
    private var visibleSongs: [Song] {
        SongListFilter.filter(page?.songs ?? [], query: query)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0,
                       pinnedViews: [.sectionHeaders]) {
                Section {
                    sectionContent
                } header: {
                    stickyHeader
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

    // MARK: 列表与吸顶头部（拆成小函数：编译器不再卡在超长表达式上，2026-11-27 CI 教训）

    @ViewBuilder
    private var sectionContent: some View {
        if let page, !page.songs.isEmpty {
            ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                Button {
                    // 队列 = 当前可见（筛选后）列表；空查询时就是整页
                    play(visibleSongs, at: index)
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
                .accessibilityLabel("第 \(index + 1) 首，\(song.name)，\(song.singer)")
            }
            MiniPlayerSpacer()
        } else if loading {
            SkeletonRows(count: 10)
                .padding(.top, Tokens.Spacing.xs)
        } else if failed {
            EmptyStateView(title: "这个歌单暂时取不到",
                           systemImage: "music.note.list",
                           description: "换个网络或稍后再试",
                           actionTitle: "重试") {
                Task { await load(force: true) }
            }
            .padding(.top, Tokens.Spacing.xl)
        }
    }

    @ViewBuilder
    private var stickyHeader: some View {
        if let page, !page.songs.isEmpty {
            SongListHeader(songCount: page.songs.count,
                           query: $query,
                           showsPlayAll: false,
                           shownCount: visibleSongs.count) {
                header(page)
            }
        }
    }

    private var navTitle: String {
        if let name = page?.name, !name.isEmpty { return name }
        return fallbackTitle.isEmpty ? "歌单" : fallbackTitle
    }

    // MARK: 头部

    private func header(_ page: NeteaseTrackPage) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(alignment: .center, spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(page.name.isEmpty ? navTitle : page.name)
                        .font(FontRole.sectionTitle)
                        .lineLimit(2)
                    Text("\(page.songs.count) 首 · 网易歌单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                PlayAllButtons(isEnabled: !page.songs.isEmpty) {
                    play(visibleSongs, at: 0)
                } onShuffle: {
                    player.replaceQueue(visibleSongs, shuffle: true)
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    // MARK: 播放

    private func play(_ songs: [Song], at index: Int) {
        guard songs.indices.contains(index) else { return }
        // 与其它列表同口径：先铺行高亮，再起播 / 开播放页
        RowTap.afterHighlight {
            player.play(queue: songs, startAt: index)
            library.recordPlayed(songs[index])
            router.showPlayer = true
        }
    }

    // MARK: 取数

    private func load(force: Bool) async {
        if loading { return }
        if !force, page != nil { return }
        loading = true
        failed = false
        let result = await NeteaseDiscover.playlistDetail(id: playlistID)
        if let result, !result.songs.isEmpty {
            page = result
        } else {
            // 已经有内容时不清空：刷新失败不把用户正在看的列表抽走
            failed = page == nil
        }
        loading = false
    }
}
