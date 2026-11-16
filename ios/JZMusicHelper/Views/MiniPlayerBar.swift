import SwiftUI

// MARK: - 迷你播放条
//
// 2026-11-16 改版（老板反馈 ⑤）：原来只有一个播放/暂停，没有收藏、没有上/下一首，
// 而且它挂在 TabView 的 safeAreaInset 上——**盖住了 Tab 栏**，一旦播歌就点不到搜索/下载。
//
// 现在：
//   · 四个键：收藏 / 上一首 / 播放暂停 / 下一首（都是 44pt 命中区）；
//   · 挂载方式改成挂在**每个 NavigationStack 上**（见 `miniPlayerBar`），
//     但用 overlay 浮层而不是 safeAreaInset，并在每个可滚动页面末尾放 `MiniPlayerSpacer()`
//     显式占位——safeAreaInset 在 NavigationStack 上传不进内层列表，会把最后一条压住；
//   · 进度仍用底部 2pt 细线，不高亮抢视觉。
struct MiniPlayerBar: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    let onTap: () -> Void

    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return library.isFavorite(song)
    }

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: Tokens.Spacing.xxs) {
                // 封面 + 歌名整块可点：打开播放页（右边四个键各有自己的命中区）
                Button(action: onTap) {
                    HStack(spacing: Tokens.Spacing.xs) {
                        artwork(for: song)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(song.singer.isEmpty ? "未知歌手" : song.singer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("正在播放：\(song.name)，\(song.singer)")
                .accessibilityHint("轻点打开播放页")

                favoriteButton(song)
                skipButton(systemImage: "backward.fill", label: "上一首") {
                    player.previousTrack()
                }
                playButton
                skipButton(systemImage: "forward.fill", label: "下一首") {
                    player.nextTrack()
                }
            }
            .padding(.leading, Tokens.Spacing.xs)
            .padding(.trailing, Tokens.Spacing.xxs)
            .frame(minHeight: Tokens.Size.miniPlayerHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) { progressLine }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
    }

    // MARK: 控件

    private func favoriteButton(_ song: Song) -> some View {
        Button {
            Haptics.favorite()
            withAnimation(Tokens.Motion.favorite) {
                library.toggleFavorite(song)
            }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isFavorite ? Tokens.Palette.vermilion : Color.secondary)
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
    }

    private func skipButton(systemImage: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }

    private var playButton: some View {
        Button {
            player.toggle()
        } label: {
            Group {
                if player.isResolving {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
        .disabled(player.isResolving)
    }

    // MARK: 装饰

    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * player.progress)
            }
            .frame(height: 2)
            .padding(.horizontal, 10)
            .offset(y: geo.size.height - 3)
        }
        .allowsHitTesting(false)
    }

    private func artwork(for song: Song) -> some View {
        SongArtwork(song: song, size: 40, radius: Tokens.Radius.artworkSmall)
    }
}

// MARK: - 挂载方式

extension View {
    /// 把迷你条**浮**在当前页面底部（挂在每个 Tab 的 NavigationStack 上，push 之后的子页面也有）。
    ///
    /// 为什么不用 `safeAreaInset`（前几版的写法）：`safeAreaInset` 挂在 NavigationStack 上时，
    /// 它只缩窄了栈自己的安全区，**内层 ScrollView / List 的滚动内容并不会因此让位**——
    /// 于是播歌之后每个 Tab 的最后一条、以及搜索结果最后一条都被条子压住
    /// （第五轮老板反馈 ⑨）。现在改成 overlay 浮层 + 各页面列表末尾 `MiniPlayerSpacer()` 显式占位：
    /// 占位是真实布局高度，滚到底一定停得出来，不靠安全区的传递。
    func miniPlayerBar(onTap: @escaping () -> Void) -> some View {
        modifier(MiniPlayerOverlay(onTap: onTap))
    }
}

struct MiniPlayerOverlay: ViewModifier {

    @Environment(PlayerEngine.self) private var player
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if player.hasCurrentSong {
                MiniPlayerBar(onTap: onTap)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .padding(.top, Tokens.Spacing.xxs)
                    .padding(.bottom, Tokens.Spacing.xxs)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.hasCurrentSong)
    }
}

/// 列表末尾的占位：正好等于迷你条的高度（+ 一点呼吸）。
/// 每个可滚动页面都要在内容末尾放一个——浮层不挤压内容，只能自己把位置让出来。
struct MiniPlayerSpacer: View {

    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Color.clear
            .frame(height: player.hasCurrentSong
                   ? Tokens.Size.miniPlayerHeight + Tokens.Spacing.m
                   : 0)
            .accessibilityHidden(true)
    }
}


