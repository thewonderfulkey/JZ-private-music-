import SwiftUI

// MARK: - 发现（设计稿 §3.1）
//
// 这一版是**骨架 + 真实数据**的分工：
//   · 最近播放 / 猜你喜欢 —— 接 LibraryStore 的真实数据（有多少显示多少）
//   · 编辑精选 —— 3 个静态分类占位（歌单数据源随 P1 接入，不放假歌单）
//   · 热门音乐 —— 明确写"随 P1 接入"
struct DiscoverView: View {

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    let onPlay: (Song) -> Void

    private let categories: [(title: String, subtitle: String)] = [
        ("华语经典", "20 首"),
        ("粤语金曲", "20 首"),
        ("影视 OST", "20 首"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                brandRow
                editorPicks
                recentSection
                guessSection
                hotSection
            }
            .padding(.top, Tokens.Spacing.xs)
            .padding(.bottom, Tokens.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
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
    }

    // MARK: 编辑精选

    private var editorPicks: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(title: "编辑精选")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s) {
                    ForEach(categories, id: \.title) { item in
                        MediaCard(title: item.title, subtitle: item.subtitle)
                            .accessibilityHint("歌单内容随 P1 接入")
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            }

            Text("分类占位：歌单数据源随 P1 接入")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Tokens.Spacing.pageMargin)
        }
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

    // MARK: 猜你喜欢（基于最近播放的真实派生，不是假推荐）

    @ViewBuilder
    private var guessSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(title: "猜你喜欢")
            if library.recentSongs.isEmpty {
                EmptyStateView(title: "还没有推荐",
                               systemImage: "sparkles",
                               description: "多听几首，这里会根据你的播放记录长出来")
                    .frame(height: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.recentSongs.prefix(5)) { song in
                        Button {
                            onPlay(song)
                        } label: {
                            SongRow(song: song, subtitle: "你最近听过 · \(song.singer)")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        Divider().padding(.leading, Tokens.Spacing.pageMargin + 48 + Tokens.Spacing.s)
                    }
                }
            }
        }
    }

    // MARK: 热门

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(title: "热门音乐")
            PendingFeatureRow(title: "热门榜单", note: "随 P1 接入（数据源与编辑精选同一批）")
        }
    }
}
