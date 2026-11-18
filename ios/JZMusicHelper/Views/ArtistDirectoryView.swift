import SwiftUI

// MARK: - 歌手大全整页（发现页「歌手大全 → 查看全部」）
//
// 分类 chips（全部 / 华语 / 欧美 / 组合 / 日韩男 / 日韩女 / 日韩组合）+ A–Z 字母条 + 三列头像墙。
//
// 一个必须先说清的实话：默认排序是**粉丝数**（接口就这样），不是字母序；点字母才是该字母下
// 按粉丝排。所以 meta 写「按粉丝排序」，不冒充 A-Z 全表。
struct ArtistDirectoryView: View {

    @Environment(ArtistFeed.self) private var feed

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                categoryChips
                letterBar
                meta
                content
                MiniPlayerSpacer()
            }
            .padding(.top, Tokens.Spacing.xs)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .navigationTitle("歌手大全")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feed.refresh() }
        .task { await feed.loadIfNeeded() }
    }

    // MARK: 分类

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.xs) {
                ForEach(KuwoArtist.categories) { category in
                    FilterPill(title: category.title,
                               isSelected: feed.category == category.id && feed.prefix.isEmpty) {
                        Haptics.tap()
                        Task { await feed.select(category: category.id, prefix: "") }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
    }

    // MARK: A–Z

    private var letterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(KuwoArtist.letters, id: \.self) { letter in
                    let prefix = letter == "热门" ? "" : letter
                    Button {
                        Haptics.tap()
                        Task { await feed.select(category: feed.category, prefix: prefix) }
                    } label: {
                        Text(letter)
                            .font(.caption.weight(feed.prefix == prefix ? .bold : .regular))
                            .foregroundStyle(feed.prefix == prefix ? Color.primary : Color.secondary)
                            .padding(.bottom, 2)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(feed.prefix == prefix ? Tokens.Palette.vermilion : .clear)
                                    .frame(height: 2)
                            }
                            .frame(minWidth: 20, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityAddTraits(feed.prefix == prefix ? .isSelected : [])
                }
            }
            .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
    }

    private var meta: some View {
        Text("\(feed.total) 位 · 按粉丝排序")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if feed.items.isEmpty {
            if feed.state == .failed {
                EmptyStateView(title: "歌手暂时取不到",
                               systemImage: "person.2",
                               description: "换个网络或稍后再试",
                               actionTitle: "重试") {
                    Task { await feed.refresh() }
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
        [GridItem(.flexible(), spacing: Tokens.Spacing.xs),
         GridItem(.flexible(), spacing: Tokens.Spacing.xs),
         GridItem(.flexible())]
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.m) {
            ForEach(feed.items) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist)
                } label: {
                    ArtistGridCell(artist: artist)
                }
                .buttonStyle(.pressSubtle)
                .onAppear {
                    if artist.id == feed.items.last?.id {
                        Task { await feed.loadMore() }
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
    }

    private var skeleton: some View {
        LazyVGrid(columns: columns, spacing: Tokens.Spacing.m) {
            ForEach(0..<9, id: \.self) { _ in
                VStack(spacing: Tokens.Spacing.xs) {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 88, height: 88)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 56, height: 10)
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var footer: some View {
        if feed.hasMore {
            // 滚动到底自动取下一页；这里只在"还没到底"时留一点高度，避免内容贴着迷你条
            Color.clear.frame(height: 1)
        }
    }
}
