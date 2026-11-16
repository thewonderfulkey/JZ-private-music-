import SwiftUI

// MARK: - 播放页
//
// 设计稿 §3.6 的第一个可运行版本：封面 / 题名 / 进度（含缓冲带）/ 三态循环 / 上一首-播放-下一首 /
// 状态行与音源行。歌词区（点封面切换）等歌词层移植完再加，这里先不放空的占位。
struct NowPlayingView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// 拖动中的进度（0...1）；nil 表示没在拖，显示真实进度
    @State private var dragFraction: Double?

    private var shownFraction: Double {
        dragFraction ?? player.progress
    }

    private var bufferedFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.bufferedTime / player.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    artwork
                        .padding(.horizontal, 34)
                        .padding(.top, 8)
                    titles
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                    scrubber
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                    transport
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                    footer
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .background(paperBackground.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private var paperBackground: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: 顶栏

    private var topBar: some View {
        ZStack {
            Text("正在播放")
                .font(.footnote.weight(.medium))
                .tracking(2)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭播放页")

                Spacer()

                Menu {
                    Section("播放模式") {
                        ForEach(PlayMode.allCases, id: \.self) { mode in
                            Button {
                                if player.mode != mode { player.setMode(mode) }
                            } label: {
                                Label(mode.displayName, systemImage: mode.symbolName)
                            }
                        }
                    }
                    if let source = player.source {
                        Section("当前音源") {
                            Text("\(source.backendName) · \(source.format.uppercased()) · \(source.kbps) kbps")
                            Text(source.note)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    // MARK: 封面

    @ViewBuilder
    private var artwork: some View {
        let side = min(UIScreen.main.bounds.width - 68, 380)
        Group {
            if let song = player.currentSong,
               let urlString = song.picURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .accessibilityLabel("专辑封面")
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 题名

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.currentSong?.name ?? "未在播放")
                .font(.title2.weight(.bold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(player.currentSong?.singer ?? "")
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 进度

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.primary.opacity(0.20))
                        .frame(width: max(0, width * bufferedFraction), height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, width * shownFraction), height: 4)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(width - 12, width * shownFraction - 6)))
                }
                .frame(height: 24, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / max(width, 1), 0), 1)
                        }
                        .onEnded { _ in
                            if let f = dragFraction { player.seek(toFraction: f) }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 24)

            HStack {
                Text(Self.timeText(dragFraction.map { $0 * player.duration } ?? player.currentTime))
                Spacer()
                Text("-" + Self.timeText(max(0, player.duration - (dragFraction.map { $0 * player.duration } ?? player.currentTime))))
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.timeText(player.currentTime)) / \(Self.timeText(player.duration))")
        .accessibilityAdjustableAction { direction in
            let step = 5.0
            let target = direction == .increment ? player.currentTime + step : player.currentTime - step
            guard player.duration > 0 else { return }
            player.seek(toFraction: target / player.duration)
        }
    }

    // MARK: 控件

    private var transport: some View {
        HStack {
            Button {
                player.cycleMode()
            } label: {
                Image(systemName: player.mode.symbolName)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放模式，当前\(player.mode.displayName)")

            Spacer()

            Button {
                player.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一首")

            Button {
                player.toggle()
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    if player.isResolving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            .disabled(player.isResolving)

            Button {
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")

            Spacer()

            // 下载入口（P2 接下载层；先占位但不假装可用）
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 52, height: 52)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("下载（尚未接入）")
                .accessibilityHidden(false)
        }
        .overlay(alignment: .bottom) {
            Text(player.mode.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .offset(y: 18)
        }
        .padding(.bottom, 18)
    }

    // MARK: 状态与音源

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if player.isResolving {
                    ProgressView().scaleEffect(0.6)
                }
                Text(player.errorText ?? player.statusText ?? " ")
                    .font(.caption)
                    .foregroundStyle(player.errorText == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            .frame(height: 16, alignment: .leading)

            if let source = player.source {
                HStack(spacing: 4) {
                    Text("音源 \(source.backendName) · \(source.format.uppercased()) · \(source.kbps) kbps")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 工具

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
