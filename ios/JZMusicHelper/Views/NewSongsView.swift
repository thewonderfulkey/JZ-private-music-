import SwiftUI

// MARK: - 最新单曲整页（发现页「最新单曲 → 查看全部」的落地页）
//
// 与 `ChartSongsView` 同一套骨架（页头 + 播放全部 + 统一 `SongRow`），差别的只有数据来源：
// 这里是酷我官方歌单「每日最新单曲推荐」（`KuwoPlaylist`，1082685104），一页 100 首、按发行日倒序。
//
// 这些歌都带 rid + 封面，点开不用再四平台搜索，所以整页直接进队列；
// 取流仍由播放引擎按平台适配器走（酷我），失败再跨平台补位。
struct NewSongsView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(DiscoverFeed.self) private var feed

    private var releases: [KuwoPlaylist.Release] { feed.newReleases }

    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()
    /// 2026-11-27（老板）：本页搜索——只筛这一页，队列仍是整页
    @State private var query = ""
    /// 播放范围口径（老板 2026-11-27 确认）：**播放全部 / 随机 / 点行起播 都用这一份**——
    /// 有搜索词时 = 筛选结果；没有搜索词时它 == 整页，所以行为与加搜索之前一致。**不要改回整页。**
    private var visibleReleases: [KuwoPlaylist.Release] {
        SongListFilter.filterItems(releases, query: query) { $0.song }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0,
                           pinnedViews: [.sectionHeaders]) {
                    // 2026-11-27（老板）：头部三件套吸顶（播放全部/随机原有 + 本页搜索新加）
                    Section {
                    if releases.isEmpty {
                        if feed.newState == .loading || feed.newState == .idle {
                            SkeletonRows(count: 10)
                                .padding(.top, Tokens.Spacing.xs)
                        } else {
                            EmptyStateView(title: "最新单曲暂时取不到",
                                           systemImage: "music.note.list",
                                           description: "换个网络或稍后再试",
                                           actionTitle: "重试") {
                                Task { await feed.refreshNewSongs() }
                            }
                            .padding(.top, Tokens.Spacing.xl)
                        }
                    } else {
                        if SongListRules.noMatch(totalCount: releases.count,
                                                 shownCount: visibleReleases.count,
                                                 query: query) {
                            ListNoMatchRow(query: query) { query = "" }
                        }
                        ForEach(Array(visibleReleases.enumerated()), id: \.element.id) { index, release in
                            newSongRow(release, index: index)
                        }
                        // 迷你条是浮层：末尾让出高度
                        MiniPlayerSpacer()
                    }
                    } header: {
                        if !releases.isEmpty {
                            SongListHeader(songCount: releases.count,
                                           query: $query,
                                           showsPlayAll: false,
                                           shownCount: visibleReleases.count) {
                                header
                            }
                        }
                    }
                }
                .padding(.top, Tokens.Spacing.xs)
                .readableWidth()
            }
            .scrollIndicators(.hidden)
            .locateToast(locator.toast)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LocateNowPlayingButton {
                        locator.locate(current: player.currentSong,
                                       songs: releases.map(\.song),
                                       proxy: proxy)
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("最新单曲")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 模块已经拉过就当天的数据；这里再核一次只是防"挂着跨过 0 点再点进来"
            await feed.loadNewSongsIfNeeded()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("每日最新单曲推荐")
                    .font(FontRole.sectionTitle)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)   // 副行可以省略，按钮文案不能（老板 2026-11-24）
            }
            Spacer(minLength: 0)
            PlayAllButtons(isEnabled: !(releases.isEmpty)) {
                play(visibleReleases.map(\.song), at: 0)
            } onShuffle: {
                // 抽一首直接起播，不弹播放页（停在每日新歌页看底部悬浮条）
                player.replaceQueue(visibleReleases.map(\.song), shuffle: true)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
    }

    private func newSongRow(_ release: KuwoPlaylist.Release, index: Int) -> some View {
        Button {
            play(visibleReleases.map(\.song), at: index)
        } label: {
            SongRow(song: release.song,
                    showsFavorite: true,
                    isFavorite: library.isFavorite(release.song),
                    onFavorite: {
                        Haptics.favorite()
                        withAnimation(Tokens.Motion.favorite) {
                            library.toggleFavorite(release.song)
                        }
                    })
                .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
        .buttonStyle(.rowPress)
        .id(release.song.id)
        .locatedFlash(active: locator.isHighlighted(release.song))
        .accessibilityHint("点一下以这页新歌为队列播放")
    }

    /// 副行写清楚来源：这是酷我单平台的官方歌单，不冒充"四平台合并"；
    /// 日期取这一页里最新的一条（歌单每天加歌，但页内也夹着旧歌，报"最新"比报"更新于今天"准确）。
    private var meta: String {
        var parts = ["\(releases.count) 首"]
        if let latest = releases.first?.shortDate, !latest.isEmpty {
            parts.append("最新 \(latest)")
        }
        parts.append("酷我每日新歌")
        return parts.joined(separator: " · ")
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
