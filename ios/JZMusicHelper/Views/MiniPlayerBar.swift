import SwiftUI

// MARK: - 迷你播放条
//
// 设计稿 §2：常驻在 Tab 栏之上，56pt 高，`.regularMaterial` + 发丝上边线，圆角 12，左右各 8pt。
// 点整条 → 打开播放页；右侧播放/暂停；进度用底部 2pt 细线（不抢视觉）。
struct MiniPlayerBar: View {

    @Environment(PlayerEngine.self) private var player
    let onTap: () -> Void

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 10) {
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
                Spacer(minLength: 8)
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 56)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) {
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
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在播放：\(song.name)，\(song.singer)")
            .accessibilityHint("轻点打开播放页")
        }
    }

    @ViewBuilder
    private func artwork(for song: Song) -> some View {
        Group {
            if let urlString = song.picURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholderArtwork
                    }
                }
            } else {
                placeholderArtwork
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholderArtwork: some View {
        ZStack {
            Color.primary.opacity(0.06)
            Image(systemName: "music.note")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
