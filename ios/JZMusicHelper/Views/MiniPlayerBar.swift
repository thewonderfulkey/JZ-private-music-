import SwiftUI

// MARK: - 迷你播放条
//
// 2026-11-16 改版（老板反馈 ⑤）：原来只有一个播放/暂停，没有收藏、没有上/下一首，
// 而且它挂在 TabView 的 safeAreaInset 上——**盖住了 Tab 栏**，一旦播歌就点不到搜索/下载。
//
// 现在：
//   · 四个键：收藏 / 上一首 / 播放暂停 / 下一首（都是 44pt 命中区）；
//   · 挂载方式改成挂在**每个 NavigationStack 上**（见 `miniPlayerInset`），
//     inset 只挤压内容区，Tab 栏本身仍在、仍可点；
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
    /// 把迷你条挂在**当前 Tab 的 NavigationStack** 上（不是 TabView 上）。
    ///
    /// 挂在 TabView 上的旧写法会把条子盖在 Tab 栏之上，播歌后 Tab 点不动——这就是反馈 ⑤ 的后半句。
    /// 挂在 NavigationStack 上，safeAreaInset 只挤压内容区，Tab 栏始终完整可点；
    /// 而且 push 到子页面（搜索页 / 歌单页）时条子照样在。
    func miniPlayerInset(onTap: @escaping () -> Void) -> some View {
        modifier(MiniPlayerInset(onTap: onTap))
    }
}

struct MiniPlayerInset: ViewModifier {

    @Environment(PlayerEngine.self) private var player
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.hasCurrentSong {
                MiniPlayerBar(onTap: onTap)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .padding(.bottom, Tokens.Spacing.xxs)
                    .padding(.top, Tokens.Spacing.xxs)
            }
        }
    }
}


