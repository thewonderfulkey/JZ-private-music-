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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                    header
                    ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                        Button {
                            play(releases.map(\.song), at: index)
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
                        .accessibilityHint("点一下以这页新歌为队列播放")
                    }
                    // 迷你条是浮层：末尾让出高度
                    MiniPlayerSpacer()
                }
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
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
            }
            Spacer(minLength: 0)
            Button {
                play(releases.map(\.song), at: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.caption)
                    Text("播放全部")
                        .font(FontRole.button)
                }
                .frame(minHeight: 34)
                .padding(.horizontal, Tokens.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(Tokens.Palette.vermilion)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.press)
            .disabled(releases.isEmpty)
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.s)
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
        player.play(queue: songs, startAt: index)
        library.recordPlayed(songs[index])
        router.showPlayer = true
    }
}
