import SwiftUI
import UIKit

// MARK: - 播放页（第四轮：按老板群内截屏的版式重排）
//
// 第三轮的惨痛教训（老板第四轮录屏）：
//   **整页横向溢出**——`GeometryReader` 里的宽度被撑到比屏幕还宽，于是所有"靠 Spacer 顶到两头"的
//   元素都被推到屏幕外面：左右上角的收起/更多按钮、歌名歌手、进度条两端的时间、
//   播放模式（顺序播放）与下载、底部状态行，全都看不见；只剩居中的封面、居中的三个键和一条
//   通到底的进度线。所以这一版**每一行都显式钉宽度**（`LayoutRules.playerWidth`），
//   不再有任何"让 Spacer 自己顶"的写法。
//
// 版式照群里那张参考截屏（Light Player 那一路）：
//   顶栏（收起 / 正在播放 / 更多）
//   居中大封面（双击进歌词）
//   居中歌名 + 歌手 + 音质标签（FLAC / 1533 kbps / 酷我 / 已下载）
//   一行四个功能键（收藏 / 下载 / 歌词 / 音源）——**图标 + 文字**，不许只剩图标
//   进度条 + 两端时间
//   一行五个播放键（播放模式 / 上一首 / 播放 / 下一首 / 播放列表），模式键带文字
//   底部一行状态（音源 / 错误）
struct NowPlayingView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadFlow.self) private var downloadFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSourceDetail = false
    @State private var showQueue = false
    @State private var showLyrics = false
    /// 拖动中的进度（0...1）；nil 表示没在拖，显示真实进度
    @State private var dragFraction: Double?
    /// 收起播放页的下拽距离
    @State private var sheetOffset: CGFloat = 0

    // MARK: 尺寸

    /// 屏幕宽（只用来给"外层给到多宽"做上限，不参与任何布局计算）
    private static var screenWidth: Double {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let w = scenes.first?.screen.bounds.width, w > 0 { return Double(w) }
        return 393
    }

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

    // MARK: 主体

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            GeometryReader { geo in
                // 先把宽度钉到屏幕上（外层给多宽都不认），后面每一行都按这个 w 排
                let w = CGFloat(LayoutRules.playerWidth(available: Double(geo.size.width),
                                                       screen: Self.screenWidth))
                VStack(spacing: 0) {
                    topBar(width: w)

                    if showLyrics {
                        lyricsStage(width: w)
                            .frame(maxHeight: .infinity)
                    } else {
                        coverStage(width: w, containerHeight: geo.size.height)
                        titleStage(width: w)
                        Spacer(minLength: Tokens.Spacing.xs)
                    }

                    quickRow(width: w)
                        .padding(.top, Tokens.Spacing.xs)

                    progressRow(width: w)
                        .padding(.top, Tokens.Spacing.xs)

                    transportRow(width: w)
                        .padding(.top, Tokens.Spacing.xxs)

                    statusRow(width: w)
                        .padding(.top, Tokens.Spacing.xxs)
                        .padding(.bottom, Tokens.Spacing.xs)
                }
                // 关键：整块内容先钉到 w 宽，再居中。外层就算给到 1200pt 也穿不出去。
                .frame(width: w)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .offset(y: max(0, sheetOffset))
        .opacity(sheetOffset > 0 ? Double(max(0.35, 1 - sheetOffset / 700)) : 1)
        .simultaneousGesture(dismissDrag)
        .sheet(isPresented: $showSourceDetail) {
            SourceDetailView().environment(player)
        }
        .sheet(isPresented: $showQueue) {
            PlayerQueueSheet().environment(player)
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
        // 底部「更多」菜单里那条下载入口用得到
        .onChange(of: player.currentSong?.id) { _, _ in
            showLyrics = false
            dragFraction = nil
        }
    }

    // MARK: 收起手势

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
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

    // MARK: 顶栏（钉宽度：收起在左、更多在右，永远在屏幕里）

    private func topBar(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Tokens.Spacing.minTapTarget, height: Tokens.Spacing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("收起播放页")

            Spacer(minLength: 0)

            Text(showLyrics ? "歌词" : "正在播放")
                .font(.footnote.weight(.medium))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)

            Spacer(minLength: 0)

            moreMenu
                .frame(width: Tokens.Spacing.minTapTarget, height: Tokens.Spacing.minTapTarget)
        }
        .frame(width: width)
        .padding(.top, Tokens.Spacing.xxs)
    }

    private var moreMenu: some View {
        Menu {
            Section("播放模式") {
                ForEach(PlayMode.allCases, id: \.self) { mode in
                    Button {
                        player.setMode(mode)
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
            Button {
                showQueue = true
            } label: {
                Label("播放列表", systemImage: "list.bullet")
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
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Tokens.Spacing.minTapTarget, height: Tokens.Spacing.minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    // MARK: 封面（双击进歌词）

    private func coverStage(width: CGFloat, containerHeight: CGFloat) -> some View {
        let side = coverSide(width: width, containerHeight: containerHeight)
        return VStack(spacing: Tokens.Spacing.xs) {
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
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
            .contentShape(Rectangle())
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
        .frame(width: width)
        .padding(.top, Tokens.Spacing.s)
    }

    /// 封面边长：宽高中取小的一头反推，保证下面四行控件都还在屏幕里
    private func coverSide(width: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let byHeight = containerHeight * 0.32
        let byWidth = width - Tokens.Spacing.xxl * 3
        return max(140, min(min(byWidth, byHeight), 300))
    }

    private var coverPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: 歌名 / 歌手 / 音质标签（居中，参考截屏的排法）

    private func titleStage(width: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(player.currentSong?.name ?? "未在播放")
                .font(FontRole.playerTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(player.currentSong?.singer ?? "")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)

            chipsRow(width: width)
                .padding(.top, 2)
        }
        .frame(width: width - Tokens.Spacing.xl * 2)
        .padding(.top, Tokens.Spacing.m)
    }

    /// 音质事实（参考截屏那一排小胶囊）：容器 / 码率 / 平台 / 是否已下载
    private func chipsRow(width: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.xxs + 2) {
                ForEach(Array(factChips.enumerated()), id: \.offset) { _, chip in
                    Text(chip)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 24)
        }
        .frame(width: width - Tokens.Spacing.xl * 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("音质 \(factChips.joined(separator: "，"))")
    }

    private var factChips: [String] {
        var out: [String] = []
        if let source = player.source {
            if !source.format.isEmpty { out.append(source.format.uppercased()) }
            if source.kbps > 0 { out.append("\(source.kbps) kbps") }
            if source.backendName != "本地文件" { out.append(source.platform.shortName) }
        }
        out.append(player.quality.displayName)
        if isDownloaded { out.append("已下载") }
        return out
    }

    // MARK: 一行四个功能键（收藏 / 下载 / 歌词 / 音源）——图标 + 文字缺一不可

    private func quickRow(width: CGFloat) -> some View {
        let margin = Tokens.Spacing.m
        let itemWidth = max(56, (width - margin * 2) / 4)
        return HStack(spacing: 0) {
            quickButton(icon: isFavorite ? "heart.fill" : "heart",
                        label: isFavorite ? "已收藏" : "收藏",
                        tint: isFavorite ? Tokens.Palette.vermilion : Color.white.opacity(0.82)) {
                guard let song = player.currentSong else { return }
                Haptics.favorite()
                withAnimation(Tokens.Motion.favorite) { library.toggleFavorite(song) }
            }
            .frame(width: itemWidth, height: 52)
            .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")

            quickButton(icon: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle",
                        label: isDownloaded ? "已下载" : "下载",
                        tint: .white.opacity(0.82)) {
                guard let song = player.currentSong else { return }
                downloadFlow.start(song: song, want: player.quality)
            }
            .frame(width: itemWidth, height: 52)
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.35 : 1)
            .accessibilityLabel(isDownloaded ? "已下载，可重新下载" : "下载")

            quickButton(icon: showLyrics ? "text.alignleft" : "quote.bubble",
                        label: showLyrics ? "封面" : "歌词",
                        tint: .white.opacity(0.82)) {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.26)) { showLyrics.toggle() }
            }
            .frame(width: itemWidth, height: 52)
            .accessibilityLabel(showLyrics ? "回到封面" : "看歌词")

            quickButton(icon: "antenna.radiowaves.left.and.right",
                        label: "音源",
                        tint: .white.opacity(0.82)) {
                showSourceDetail = true
            }
            .frame(width: itemWidth, height: 52)
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.35 : 1)
            .accessibilityLabel("音源详情")
        }
        .frame(width: width)
    }

    private func quickButton(icon: String, label: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
    }

    // MARK: 进度（宽度直接传进来，不用嵌套 GeometryReader）

    private func progressRow(width: CGFloat) -> some View {
        let barWidth = max(80, width - Tokens.Spacing.l * 2)
        return VStack(spacing: 2) {
            progressBar(width: barWidth)

            HStack(spacing: 0) {
                Text(Self.timeText(currentShownTime))
                Spacer(minLength: 0)
                Text("-" + Self.timeText(remainingShownTime))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: barWidth)
        }
        .frame(width: width)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.timeText(player.currentTime)) / \(Self.timeText(player.duration))")
        .accessibilityAdjustableAction { direction in
            guard player.duration > 0 else { return }
            let step = 5.0
            let target = direction == .increment ? player.currentTime + step : player.currentTime - step
            player.seek(toSeconds: target)
        }
    }

    private var currentShownTime: Double {
        if let f = dragFraction { return f * player.duration }
        return player.currentTime
    }

    private var remainingShownTime: Double {
        max(0, player.duration - currentShownTime)
    }

    private func progressBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.20))
                .frame(width: width, height: 4)
            Capsule()
                .fill(Color.white.opacity(0.34))
                .frame(width: max(0, width * bufferedFraction), height: 4)
            Capsule()
                .fill(Color.white)
                .frame(width: max(0, width * shownFraction), height: 4)
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .offset(x: max(0, min(width - 12, width * shownFraction - 6)))
        }
        .frame(width: width, height: 22, alignment: .leading)
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

    // MARK: 一行五个播放键（模式带文字：老板两次说"顺序播放没了"）

    private func transportRow(width: CGFloat) -> some View {
        let margin = Tokens.Spacing.s
        let sideWidth = max(52, (width - margin * 2 - 64) / 4)
        return HStack(spacing: 0) {
            modeButton
                .frame(width: sideWidth, height: 56)

            transportButton(icon: "backward.fill", label: "上一首") {
                player.previousTrack()
                Haptics.trackChange()
            }
            .frame(width: sideWidth, height: 56)

            playButton
                .frame(width: 64, height: 64)

            transportButton(icon: "forward.fill", label: "下一首") {
                player.nextTrack()
                Haptics.trackChange()
            }
            .frame(width: sideWidth, height: 56)

            queueButton
                .frame(width: sideWidth, height: 56)
        }
        .frame(width: width)
    }

    private var modeButton: some View {
        Button {
            player.cycleMode()
            Haptics.trackChange()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: player.mode.symbolName)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                Text(player.mode.displayName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel("播放模式，当前\(player.mode.displayName)")
        .accessibilityHint("轻点切换")
    }

    private var queueButton: some View {
        Button {
            Haptics.tap()
            showQueue = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                Text("播放列表")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel("播放列表")
    }

    private func transportButton(icon: String, label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: Tokens.Spacing.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }

    private var playButton: some View {
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
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.black)
                }
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
        .disabled(player.isResolving)
    }

    // MARK: 底部状态行

    private func statusRow(width: CGFloat) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if player.isResolving {
                ProgressView().tint(.white).scaleEffect(0.6)
            }
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(player.errorText == nil ? Color.white.opacity(0.45) : Color.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(width: max(80, width - Tokens.Spacing.l * 2))
        .frame(minHeight: 16)
    }

    private var statusLine: String {
        if let error = player.errorText { return error }
        if let status = player.statusText, !status.isEmpty { return status }
        return player.mode.displayName
    }

    // MARK: 大歌词

    private func lyricsStage(width: CGFloat) -> some View {
        VStack(spacing: Tokens.Spacing.xs) {
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
                if !player.lyrics.isEmpty {
                    Text(offsetLabel)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(width: max(80, width - Tokens.Spacing.m * 2))

            offsetRow(width: width)

            if player.lyrics.isEmpty {
                lyricsEmpty(width: width)
            } else {
                lyricsList(width: width)
            }
        }
        .frame(width: width)
        .padding(.top, Tokens.Spacing.xs)
    }

    /// 歌词快慢：三个胶囊横向排死，永远不会被挤掉（上一版被 Spacer 顶出屏幕，老板调不了）
    private func offsetRow(width: CGFloat) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            offsetPill(title: "慢一点") {
                settings.lyricOffsetMs = SettingsStore.clampOffset(settings.lyricOffsetMs - 200)
                Haptics.tap()
            }
            offsetPill(title: "归零") {
                settings.lyricOffsetMs = 0
                Haptics.tap()
            }
            offsetPill(title: "快一点") {
                settings.lyricOffsetMs = SettingsStore.clampOffset(settings.lyricOffsetMs + 200)
                Haptics.tap()
            }
        }
        .frame(width: max(80, width - Tokens.Spacing.m * 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("歌词时间微调")
    }

    private func offsetPill(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        }
        .buttonStyle(.press)
    }

    private var offsetLabel: String {
        let v = settings.lyricOffsetMs
        if v == 0 { return "对齐" }
        let seconds = Double(abs(v)) / 1000
        return (v > 0 ? "+" : "−") + String(format: "%.1fs", seconds)
    }

    private var lyricsMeta: String {
        if player.isLoadingLyrics { return "正在取歌词…" }
        guard !player.lyrics.isEmpty else { return "还没取到歌词" }
        let word = player.lyrics.first?.hasWordTiming == true ? " · 逐字" : ""
        return "\(player.lyrics.count) 行 · \(player.lyricsSource)\(word)"
    }

    private func lyricsEmpty(width: CGFloat) -> some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            if player.isLoadingLyrics {
                ProgressView().tint(.white)
                Text("正在取歌词…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Image(systemName: "quote.bubble")
                    .font(.title3.weight(.light))
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
        .frame(width: max(80, width - Tokens.Spacing.m * 2))
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, Tokens.Spacing.m)
    }

    private func lyricsList(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: Tokens.Spacing.s) {
                    ForEach(Array(player.lyrics.enumerated()), id: \.offset) { idx, line in
                        lyricLineView(index: idx, line: line)
                            .id(idx)
                    }
                }
                .frame(width: max(80, width - Tokens.Spacing.l * 2))
                .padding(.vertical, 72)
            }
            .frame(width: max(80, width - Tokens.Spacing.m * 2))
            .mask(lyricsFadeMask)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
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
    }

    /// 一行歌词：当前行逐字染色（有逐字时间时），其他行 45% 不透明度。
    private func lyricLineView(index: Int, line: LyricLine) -> some View {
        let isCurrent = index == player.lyricIndex

        return Group {
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 点某一句 → 跳到那句（偏移已算进去，跳完高亮就落在这一句上）
        .onTapGesture {
            guard player.duration > 0 else { return }
            Haptics.lyricSeek()
            player.seek(toLyricLine: index)
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
                .frame(height: 28)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
        }
    }

    // MARK: 工具

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 播放列表（队列）

/// 播放页「播放列表」：当前队列一行一首，点一首直接跳过去。
struct PlayerQueueSheet: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.queue.isEmpty {
                    ContentUnavailableView("队列是空的", systemImage: "music.note.list")
                } else {
                    List {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { index, song in
                            Button {
                                player.jump(to: index)
                                dismiss()
                            } label: {
                                HStack(spacing: Tokens.Spacing.s) {
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 22, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(song.name)
                                            .font(.body)
                                            .foregroundStyle(index == player.index ? Tokens.Palette.vermilion : Color.primary)
                                            .lineLimit(1)
                                        Text(song.singer)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if index == player.index {
                                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                            .font(.caption)
                                            .foregroundStyle(Tokens.Palette.vermilion)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("播放列表（\(player.queue.count) 首）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
