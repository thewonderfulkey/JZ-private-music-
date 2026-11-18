import SwiftUI

// MARK: - 歌单广场整页（发现页「歌单广场 → 查看全部」）
//
// 热门 / 最新 两个排序，双列封面墙。数据来自 `SquareFeed`：
// 第一页按本地日落盘（当天只拉一次），第 2 页起翻页只在内存。
struct PlaylistSquareView: View {

    @Environment(SquareFeed.self) private var feed

    @State private var sort: KuwoPlaylist.Sort = .hot

    private var items: [KuwoPlaylist.Summary] {
        sort == .hot ? feed.hot : feed.latest
    }

    private var state: SquareFeed.LoadState {
        sort == .hot ? feed.hotState : feed.latestState
    }

    private var hasMore: Bool {
        sort == .hot ? feed.hotHasMore : feed.latestHasMore
    }

    private var loadingMore: Bool {
        sort == .hot ? feed.loadingMoreHot : feed.loadingMoreLatest
    }

    private var total: Int {
        sort == .hot ? feed.hotTotal : feed.latestTotal
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                chips
                content
                MiniPlayerSpacer()
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("歌单广场")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feed.refresh(sort) }
        .task {
            await feed.loadIfNeeded()
            await feed.loadLatestIfNeeded()
        }
    }

    // MARK: 筛选

    private var chips: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            ForEach(KuwoPlaylist.Sort.allCases) { option in
                FilterPill(title: option.title, isSelected: sort == option) {
                    guard sort != option else { return }
                    Haptics.tap()
                    sort = option
                    Task {
                        if option == .new { await feed.loadLatestIfNeeded() }
                    }
                }
            }
            Spacer(minLength: 0)
            if total > 0 {
                Text("\(total) 张")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            if state == .failed {
                EmptyStateView(title: "歌单广场暂时取不到",
                               systemImage: "music.note.list",
                               description: "换个网络或稍后再试",
                               actionTitle: "重试") {
                    Task { await feed.refresh(sort) }
                }
                .padding(.top, Tokens.Spacing.xl)
            } else {
                skeleton
            }
        } else {
            grid
            footer
        }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: Tokens.Spacing.m),
         GridItem(.flexible())]
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.l) {
            ForEach(items) { item in
                NavigationLink {
                    PlaylistDetailView(summary: item)
                } label: {
                    PlaylistGridCard(summary: item)
                }
                .buttonStyle(.pressSubtle)
                .onAppear {
                    // 滚到最后一个时取下一页（不打断滚动，失败就停在这）
                    if item.id == items.last?.id {
                        Task { await feed.loadMore(sort) }
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    private var skeleton: some View {
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.l) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var footer: some View {
        if loadingMore {
            HStack {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Spacer()
            }
            .padding(.vertical, Tokens.Spacing.s)
        } else if !hasMore, items.count > 0 {
            Text("没有更多了")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.s)
        }
    }
}
