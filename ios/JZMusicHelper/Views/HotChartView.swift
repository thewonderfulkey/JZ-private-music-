import SwiftUI

// MARK: - 热门音乐榜单页（设计稿 §3.3）
//
// 21 行，数据来自 DiscoverFeed 当天缓存（种子词四平台合并 + 原版优先挑选）。
// 点任一行以整张榜单为队列起播——与「猜你喜欢」一致，不让用户一首一首点。
//
// 行样式统一走 `DiscoverSongRow`（与发现页热门模块同一套），不再单独维护一张 ChartRow：
// 两处一旦各写一遍，改版时必然只改一处，看起来就是"同一个榜单两种样子"。
struct HotChartView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DiscoverFeed.self) private var feed
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if feed.hotSongs.isEmpty {
                if feed.hotState == .loading || feed.hotState == .idle {
                    SkeletonRows(count: 8)
                } else {
                    EmptyStateView(title: "榜单暂时取不到",
                                   systemImage: "chart.bar",
                                   description: "换个网络或稍后再试",
                                   actionTitle: "重试") {
                        Task { await feed.refreshHot() }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Text("每日更新 · 四平台合并 · 原版优先")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            .padding(.bottom, Tokens.Spacing.xs)

                        ForEach(Array(feed.hotSongs.enumerated()), id: \.element.id) { index, song in
                            Button {
                                player.play(queue: feed.hotSongs, startAt: index)
                                library.recordPlayed(song)
                                router.showPlayer = true
                            } label: {
                                DiscoverSongRow(song: song,
                                                reason: song.singer,
                                                showReason: false,
                                                rank: index + 1)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            Divider().padding(.leading, Tokens.Spacing.pageMargin + 44)
                        }
                    }
                    .padding(.top, Tokens.Spacing.xs)
                    .padding(.bottom, Tokens.Spacing.xxl)
                    .readableWidth()
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("热门音乐")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await feed.loadHotIfNeeded()
        }
    }
}
