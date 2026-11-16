import SwiftUI
import UIKit

// MARK: - 播放页（第三轮：对齐 APK / Light Player 的交互）
//
// 交互口径（全部抄 APK `PlayerScreen.kt` 的 LyricsLargeView / PlayerControls）：
//   · **双击封面** → 进入大歌词；**单击或双击歌词** → 回到封面。（APK 就是 onDoubleTap 切换）
//   · 播放控制一行：播放模式（图标 + 文字）/ 上一首 / 播放 / 下一首 / 下载（图标 + 文字）。
//     文字必须留着——上一版只留图标，老板以为"顺序播放和下载没了"。
//   · **整页向下拽**即可收起，不用非得点左上角。
//   · 歌词切行按 `LyricsService.indexAt`（APK 同款：`line.timeMs <= position`），
//     位置用 25Hz 的 `player.lyricPositionMs`（精确位置 + 用户偏移）。
//
// 视觉：封面模糊铺底 + 压暗、大圆角封面、半透明歌词卡、白色圆形播放键。
struct NowPlayingView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSourceDetail = false
    @State private var showLyrics = false
    /// 拖动中的进度（0...1）；nil 表示没在拖，显示真实进度
    @State private var dragFraction: Double?
    /// 收起播放页的下拽距离
    @State private var sheetOffset: CGFloat = 0

    private var shownFraction: Double { dragFraction ?? player.progress }

    private var bufferedFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.bufferedTime / player.duration, 0), 1)
    }

    private var isFavorite: Bool {
        guard let song = player.currentSong else { return false }
        return library.isFavorite(song)
    }

    private var isDownloaded: Bool {
        guard let song = player.currentSong else { return false }
        return downloadFlow.isDownloaded(song)
    }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            GeometryReader { geo in
                VStack(spacing: 0) {
                    topBar

                    if showLyrics {
                        lyricsStage
                            .padding(.horizontal, Tokens.Spacing.m)
                            .padding(.top, Tokens.Spacing.xs)
                            .frame(maxHeight: .infinity)
                    } else {
                        coverStage(side: coverSide(in: geo.size))
                            .padding(.top, Tokens.Spacing.xs)
                        titles
                            .padding(.horizontal, Tokens.Spacing.l)
                            .padding(.top, Tokens.Spacing.m)
                        Spacer(minLength: 0)
                    }

                    scrubber
                        .padding(.horizontal, Tokens.Spacing.l)
                        .padding(.top, Tokens.Spacing.xs)
                    transport
                        .padding(.horizontal, Tokens.Spacing.s)
                        .padding(.top, Tokens.Spacing.xxs)
                    quickActions
                        .padding(.horizontal, Tokens.Spacing.l)
                        .padding(.bottom, Tokens.Spacing.xxs)
                }
            }
        }
        .offset(y: max(0, sheetOffset))
        .opacity(sheetOffset > 0 ? Double(max(0.35, 1 - sheetOffset / 700)) : 1)
        .simultaneousGesture(dismissDrag)
        .sheet(isPresented: $showSourceDetail) {
            SourceDetailView().environment(player)
        }
        // 音质选择必须挂在播放页自己身上：播放页是盖在根视图上的模态，根视图弹不出 sheet
        .sheet(isPresented: Binding(get: { downloadFlow.isPresented },
                                    set: { downloadFlow.isPresented = $0 }),
               onDismiss: { downloadFlow.dismiss() }) {
            DownloadSheet()
                .environment(downloadFlow)
                .environment(settings)
                .environment(player)
        }
        .task {
            Haptics.prepare()
            if player.lyrics.isEmpty && !player.isLoadingLyrics {
                player.reloadLyrics()
            }
        }
    }

    /// 封面边长：大屏最多 320，矮屏用高度反推（留出题名/进度/控制的位置）
    private func coverSide(in size: CGSize) -> CGFloat {
        let byHeight = size.height * 0.33
        return max(150, min(min(size.width - 96, byHeight), 320))
    }

    // MARK: 收起手势

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                // 只在「往下」时跟手；横向/上滑不接管
                if abs(value.translation.height) > abs(value.translation.width) {
                    sheetOffset = value.translation.height
                }
            }
            .onEnded { value in
                let far = value.translation.height > 110
                let fast = value.predictedEndTranslation.height > 280
                if far || fast {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        sheetOffset = 0
                    }
                }
            }
    }

    // MARK: 背景（模糊封面 + 压暗）

    private var backdrop: some View {
        ZStack {
            Color.black
            if let urlString = player.currentSong?.picURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable()
                            .scaledToFill()
                            .blur(radius: 46)
                            .opacity(0.85)
                    } else {
                        Color.black
                    }
                }
            }
            LinearGradient(
                colors: [Color.black.opacity(0.30), Color.black.opacity(0.10), Color.black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }

    // MARK: 顶栏

    private var topBar: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)

            ZStack {
                Text(showLyrics ? "歌词" : "正在播放")
                    .font(.footnote.weight(.medium))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.65))

                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("收起播放页")

                    Spacer()

                    moreMenu
                }
            }
            .frame(minHeight: 40)
        }
        .contentShape(Rectangle())
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
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    // MARK: 封面（双击看歌词）

    private func coverStage(side: CGFloat) -> some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Group {
                if let song = player.currentSong,
                   let urlString = song.picURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            coverPlaceholder
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
            .contentShape(Rectangle())
            // APK / Light Player 同款：双击封面进歌词
            .onTapGesture(count: 2) {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.26)) { showLyrics = true }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("专辑封面")
            .accessibilityHint("双击看歌词")
            .accessibilityAction {
                withAnimation(.easeInOut(duration: 0.26)) { showLyrics = true }
            }

            Text("双击封面看歌词")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var coverPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: 题名 + 收藏

    private var titles: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.xs) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentSong?.name ?? "未在播放")
                    .font(FontRole.playerTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(player.currentSong?.singer ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                guard let song = player.currentSong else { return }
                Haptics.favorite()
                withAnimation(Tokens.Motion.favorite) { library.toggleFavorite(song) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isFavorite ? Tokens.Palette.vermilion : Color.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(player.currentSong == nil)
            .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
        }
    }

    // MARK: 大歌词（双击/单击回封面）

    private var lyricsStage: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentSong?.name ?? "歌词")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(lyricsMeta)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !player.lyrics.isEmpty { offsetControls }
            }
            .padding(.horizontal, Tokens.Spacing.xs)

            if player.lyrics.isEmpty {
                lyricsEmpty
            } else {
                lyricsScroll
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("双击歌词回到封面")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.28))
                .padding(.trailing, Tokens.Spacing.s)
                .padding(.bottom, Tokens.Spacing.xxs)
        }
    }

    /// 歌词快/慢的现场微调（±200ms）
    private var offsetControls: some View {
        HStack(spacing: 4) {
            Button {
                settings.lyricOffsetMs = SettingsStore.clampOffset(settings.lyricOffsetMs - 200)
                Haptics.tap()
            } label: {
                Text("慢一点")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.press)

            Text(offsetLabel)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .frame(minWidth: 46)

            Button {
                settings.lyricOffsetMs = SettingsStore.clampOffset(settings.lyricOffsetMs + 200)
                Haptics.tap()
            } label: {
                Text("快一点")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.press)
        }
        .accessibilityElement(children: .contain)
    }

    private var offsetLabel: String {
        let v = settings.lyricOffsetMs
        if v == 0 { return "对齐" }
        return v > 0 ? "+\(v)ms" : "\(v)ms"
    }

    private var lyricsMeta: String {
        if player.isLoadingLyrics { return "正在取歌词…" }
        guard !player.lyrics.isEmpty else { return "还没取到歌词" }
        let word = player.lyrics.first?.hasWordTiming == true ? " · 逐字" : ""
        return "\(player.lyrics.count) 行 · \(player.lyricsSource)\(word)"
    }

    private var lyricsEmpty: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            if player.isLoadingLyrics {
                ProgressView().tint(.white)
                Text("正在取歌词…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                Text("这首歌还没取到歌词")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                Button("重试") { player.reloadLyrics() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.press)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Color.white.opacity(0.06))
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
                // 上下各留半屏：当前行滚到中间（与 APK 的 contentPadding=halfVh 同口径）
                .padding(.vertical, 96)
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
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
        // 双击回封面（与 APK 一致；单击留给"点某句跳转"，不做切回）
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.26)) { showLyrics = false }
        }
    }

    /// 一行歌词：当前行逐字染色（有逐字时间时），其他行 45% 不透明度。
    @ViewBuilder
    private func lyricLineView(index: Int, line: LyricLine) -> some View {
        let isCurrent = index == player.lyricIndex

        Group {
            if isCurrent {
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
                        .foregroundStyle(.white)
                }
            } else {
                Text(line.text)
                    .font(FontRole.lyricOther)
                    .lineSpacing(3)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // 点某一句 → 跳到那句（双击歌词回封面的手势在容器上，不冲突）
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
    }

    private var currentLineFont: Font {
        switch settings.lyricFontScale {
        case .system: return FontRole.lyricCurrent
        case .large: return .title.weight(.bold)
        case .extraLarge: return .largeTitle.weight(.bold)
        }
    }

    /// 当前行的富文本：逐字推进用 `lyricPositionMs`（已含用户偏移），与切行判定同源。
    private func currentLineString(_ line: LyricLine) -> AttributedString {
        guard line.hasWordTiming else {
            var whole = AttributedString(line.text)
            whole.foregroundColor = .white
            return whole
        }

        let nowMs = player.lyricPositionMs
        let unsung = Color.white.opacity(0.45)
        var result = AttributedString()
        for word in line.words {
            let progress = min(max(Double(nowMs - word.startMs) / 140.0, 0), 1)
            var piece = AttributedString(word.text)
            piece.foregroundColor = mix(unsung, .white, progress)
            result.append(piece)
        }
        return result
    }

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

    private var lyricsFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 32)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 32)
        }
    }

    // MARK: 进度

    private var scrubber: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: max(0, width * bufferedFraction), height: 4)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, width * shownFraction), height: 4)
                    Circle()
                        .fill(Color.white)
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
            .foregroundStyle(.white.opacity(0.55))
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

    // MARK: 控件（图标 + 文字，对齐 APK 的 PlayerControls）

    private var transport: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            controlColumn(icon: player.mode.symbolName,
                          label: player.mode.displayName,
                          tint: .white.opacity(0.85),
                          size: 19) {
                player.cycleMode()
                Haptics.trackChange()
            }
            .accessibilityLabel("播放模式，当前\(player.mode.displayName)")

            Spacer(minLength: 0)

            Button {
                player.previousTrack()
                Haptics.trackChange()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("上一首")

            Button {
                player.toggle()
                Haptics.playbackToggle()
            } label: {
                ZStack {
                    Circle().fill(Color.white)
                    if player.isResolving {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 64, height: 64)
                .contentShape(Circle())
            }
            .buttonStyle(.press)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            .disabled(player.isResolving)

            Button {
                player.nextTrack()
                Haptics.trackChange()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("下一首")

            Spacer(minLength: 0)

            controlColumn(icon: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle",
                          label: isDownloaded ? "已下载" : "下载",
                          tint: .white.opacity(0.85),
                          size: 19) {
                guard let song = player.currentSong else { return }
                downloadFlow.start(song: song, want: player.quality)
            }
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.35 : 1)
            .accessibilityLabel(isDownloaded ? "已下载，可重新下载" : "下载")
        }
    }

    /// 图标 + 文字的一列（APK 的播放模式/下载就是这种）
    private func controlColumn(icon: String, label: String, tint: Color, size: CGFloat,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 24)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 56)
            .frame(minHeight: Tokens.Spacing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
    }

    /// 底部一行：状态/音源信息（小字，别抢画面）
    private var quickActions: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if player.isResolving {
                ProgressView().tint(.white).scaleEffect(0.6)
            }
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(player.errorText == nil ? Color.white.opacity(0.45) : Color.orange)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let source = player.source {
                Text("\(source.backendName) · \(source.format.uppercased())")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.40))
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 18)
    }

    private var statusLine: String {
        if let error = player.errorText { return error }
        if let status = player.statusText, !status.isEmpty { return status }
        return player.mode.displayName
    }

    // MARK: 工具

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
