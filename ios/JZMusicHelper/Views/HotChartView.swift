import SwiftUI

// MARK: - 热门音乐榜单页（设计稿 §3.3）
//
// 21 行，数据来自 DiscoverFeed 当天缓存（种子词四平台合并 + 原版优先挑选）。
// 点任一行以整张榜单为队列起播——与「猜你喜欢」一致，不让用户一首一首点。
struct HotChartView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DiscoverFeed.self) private var feed

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
                            } label: {
                                ChartRow(rank: index + 1, song: song)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            Divider().padding(.leading, Tokens.Spacing.pageMargin + 36)
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
