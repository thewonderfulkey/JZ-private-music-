import SwiftUI
import UIKit

// MARK: - 播放页（第五轮：间距 / 标签居中 / 全屏歌词 / 歌词手感）
//
// 第三轮的惨痛教训（老板第四轮录屏）：
//   **整页横向溢出**——`GeometryReader` 里的宽度被撑到比屏幕还宽，于是所有"靠 Spacer 顶到两头"的
//   元素都被推到屏幕外面：左右上角的收起/更多按钮、歌名歌手、进度条两端的时间、
//   播放模式（顺序播放）与下载、底部状态行，全都看不见。所以这一版**每一行都显式钉宽度**
//   （`LayoutRules.playerWidth`），不再有任何"让 Spacer 自己顶"的写法。
//
// 第五轮老板截屏（对照 APK 播放页）暴露的四个问题，都在这一个文件里：
//   ① 封面和播放栏中间一大段空白 + 歌名下面的音质标签没居中
//      → 空白不是封面太小，是标题与功能键之间那个**没有上限的 `Spacer()`** 把富余高度全吞了；
//        现在换成 `LayoutRules.playerGap(availableHeight:)` 给出的有上限留白（~50-64pt），
//        多出来的高度落到状态行下面（与参考截屏一致）。
//        标签行原来是 `ScrollView` 里的 `HStack`，天然靠左；现在给内容一个 `minWidth` 把它居中。
//   ④ 双击封面只弹一个"小框歌词" → 歌词改成**整页层**：去掉卡片底/描边/左右边距，
//      直接铺满顶栏下方到进度条之间（歌词模式下连功能键行与状态行都收起来）。
//   ⑤ 滑歌词后"还没来得及点就弹回当前行" → `LyricsPane` 记一次滑动/点击的时间，
//      停够 `LyricsUXRules.dwellSeconds`（4 秒）才回当前行；期间底部给一个「回到当前」。
//   ⑥ 没点歌词也算点了、判定范围太宽 → 命中区只认**字本身**（不再整行铺满），
//      并且滑动结束后 0.35 秒内的触摸只当"刹车"，不跳歌。
//   ⑦ 在歌词页上下滑会被当成"下拽收起播放页" → 整页下拽手势只在**封面模式**挂上。
//
// 版式（封面模式）：顶栏 → 居中大封面 → 歌名/歌手/音质标签 → 有上限留白 →
//   四个功能键 → 进度条+两端时间 → 五个播放键 → 底部状态行。
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
        page
            .offset(y: max(0, sheetOffset))
            .opacity(sheetOffset > 0 ? Double(max(0.35, 1 - sheetOffset / 700)) : 1)
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
            // 切歌时只清掉拖动中的进度；歌词模式**保留**——
            // 列表循环自动播下一首时，老板正看着歌词，不该被弹回封面。
            .onChange(of: player.currentSong?.id) { _, _ in
                dragFraction = nil
            }
    }

    /// 歌词模式下**不挂**整页下拽手势（老板反馈 ⑦：在歌词页上下滑只是想快进/后退，
    /// 结果播放页被收起来了）。收起播放页仍然有左上角 chevron。
    @ViewBuilder
    private var page: some View {
        if showLyrics {
            canvas
        } else {
            canvas.simultaneousGesture(dismissDrag)
        }
    }

    private var canvas: some View {
        ZStack {
            backdrop.ignoresSafeArea()

            GeometryReader { geo in
                // 先把宽度钉到屏幕上（外层给多宽都不认），后面每一行都按这个 w 排
                let w = CGFloat(LayoutRules.playerWidth(available: Double(geo.size.width),
                                                        screen: Self.screenWidth))
                playerBody(width: w, height: geo.size.height)
                    // 关键：整块内容先钉到 w 宽，再居中。外层就算给到 1200pt 也穿不出去。
                    .frame(width: w)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func playerBody(width w: CGFloat, height h: CGFloat) -> some View {
        // r63「封面撑满型」：整列**铺满屏高**，富余高度由等权 Spacer 均分。
        // 上一版是"顶端对齐 + 一段有上限的留白"，富余高度全堆在播放键下面（老板：进度条下方一大段空的）。
        let gap = CGFloat(LayoutRules.playerGap(availableHeight: Double(h)))
        let coverSide = CGFloat(LayoutRules.playerCoverSide(width: Double(w), height: Double(h)))

        return VStack(spacing: 0) {
            topBar(width: w)

            if showLyrics {
                // 全屏歌词：顶栏下面一路铺到进度条，中间不再有卡片、不再有功能键行
                lyricsStage(width: w)
                    .frame(maxHeight: .infinity)

                progressRow(width: w)
                    .padding(.top, Tokens.Spacing.xs)

                transportRow(width: w)
                    .padding(.top, Tokens.Spacing.xxs)
                    .padding(.bottom, Tokens.Spacing.xs)
            } else {
                Spacer(minLength: gap)
                coverStage(width: w, side: coverSide)
                Spacer(minLength: gap)
                titleStage(width: w)
                Spacer(minLength: gap)
                quickRow(width: w)
                Spacer(minLength: gap)
                progressRow(width: w)
                transportRow(width: w)
                    .padding(.top, Tokens.Spacing.xs)

                // 状态行只在出错时出现（老板 r63：暂停键下面那行小字不要了，
                // 但"无源/换源失败"必须让人看见，否则点歌没反应像卡死）
                if let error = player.errorText {
                    errorLine(width: w)
                        .padding(.top, Tokens.Spacing.xs)
                }

                Spacer(minLength: gap)
            }
        }
        .frame(width: w, height: h, alignment: .top)
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

    /// 已下载的歌优先用下载时一起存的本地封面（老板反馈 ⑧：无网络也要有图）。
    /// `AsyncImage` 不能读 file://，本地图直接走 `UIImage(contentsOfFile:)`。
    private var localCoverImage: UIImage? {
        guard let song = player.currentSong,
              let url = DownloadManager.shared.localCoverURL(for: song) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var remoteCoverURL: URL? {
        guard let raw = player.currentSong?.picURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            if let local = localCoverImage {
                Image(uiImage: local)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 46)
                    .opacity(0.85)
            } else if let url = remoteCoverURL {
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
        // 标题绝对居中（ZStack），左右各是按钮——加一个「封面」返回键时标题也不会被挤歪
        ZStack {
            Text(showLyrics ? "歌词" : "正在播放")
                .font(.footnote.weight(.medium))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)

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

                // 歌词页收起了功能键行，这里必须有「回封面」的出口（不然只能关掉整个播放页）
                if showLyrics {
                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.26)) { showLyrics = false }
                    } label: {
                        Text("封面")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: Tokens.Spacing.minTapTarget, height: Tokens.Spacing.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("回到封面")
                }

                moreMenu
                    .frame(width: Tokens.Spacing.minTapTarget, height: Tokens.Spacing.minTapTarget)
            }
        }
        .frame(width: width)
        .frame(minHeight: Tokens.Spacing.minTapTarget)
        .padding(.top, Tokens.Spacing.xxs)
    }

    private var moreMenu: some View {
        Menu {
            if showLyrics {
                Button {
                    withAnimation(.easeInOut(duration: 0.26)) { showLyrics = false }
                } label: {
                    Label("回到封面", systemImage: "rectangle.portrait")
                }
                Divider()
            }
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

    private func coverStage(width: CGFloat, side: CGFloat) -> some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Group {
                if let local = localCoverImage {
                    Image(uiImage: local).resizable().scaledToFill()
                } else if let url = remoteCoverURL {
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
            .accessibilityHint("双击看全屏歌词")
            .accessibilityAction {
                withAnimation(.easeInOut(duration: 0.26)) { showLyrics = true }
            }

            Text("双击封面看歌词")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(width: width)
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

    // MARK: 歌名 / 歌手 / 音质标签（居中）

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
    ///
    /// 老板反馈 ①"文字下的标签也没有居中"：这一排原来放在横向 `ScrollView` 里，
    /// 内容天然靠左。现在给内容一个 `minWidth = 行宽`——装得下时被 `frame` 居中，
    /// 装不下时（小屏 + 5 个胶囊）Spacer 收成 0，仍然可以横向滑。
    private func chipsRow(width: CGFloat) -> some View {
        let contentWidth = max(80, width - Tokens.Spacing.xl * 2)
        return ScrollView(.horizontal, showsIndicators: false) {
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
            .frame(minWidth: contentWidth)
            .frame(minHeight: 24)
        }
        .frame(width: contentWidth)
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

    // MARK: 底部错误行（r63：正常状态整行不显示）

    /// 老板 r63："暂停键下方的小字不用再显示了，毕竟已经在音源里了。"
    /// 但"解析失败/无源/换源"这类错误必须让人看见——所以这行现在只在 `player.errorText` 有值时出现，
    /// 高度也不预留（正常状态下一点空隙都不占）。
    private func errorLine(width: CGFloat) -> some View {
        HStack(spacing: Tokens.Spacing.xxs + 2) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
            Text(player.errorText ?? "")
                .font(.caption2)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.orange)
        .frame(width: max(80, width - Tokens.Spacing.l * 2))
        .accessibilityElement(children: .combine)
    }

    // MARK: 全屏歌词

    private func lyricsStage(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            lyricsHeader(width: width)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { backToCover() }

            offsetRow(width: width)
                .padding(.top, Tokens.Spacing.xxs)

            if player.lyrics.isEmpty {
                lyricsEmpty(width: width)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { backToCover() }
            } else {
                LyricsPane(width: width)
                    .padding(.top, Tokens.Spacing.xs)
            }
        }
        .frame(width: width)
        .padding(.top, Tokens.Spacing.xxs)
    }

    /// 歌词页 → 封面（双击空白处、点右上角「封面」、⋯ 菜单都走这里）
    private func backToCover() {
        Haptics.tap()
        withAnimation(.easeInOut(duration: 0.26)) { showLyrics = false }
    }

    /// 歌词页顶部的歌名 / 行数来源 / 当前偏移（一行放完，不吃歌词的高度）
    private func lyricsHeader(width: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
            Text(player.currentSong?.name ?? "歌词")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(lyricsMeta)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)

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
                .frame(maxWidth: .infinity, minHeight: 30)
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

    /// 歌词空状态（r63：**去掉那个圆角卡片**——老板说"不要显示一个框，很丑，直接把边缘去掉"）；
    /// 顺便把失败原因写清楚，下一轮一眼能看出是哪条链断了。
    private func lyricsEmpty(width: CGFloat) -> some View {
        VStack(spacing: Tokens.Spacing.xs) {
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
                if !player.lyricsFailure.isEmpty {
                    Text(player.lyricsFailure)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Tokens.Spacing.l)
                }
                Button("重试") { player.reloadLyrics() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.press)
            }
        }
        .frame(width: max(80, width - Tokens.Spacing.m * 2))
        .frame(maxHeight: .infinity)
    }

    // MARK: 工具

    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 歌词面板（全屏 + 浏览手感）

/// 老板反馈 ④⑤⑥：双击封面后是**整页歌词**，不是一个小框。
///
/// 手感规则（全部来自 `LyricsUXRules`，CI 有断言）：
///   · 用户滑动歌词 → `browsing = true`，此时**不再**跟着唱到哪滚到哪；
///   · 停手 4 秒没有新操作 → 自动回到当前行；期间底部有「回到当前」可以立刻回去；
///   · 点某一句 → 跳到那句；但滑动刚结束的 0.35 秒内触摸只当"刹车"，不跳歌；
///   · 命中区只认字本身（不是整行），手指扫过空白不会再误跳。
private struct LyricsPane: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let width: CGFloat

    /// 用户正停在自己滑到的位置（true 时不再自动跟随）
    @State private var browsing = false
    /// 最后一次滑动 / 点击的时刻（停留计时的起点）
    @State private var lastInteraction = Date.distantPast
    /// 最后一次滑动结束的时刻（"刹车触摸"冷却用）
    @State private var lastScrollEnd = Date.distantPast
    /// 停留计时任务
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                scrollView(proxy: proxy)

                if browsing {
                    returnButton(proxy: proxy)
                        .padding(.bottom, Tokens.Spacing.s)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: browsing)
        }
        .onDisappear {
            resumeTask?.cancel()
            resumeTask = nil
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            browsing = false
            lastInteraction = Date.distantPast
            lastScrollEnd = Date.distantPast
            resumeTask?.cancel()
            resumeTask = nil
        }
    }

    // MARK: 歌词滚动区

    private func scrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: Tokens.Spacing.m) {
                ForEach(Array(player.lyrics.enumerated()), id: \.offset) { index, line in
                    LyricLineRow(index: index,
                                 line: line,
                                 isCurrent: index == player.lyricIndex,
                                 onTap: { tapLine(index) })
                        .id(index)
                }
            }
            .frame(width: max(80, width - Tokens.Spacing.l * 2))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 160)
        }
        .frame(width: width)
        .mask(lyricsFade)
        .simultaneousGesture(browseGesture(proxy: proxy))
        .onChange(of: player.lyricIndex) { _, idx in
            guard idx >= 0, !browsing else { return }
            scroll(proxy: proxy, to: idx, animated: true)
        }
        .onAppear {
            guard player.lyricIndex >= 0 else { return }
            // 首帧行还没布局完，等一拍再滚
            DispatchQueue.main.async {
                proxy.scrollTo(player.lyricIndex, anchor: .center)
            }
        }
    }

    /// 上下淡出（用渐变 stop，而不是两条固定高度的渐变条——AX5 下也不会截断文字）
    private var lyricsFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.10),
                .init(color: .black, location: 0.90),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: 手势

    /// 用户滑歌词：记一次交互并暂停自动跟随；松手后开始停留计时
    private func browseGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { _ in
                lastInteraction = Date()
                if !browsing { browsing = true }
                resumeTask?.cancel()
                resumeTask = nil
            }
            .onEnded { _ in
                lastInteraction = Date()
                lastScrollEnd = Date()
                scheduleResume(proxy: proxy)
            }
    }

    /// 停 `dwellSeconds` 秒没有新操作就回当前行；期间又动过就再等一轮
    private func scheduleResume(proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(LyricsUXRules.dwellSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let idle = Date().timeIntervalSince(lastInteraction)
            guard LyricsUXRules.shouldResumeFollowing(secondsSinceInteraction: idle) else {
                scheduleResume(proxy: proxy)
                return
            }
            browsing = false
            if player.lyricIndex >= 0 {
                scroll(proxy: proxy, to: player.lyricIndex, animated: true)
            }
        }
    }

    /// 点某一句 → 跳过去
    private func tapLine(_ index: Int) {
        // 滑动刚结束的那一下是"刹车"，不是点击（老板反馈 ⑥：没点歌词也算点了）
        let sinceScroll = Date().timeIntervalSince(lastScrollEnd)
        guard !LyricsUXRules.isTapCoolingDown(secondsSinceScrollEnd: sinceScroll) else { return }
        guard player.duration > 0 else { return }
        Haptics.lyricSeek()
        resumeTask?.cancel()
        resumeTask = nil
        browsing = false
        lastInteraction = Date()
        lastScrollEnd = Date.distantPast
        player.seek(toLyricLine: index)
    }

    private func returnButton(proxy: ScrollViewProxy) -> some View {
        Button {
            Haptics.tap()
            resumeTask?.cancel()
            resumeTask = nil
            browsing = false
            if player.lyricIndex >= 0 {
                scroll(proxy: proxy, to: player.lyricIndex, animated: true)
            }
        } label: {
            Label("回到当前", systemImage: "arrow.down.to.line.compact")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.vertical, Tokens.Spacing.xxs + 2)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.press)
        .accessibilityLabel("回到正在唱的一句")
    }

    private func scroll(proxy: ScrollViewProxy, to index: Int, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(Tokens.Motion.lyricAdvance) {
                proxy.scrollTo(index, anchor: .center)
            }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}

