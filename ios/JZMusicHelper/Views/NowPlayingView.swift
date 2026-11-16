import SwiftUI
import UIKit

// MARK: - 播放页
//
// 设计稿 §3.6 的第一个可运行版本：封面 / 题名 / 进度（含缓冲带）/ 三态循环 / 上一首-播放-下一首 /
// 状态行与音源行。歌词区（点封面切换）等歌词层移植完再加，这里先不放空的占位。
struct NowPlayingView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showSourceDetail = false
    /// 设计稿 §3.6：开「减弱动态效果」时歌词直接跳行，不做位移过渡
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 拖动中的进度（0...1）；nil 表示没在拖，显示真实进度
    @State private var dragFraction: Double?
    /// 封面 ↔ 歌词
    @State private var showLyrics = false

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
                    stage
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
        .sheet(isPresented: $showSourceDetail) {
            SourceDetailView().environment(player)
        }
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
                    Button {
                        showSourceDetail = true
                    } label: {
                        Label("音源详情", systemImage: "antenna.radiowaves.left.and.right")
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

    // MARK: 封面 / 歌词

    /// 封面与歌词共用一个方形区域：点击封面切歌词，点歌词切回封面（设计稿 §3.6）
    @ViewBuilder
    private var stage: some View {
        if showLyrics {
            lyricsPanel
                .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showLyrics = false } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("歌词，轻点返回封面")
        } else {
            artwork
                .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showLyrics = true } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("专辑封面，轻点看歌词")
        }
    }

    private var lyricsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    if player.lyrics.isEmpty {
                        VStack(spacing: 10) {
                            if player.isLoadingLyrics { ProgressView() }
                            Text(player.isLoadingLyrics ? "歌词加载中…" : "暂无歌词")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 60)
                    } else {
                        ForEach(Array(player.lyrics.enumerated()), id: \.offset) { idx, line in
                            lyricLineView(index: idx, line: line)
                                .id(idx)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                // 上下各留一屏余量，当前行才能稳定停在正中
                .padding(.vertical, 120)
            }
            .mask(lyricsFadeMask)
            .onChange(of: player.lyricIndex) { _, idx in
                guard idx >= 0 else { return }
                if reduceMotion {
                    proxy.scrollTo(idx, anchor: .center)
                } else {
                    // 设计稿 §3.6：行推进 spring(0.38, 0.92)
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.92)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
            .onAppear {
                guard player.lyricIndex >= 0 else { return }
                proxy.scrollTo(player.lyricIndex, anchor: .center)
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 一行歌词：当前行逐字染色（有逐字时间时），其他行 55% 不透明度。
    @ViewBuilder
    private func lyricLineView(index: Int, line: LyricLine) -> some View {
        let isCurrent = index == player.lyricIndex

        Group {
            if isCurrent {
                // 逐字推进要 30fps；用 TimelineView 而不是 0.5s 的时间观察者，否则字是「跳」着亮的
                if settings.lyricAnimation {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { _ in
                        Text(currentLineString(line))
                            .font(currentLineFont)
                            .lineSpacing(4)
                    }
                } else {
                    Text(line.text)
                        .font(currentLineFont)
                        .lineSpacing(4)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            } else {
                Text(line.text)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // 设计稿 §1：可点区域 ≥44pt——歌词行本身只有 22~28pt，补 8pt 上下内边距
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard player.duration > 0 else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            player.seek(toFraction: (Double(line.timeMs) / 1000) / player.duration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.text)
        .accessibilityValue(isCurrent ? "第 \(index + 1) 行，共 \(player.lyrics.count) 行" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("跳到这一句")
        .accessibilityAction {
            guard player.duration > 0 else { return }
            player.seek(toFraction: (Double(line.timeMs) / 1000) / player.duration)
        }
    }

    private var currentLineFont: Font {
        switch settings.lyricFontScale {
        case .system: return FontRole.lyricCurrent
        case .large: return .title.weight(.bold)
        case .extraLarge: return .largeTitle.weight(.bold)
        }
    }

    /// 当前行的富文本：有逐字时间就按每字 start/dur 推进颜色，没有就整行高亮。
    private func currentLineString(_ line: LyricLine) -> AttributedString {
        guard line.hasWordTiming else {
            var whole = AttributedString(line.text)
            whole.foregroundColor = Color.accentColor
            return whole
        }

        let nowMs = Int(player.preciseTime * 1000)
        let unsung = Color.secondary.opacity(0.55)
        var result = AttributedString()
        for word in line.words {
            // 设计稿 §3.6：单字 140ms 线性过渡
            let progress = min(max(Double(nowMs - word.startMs) / 140.0, 0), 1)
            var piece = AttributedString(word.text)
            piece.foregroundColor = mix(unsung, Color.accentColor, progress)
            result.append(piece)
        }
        return result
    }

    /// SwiftUI 没有内置 Color 插值，这里用 UIColor 通道手动混一下。
    private func mix(_ from: Color, _ to: Color, _ t: Double) -> Color {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        guard UIColor(from).getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
              UIColor(to).getRed(&tr, green: &tg, blue: &tb, alpha: &ta) else {
            return to
        }
        let k = CGFloat(min(max(t, 0), 1))
        return Color(uiColor: UIColor(
            red: fr + (tr - fr) * k,
            green: fg + (tg - fg) * k,
            blue: fb + (tb - fb) * k,
            alpha: fa + (ta - fa) * k
        ))
    }

    /// 歌词区上下淡出（设计稿 §3.6 的「上下一屏淡出」）
    private var lyricsFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
        }
    }

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
        HStack(alignment: .top, spacing: 8) {
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
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() }
            } label: {
                Image(systemName: showLyrics ? "photo" : "quote.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showLyrics ? "显示封面" : "显示歌词")
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
            if !player.lyrics.isEmpty {
                Text("歌词 \(player.lyrics.count) 行 · 来自\(player.lyricsSource)\(player.hasLyrics && player.lyrics.first?.hasWordTiming == true ? " · 逐字" : "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
