import SwiftUI

// MARK: - 歌手页（歌手大全点进来的落地页）
//
// 只做「热门歌曲」：接口有 albumNum / mvNum，但这一轮不铺专辑/MV 页，
// 避免交付一个只有标题的空页。50 首都是带 rid 的，点开即播。
struct ArtistDetailView: View {

    let artist: KuwoArtist.Artist

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    @State private var releases: [KuwoPlaylist.Release] = []
    @State private var loading = false
    @State private var failed = false
    /// 这位歌手一共有多少首（接口 `data.total`；缺失时 0 = 只显示"已显示 N 首"）
    @State private var totalSongs = 0
    /// 已经翻到第几页（首页 = 1）
    @State private var loadedPage = 1
    /// 正在加载下一页
    @State private var loadingMore = false
    /// 下一页失败了（按钮变"重试"，不打断已有列表）
    @State private var moreFailed = false
    /// 第四十四轮：「定位到正在播放」的状态
    @State private var locator = SongLocator()
    /// 2026-11-27（老板）：本页搜索——只筛这一页，队列仍是整位歌手的列表
    @State private var query = ""
    /// 搜索过滤后的行（空查询 = 全部）
    private var visibleReleases: [KuwoPlaylist.Release] {
        SongListFilter.filterItems(releases, query: query) { $0.song }
    }

    private var songs: [Song] { releases.map(\.song) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0,
                           pinnedViews: [.sectionHeaders]) {
                    // 2026-11-27（老板）：头部三件套吸顶（播放全部/随机原有 + 本页搜索新加）
                    Section {
                    if releases.isEmpty {
                        if loading {
                            SkeletonRows(count: 8)
                                .padding(.top, Tokens.Spacing.s)
                        } else if failed {
                            EmptyStateView(title: "歌手的歌暂时取不到",
                                           systemImage: "person.crop.circle",
                                           description: "换个网络或稍后再试",
                                           actionTitle: "重试") {
                                Task { await load() }
                            }
                            .padding(.top, Tokens.Spacing.xl)
                        }
                    } else {
                        Text("热门歌曲")
                            .font(FontRole.sectionTitle)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            .padding(.top, Tokens.Spacing.s)
                            .padding(.bottom, Tokens.Spacing.xs)
                        ForEach(Array(visibleReleases.enumerated()), id: \.element.id) { index, release in
                            Button {
                                // 队列仍是这位歌手的全部歌（搜索只筛显示）
                                // 队列 = 当前可见（筛选后）列表；空查询时就是这位歌手的全部歌
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
                            // 第四十四轮：行 id 要让 ScrollViewReader 找得到
                            .id(release.song.id)
                            .locatedFlash(active: locator.isHighlighted(release.song))
                            .accessibilityHint("点一下以这位歌手的歌为队列播放")
                        }
                        // 2026-11-27（老板）：底部给「显示更多」，接着往下翻、不与上面重复
                        moreFooter
                    }
                    MiniPlayerSpacer()
                    } header: {
                        if !releases.isEmpty {
                            VStack(spacing: Tokens.Spacing.xs) {
                                header
                                ListSearchField(text: $query)
                                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                            }
                            .padding(.bottom, Tokens.Spacing.xs)
                            .background(Tokens.Palette.paper)
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
                                       songs: songs,
                                       proxy: proxy)
                    }
                }
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                avatar
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    Text(artist.name)
                        .font(FontRole.sectionTitle)
                        .lineLimit(2)
                    if !artist.alias.isEmpty {
                        Text(artist.alias)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            PlayAllButtons(isEnabled: !(songs.isEmpty)) {
                play(visibleReleases.map(\.song), at: 0)
            } onShuffle: {
                // 抽一首直接起播，不弹播放页（停在歌手页看底部悬浮条）
                player.replaceQueue(visibleReleases.map(\.song), shuffle: true)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.xs)
    }

    @ViewBuilder
    private var avatar: some View {
        if artist.picURL.isEmpty {
            ZStack {
                Circle().fill(Tokens.Palette.paperElevated)
                Text(artist.initial)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 88)
        } else {
            RemoteArtwork(url: artist.picURL, size: 88, circular: true)
        }
    }

    private var meta: String {
        var parts = ["\(CountFormat.short(artist.fans))粉丝"]
        if artist.songCount > 0 { parts.append("\(artist.songCount) 首") }
        if artist.albumCount > 0 { parts.append("\(artist.albumCount) 张专辑") }
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

    // MARK: 显示更多（2026-11-27）

    /// 列表底部那一块：进度文案 + 按钮（加载中转圈 / 失败可重试 / 到底了写"已全部加载"）
    @ViewBuilder
    private var moreFooter: some View {
        let shown = releases.count
        if ArtistPaging.hasMore(shown: shown, total: totalSongs) {
            VStack(spacing: Tokens.Spacing.xs) {
                Button {
                    Haptics.trackChange()
                    Task { await loadMore() }
                } label: {
                    HStack(spacing: Tokens.Spacing.xs) {
                        if loadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: moreFailed ? "arrow.clockwise" : "chevron.down")
                                .font(.footnote.weight(.semibold))
                        }
                        Text(moreFailed ? "重试" : "显示更多")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loadingMore)

                Text(moreFailed
                     ? "\(ArtistPaging.progressText(shown: shown, total: totalSongs)) · 刚才没取到，点重试"
                     : ArtistPaging.progressText(shown: shown, total: totalSongs))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
            .padding(.top, Tokens.Spacing.s)
            .padding(.bottom, Tokens.Spacing.m)
        } else {
            Text("已全部加载 · \(shown) 首")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.m)
        }
    }

    // MARK: 取数

    private func load() async {
        guard releases.isEmpty, !loading else { return }
        loading = true
        failed = false
        do {
            let page = try await KuwoArtist.fetchSongsPage(artistID: artist.id, page: 1)
            releases = page.items
            totalSongs = page.total
            loadedPage = 1
        } catch {
            failed = releases.isEmpty
        }
        loading = false
    }

    /// 翻下一页：追加到列表底部，**不跳回顶部**（老板明确要求），重复的丢掉
    private func loadMore() async {
        guard !loadingMore, !releases.isEmpty else { return }
        loadingMore = true
        moreFailed = false
        let next = loadedPage + 1
        do {
            let page = try await KuwoArtist.fetchSongsPage(artistID: artist.id, page: next)
            let merged = ArtistPaging.appendUnique(releases, adding: page.items)
            // 接口还在给数据但全是旧的 = 已经到底（total 可能偏大，或多个版本指向同一首）
            if ArtistPaging.addedNothing(releases, adding: page.items) {
                moreFailed = false
                totalSongs = merged.count
            } else {
                releases = merged
                if page.total > 0 { totalSongs = page.total }
            }
            loadedPage = next
        } catch {
            moreFailed = true
        }
        loadingMore = false
    }
}