// MARK: - 一行歌词

/// 命中区只落在**文字本身**上：以前整行 `.contentShape(Rectangle())` + `frame(maxWidth:)`，
/// 手指从空白处扫过也算点击（老板反馈 ⑥）。现在文字两侧用 Spacer 撑开，点击范围就是字的包围盒。
private struct LyricLineRow: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(SettingsStore.self) private var settings

    let index: Int
    let line: LyricLine
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            textContent
                .multilineTextAlignment(.center)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.text)
                .accessibilityValue(isCurrent ? "第 \(index + 1) 行，共 \(player.lyrics.count) 行" : "")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("跳到这一句")
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Spacing.xxs)
    }

    @ViewBuilder
    private var textContent: some View {
        if isCurrent {
            if settings.lyricAnimation {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { _ in
                    Text(currentLineString())
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

    private var currentLineFont: Font {
        switch settings.lyricFontScale {
        case .system: return FontRole.lyricCurrent
        case .large: return .title.weight(.bold)
        case .extraLarge: return .largeTitle.weight(.bold)
        }
    }

    /// 当前行的富文本：逐字推进用 `lyricPositionMs`（已含用户偏移），与切行判定同源。
    private func currentLineString() -> AttributedString {
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
            piece.foregroundColor = mixColor(unsung, .white, progress)
            result.append(piece)
        }
        return result
    }
}

/// 两个颜色按进度混合（逐字染色用）
private func mixColor(_ from: Color, _ to: Color, _ t: Double) -> Color {
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
