import SwiftUI

// MARK: - 我的收藏（老板反馈 ⑤：资料库那页设计不行，直接换成"我的收藏"）
//
// 只做一件事：把收藏的歌排成一张干净的列表。
//   · 顶部一张大卡写明「我喜欢的音乐 · N 首」，播放全部 / 随机播放两个动作就在卡上；
//   · 下面是收藏列表，行内可直接取消收藏（爱心）；
//   · 设置收进右上角齿轮（原来在"资料库"里）。
// 最近播放没有消失：它作为一屏「最近播放」留在发现页（那里本来就有一栏）。
struct FavoritesView: View {

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if library.favorites.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header
                        ForEach(Array(library.favorites.enumerated()), id: \.element.id) { index, song in
                            Button {
                                // 第三十九轮：让行高亮先铺满，再起播/弹悬浮栏/开播放页
                                RowTap.afterHighlight {
                                    player.play(queue: library.favorites, startAt: index)
                                    library.recordPlayed(song)
                                    router.showPlayer = true
                                }
                            } label: {
                                SongRow(song: song,
                                        showsFavorite: true,
                                        isFavorite: true,
                                        onFavorite: {
                                            Haptics.favorite()
                                            withAnimation(Tokens.Motion.favorite) {
                                                library.toggleFavorite(song)
                                            }
                                        })
                                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                            }
                            .buttonStyle(.rowPress)
                            .contextMenu {
                                Button {
                                    downloadFlow.start(song: song, want: player.quality)
                                } label: {
                                    Label("下载…", systemImage: "arrow.down.circle")
                                }
                                Button(role: .destructive) {
                                    library.toggleFavorite(song)
                                } label: {
                                    Label("取消收藏", systemImage: "heart.slash")
                                }
                            }
                        }
                        // 迷你条是浮层：末尾让出它的高度，最后一条收藏不会被压住
                        MiniPlayerSpacer()
                    }
                    .readableWidth()
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("我的收藏")
        // 第四轮（老板反馈 ③）：设置已经单独占一个 Tab，这里的齿轮撤掉，只留一个入口。
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Tokens.Palette.vermilion.opacity(0.85),
                                                    Tokens.Palette.vermilion.opacity(0.45)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Image(systemName: "heart.fill")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("我喜欢的音乐")
                        .font(.title3.weight(.bold))
                    Text("\(library.favorites.count) 首 · 收藏即得")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Tokens.Spacing.s) {
                        Button {
                            guard !library.favorites.isEmpty else { return }
                            player.play(queue: library.favorites, startAt: 0)
                            library.recordPlayed(library.favorites[0])
                            router.showPlayer = true
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)

                        Button {
                            guard !library.favorites.isEmpty else { return }
                            player.replaceQueue(library.favorites, shuffle: true)
                            router.showPlayer = true
                        } label: {
                            Label("随机", systemImage: "shuffle")
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule().fill(Tokens.Palette.paperElevated))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        }
                        .buttonStyle(.press)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.m)
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "heart")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Tokens.Palette.vermilion.opacity(0.7))
            Text("还没有收藏的歌")
                .font(.headline)
            Text("在播放页点 ❤，或在搜索结果里左滑收藏")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.Spacing.l)
    }
}
