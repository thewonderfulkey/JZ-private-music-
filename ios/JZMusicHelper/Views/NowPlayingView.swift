import SwiftUI
import UIKit

// MARK: - 播放页（老板反馈 ③④）
//
// ③ **全屏覆盖**：外面从 sheet 改成 `fullScreenCover`（见 RootTabView）。sheet 那种"拉起一张布"的
//    观感就是它只会盖到 .large detent + 圆角 + 后面能看到桌面；全屏之后才是"进播放页"。
//    收起来的路径保留两条：左上角 chevron.down，或者按住顶部往下拽（>90pt）。
//
// ④ **歌词常驻**：上一版歌词藏在"点封面"后面（`showLyrics`），不点就永远看不见，看起来就是
//    "歌词是空的"。现在封面下面直接跟一块歌词面板（当前行高亮 + 上下淡出 + 自动滚到中间），
//    空的时候写明原因并给「重试」；打开播放页时如果歌词还是空的，自动再取一次（`reloadLyrics`）。
//
// 其余：封面 / 题名 + 收藏 / 进度（含缓冲带）/ 播放模式 / 上一首-播放-下一首 / 下载 / 状态与音源。
struct NowPlayingView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSourceDetail = false
    /// 拖动中的进度（0...1）；nil 表示没在拖，显示真实进度
    @State private var dragFraction: Double?

    private var shownFraction: Double { dragFraction ?? player.progress }

    private var bufferedFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.bufferedTime / player.duration, 0), 1)
    }

    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return library.isFavorite(song)
    }

    /// 当前这首歌是否已经下到本地（决定按钮用实心图标）
    private var isDownloaded: Bool {
        guard let song = player.currentSong else { return false }
        return downloadFlow.isDownloaded(song)
    }

    var body: some View {
        GeometryReader { geo in
            // 封面尺寸按屏幕算：大屏最多 300pt，SE 这种矮屏用高度反推，保证歌词区一定留得下
            let side = max(140, min(min(geo.size.width - 104, geo.size.height * 0.30), 300))
            VStack(spacing: 0) {
                topBar
                artwork(side: side)
                    .padding(.top, Tokens.Spacing.xxs)
                titles
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.top, Tokens.Spacing.m)
                lyricsBlock
                    .padding(.horizontal, Tokens.Spacing.m)
                    .padding(.top, Tokens.Spacing.s)
                    .frame(maxHeight: .infinity)
                scrubber
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.top, Tokens.Spacing.xxs)
                transport
                    .padding(.horizontal, Tokens.Spacing.l)
                footer
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.bottom, Tokens.Spacing.xs)
            }
        }
        .background(paperBackground.ignoresSafeArea())
        .sheet(isPresented: $showSourceDetail) {
            SourceDetailView().environment(player)
        }
        .task {
            Haptics.prepare()
            // 打开播放页时歌词仍为空 → 再取一次（切歌瞬间取词失败不再等于永久没词）
            player.reloadLyrics()
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
        VStack(spacing: 6) {
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)

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
                    .accessibilityLabel("收起播放页")

                    Spacer()

                    moreMenu
                }
            }
            .frame(minHeight: 40)
        }
        .contentShape(Rectangle())
        // 往下拽收起来（sheet 的手感，但内容是满屏的）
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 90 { dismiss() }
                }
        )
    }

    private var moreMenu: some View {
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
            if let song = player.currentSong {
                Button {
                    downloadFlow.start(song: song, want: player.quality)
                } label: {
                    Label("下载…", systemImage: "arrow.down.circle")
                }
                ShareLink(item: SongShare.text(song: song, source: player.source)) {
                    Label("分享", systemImage: "square.and.arrow.up")
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

    // MARK: 封面

    private func artwork(side: CGFloat) -> some View {
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
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.playerArtwork, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .accessibilityLabel("专辑封面")
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 题名 + 收藏

    private var titles: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.name ?? "未在播放")
                    .font(FontRole.playerTitle)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(player.currentSong?.singer ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                guard let song = player.currentSong else { return }
                Haptics.favorite()
                withAnimation(Tokens.Motion.favorite) { library.toggleFavorite(song) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isFavorite ? Tokens.Palette.vermilion : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
            .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
        }
    }

    // MARK: 歌词（反馈 ④：常驻可见）

    private var lyricsBlock: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.xs) {
                Text("歌词")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if player.isLoadingLyrics {
                    ProgressView().scaleEffect(0.6)
                } else if !player.lyrics.isEmpty {
                    Text(lyricsMeta)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if player.lyrics.isEmpty && !player.isLoadingLyrics {
                    Button("重试") { player.reloadLyrics() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.vermilion)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Tokens.Spacing.xs)

            if player.lyrics.isEmpty {
                lyricsEmpty
            } else {
                lyricsScroll
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var lyricsMeta: String {
        let word = player.lyrics.first?.hasWordTiming == true ? " · 逐字" : ""
        return "\(player.lyrics.count) 行 · \(player.lyricsSource)\(word)"
    }

    private var lyricsEmpty: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            if player.isLoadingLyrics {
                ProgressView()
                Text("正在取歌词…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("这首歌还没取到歌词")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("换下一首再回来、或点右上「重试」重新取")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: Tokens.Spacing.m) {
                    ForEach(Array(player.lyrics.enumerated()), id: \.offset) { idx, line in
                        lyricLineView(index: idx, line: line)
                            .id(idx)
                    }
                }
                .frame(maxWidth: .infinity)
                // 上下各留一段余量，当前行才能稳定停在正中
                .padding(.vertical, 72)
            }
            .mask(lyricsFadeMask)
            .onChange(of: player.lyricIndex) { _, idx in
                guard idx >= 0 else { return }
                if reduceMotion {
                    proxy.scrollTo(idx, anchor: .center)
                } else {
                    withAnimation(Tokens.Motion.lyricAdvance) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
            .onAppear {
                guard player.lyricIndex >= 0 else { return }
                proxy.scrollTo(player.lyricIndex, anchor: .center)
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
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
                            .lineSpacing(3)
                    }
                } else {
                    Text(line.text)
                        .font(currentLineFont)
                        .lineSpacing(3)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
            } else {
                Text(line.text)
                    .font(FontRole.lyricOther)
                    .lineSpacing(3)
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard player.duration > 0 else { return }
            Haptics.lyricSeek()
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
            whole.foregroundColor = Tokens.Palette.vermilion
            return whole
        }

        let nowMs = Int(player.preciseTime * 1000)
        let unsung = Color.secondary.opacity(0.55)
        var result = AttributedString()
        for word in line.words {
            // 设计稿 §3.6：单字 140ms 线性过渡
            let progress = min(max(Double(nowMs - word.startMs) / 140.0, 0), 1)
            var piece = AttributedString(word.text)
            piece.foregroundColor = mix(unsung, Tokens.Palette.vermilion, progress)
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
                .frame(height: 36)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 36)
        }
    }

    // MARK: 进度

    private var scrubber: some View {
        VStack(spacing: 2) {
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
            .font(.caption)
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
        HStack(spacing: Tokens.Spacing.xs) {
            Button {
                player.cycleMode()
                Haptics.trackChange()
            } label: {
                Image(systemName: player.mode.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: Tokens.Size.transportButton, height: Tokens.Size.transportButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放模式，当前\(player.mode.displayName)")

            Spacer(minLength: 0)

            Button {
                player.previousTrack()
                Haptics.trackChange()
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
                Haptics.playbackToggle()
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    if player.isResolving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: Tokens.Size.playButton, height: Tokens.Size.playButton)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            .disabled(player.isResolving)

            Button {
                player.nextTrack()
                Haptics.trackChange()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")

            Spacer(minLength: 0)

            Button {
                guard let song = player.currentSong else { return }
                downloadFlow.start(song: song, want: player.quality)
            } label: {
                Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: Tokens.Size.transportButton, height: Tokens.Size.transportButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
            .foregroundStyle(Color.primary)
            .opacity(player.currentSong == nil ? 0.35 : 1)
            .accessibilityLabel(isDownloaded ? "已下载，可重新下载" : "下载")
        }
    }

    // MARK: 状态与音源

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if player.isResolving {
                    ProgressView().scaleEffect(0.6)
                }
                Text(player.errorText ?? player.statusText ?? " ")
                    .font(.caption2)
                    .foregroundStyle(player.errorText == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }

            if let source = player.source {
                Text("音源 \(source.backendName) · \(source.format.uppercased()) · \(source.kbps) kbps")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: 工具

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
