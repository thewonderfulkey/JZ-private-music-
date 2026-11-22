import SwiftUI

// MARK: - 识曲（设计稿 §3.8）
//
// 三条链路叠在一起：
//   麦克风（AudioCapture，8k 单声道 16bit）
//     → 酷狗指纹通道（KugouRecognizer，先 6 秒偷一次跑，没对上再录满）
//     → 统一打分（RecognizeScore：原唱标记 / 裸名 / 专辑 / 时长 / 位次）
//     → 结果卡 + 「其他版本」（走现有跨平台搜索，播放也走它）
//
// 网易通道（afp wasm）留到下一轮：它要 12 秒窗口 + WKWebView 跑 wasm，
// 和这一轮的采集/打分/页面解耦，不影响先上酷狗这一路。
struct RecognizeView: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    enum Phase: Equatable {
        case idle
        case listening
        case recognizing
        case result
        case noMatch
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var remaining = 12
    @State private var level: Float = 0

    @State private var recognized: RecognizeCandidate?
    @State private var resolved: Song?
    @State private var versions: [Song] = []
    /// 「其他版本」里唯一一条该打「原唱」的 id；nil = 这一组没有可标的原唱
    @State private var originalVersionID: String?
    @State private var isResolvingVersions = false

    @State private var task: Task<Void, Never>?
    @State private var capture = AudioCapture()
    /// 单通道失败的原因（两条都空时用它决定文案，避免把网络问题说成"没听出来"）
    @State private var channelError: String?

    /// 先问一次酷狗的时长（与 Android `EARLY_SECONDS` 一致）
    private let earlySeconds = 6

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.l) {
                // 第三十二轮：舞台从"整页渐变的一颗圈"换成 RecognizeStage（声波/频谱/倒计时/雷达）。
                RecognizeStage(phase: phase,
                               level: level,
                               remaining: remaining,
                               totalSeconds: settings.recognizeSeconds,
                               onTap: handleMicTap)
                phaseText
                resultSlot
                recentSection
                // 迷你条是浮层：末尾让出高度（第五轮反馈 ⑨）
                MiniPlayerSpacer()
            }
            .padding(.top, Tokens.Spacing.m)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        // 网易指纹引擎（WKWebView 跑 wasm）必须挂在视图层级里才保证执行 JS
        .background(
            FingerprintHostView()
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach([12, 15, 20], id: \.self) { seconds in
                        Button {
                            settings.recognizeSeconds = seconds
                        } label: {
                            if settings.recognizeSeconds == seconds {
                                Label("听 \(seconds) 秒", systemImage: "checkmark")
                            } else {
                                Text("听 \(seconds) 秒")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("听 \(settings.recognizeSeconds) 秒")
                            .font(.footnote)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .disabled(phase == .listening || phase == .recognizing)
            }
        }
        .onDisappear { cancelListen() }
        // 第三十二轮：五个 Tab 改成常驻保活（切走不再触发 onDisappear），
        // 所以"切走就停录"要显式盯 router.tab，否则麦克风会在后台一直录。
        .onChange(of: router.tab) { _, newTab in
            guard newTab != .recognize else { return }
            if phase == .listening || phase == .recognizing {
                cancelListen()
            }
        }
        // 同理：全屏播放页盖上来时也别继续录（常驻 Tab 不会触发 onDisappear）
        .onChange(of: router.showPlayer) { _, showing in
            guard showing else { return }
            if phase == .listening || phase == .recognizing {
                cancelListen()
            }
        }
        // App Intent（「听歌识曲」快捷指令）进来时自动开始听
        .onChange(of: router.pendingRecognize) { _, value in
            guard value else { return }
            router.pendingRecognize = false
            if phase != .listening, phase != .recognizing { startListen() }
        }
        .task {
            if router.pendingRecognize {
                router.pendingRecognize = false
                startListen()
            }
        }
    }

    // MARK: 阶段文案
    //
    // 第三十二轮：文案不再跟着整页一起 0.6s 渐变。每个阶段是一条独立短句，
    // 插入时 6pt 上浮 + 淡入（0.18s），移出只淡出；舞台、按钮、结果卡各走各的动画。

    @ViewBuilder
    private var phaseText: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            switch phase {
            case .idle:
                phaseMessage(title: "点一下麦克风，开始听",
                             detail: "把手机靠近正在外放的音箱")
            case .listening:
                phaseMessage(title: "正在聆听…",
                             detail: "还能听 \(remaining) 秒 · 再点一下可取消")
            case .recognizing:
                phaseMessage(title: "正在辨认…", detail: "比对曲库中")
            case .result:
                phaseMessage(title: "听出来了", detail: nil)
            case .noMatch:
                retryMessage(title: "这次没听出来",
                             detail: "靠近一点、音量别太小，或者换个安静点的地方再试",
                             actionTitle: "再听一次")
            case .failed(let message):
                retryMessage(title: "识别没成功",
                             detail: message,
                             actionTitle: "再试一次")
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Tokens.Motion.textSwap, value: phase)
    }

    private func phaseMessage(title: String, detail: String?) -> some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            Text(title)
                .font(.title3)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.l)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .opacity))
    }

    private func retryMessage(title: String, detail: String, actionTitle: String) -> some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            Text(title)
                .font(.title3)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Spacing.l)
            Button(actionTitle) { handleMicTap() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.press)
                .padding(.top, Tokens.Spacing.xs)
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .opacity))
    }

    // MARK: 结果
    //
    // 结果卡单独占一个"插槽"：只有它的插入/移出走 resultIn（从下方 12pt 顶上来），
    // 舞台与文案不受这条 spring 影响。

    @ViewBuilder
    private var resultSlot: some View {
        Group {
            if phase == .result {
                resultSection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Tokens.Motion.resultIn, value: phase)
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(spacing: Tokens.Spacing.m) {
            if let recognized {
                VStack(spacing: Tokens.Spacing.xs) {
                    HStack(spacing: Tokens.Spacing.s) {
                        if let resolved {
                            SongArtwork(song: resolved, size: 64, radius: Tokens.Radius.artworkSmall)
                        } else {
                            RoundedRectangle(cornerRadius: Tokens.Radius.artworkSmall, style: .continuous)
                                .fill(Tokens.Palette.paperElevated)
                                .frame(width: 64, height: 64)
                                .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(recognized.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                    .layoutPriority(1)
                                if mainIsOriginal {
                                    Text("原唱")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Tokens.Palette.vermilion)
                                        .fixedSize()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .overlay(Capsule().strokeBorder(Tokens.Palette.vermilion.opacity(0.5),
                                                                        lineWidth: 0.5))
                                        .transition(.opacity)
                                }
                            }
                            .animation(Tokens.Motion.stateChange, value: mainIsOriginal)
                            Text(recognized.artist.isEmpty ? "未知歌手" : recognized.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !recognized.album.isEmpty {
                                Text(recognized.album)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: Tokens.Spacing.xs)

                        if isResolvingVersions {
                            ProgressView().controlSize(.small)
                        } else if let resolved {
                            Button {
                                play(resolved)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Tokens.Palette.vermilion)
                            }
                            .buttonStyle(.press)
                            .accessibilityLabel("播放这首歌")
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)

                    HStack(spacing: 4) {
                        Text(scoreNote)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)
                }
                .accessibilityElement(children: .combine)
            }

            if !versions.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("其他版本")
                            .font(FontRole.sectionTitle)
                        Spacer()
                        Text("\(versions.count) 个")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Tokens.Spacing.pageMargin)

                    VStack(spacing: 0) {
                        ForEach(versions) { song in
                            Button {
                                play(song)
                            } label: {
                                versionRow(song)
                            }
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            .buttonStyle(.rowPress)
                        }
                    }
                }
            }
        }
    }

    private var scoreNote: String {
        guard let recognized else { return "" }
        var parts: [String] = []
        parts.append("识别依据：\(channelName(recognized.source))")
        if recognized.isOriginal == 1 { parts.append("通道标为原唱") }
        if recognized.isOriginal == 2 { parts.append("通道标为翻唱/他人版本") }
        if recognized.isOriginal == 4 { parts.append("原唱但非该录音室版本") }
        if recognized.durationSec > 0 { parts.append("时长 \(recognized.durationSec)s") }
        return parts.joined(separator: " · ")
    }

    /// 主结果这条录音是不是原唱（同一首歌 + 裸名 + 歌手匹配 + 时长对得上）
    private var mainIsOriginal: Bool {
        guard let recognized, let resolved else { return false }
        return StudioPick.isOriginalRecording(resolved,
                                              title: recognized.title,
                                              artist: recognized.artist,
                                              durationSec: recognized.durationSec)
    }

    private func channelName(_ source: String) -> String {
        switch source {
        case RecognizeScore.sourceKugou: return "酷狗"
        case RecognizeScore.sourceNetease: return "网易"
        default: return "指纹通道"
        }
    }

    /// 版本行：「原唱」只给**唯一一条**与识别时长对得上的裸名同歌手版本。
    /// 第三十三轮：旧规则只看这一行自己的歌名/歌手，没校验「是不是同一首歌」，
    /// 结果同歌手的其他歌全被打成原唱（真机截图六条全中）。
    private func versionRow(_ song: Song) -> some View {
        let isOriginal = song.id == originalVersionID
        return HStack(spacing: Tokens.Spacing.s) {
            SongArtwork(song: song, size: 44, radius: Tokens.Radius.artworkSmall)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.name)
                    .font(FontRole.songTitle)
                    .lineLimit(1)
                Text(song.album.isEmpty ? song.singer : "\(song.singer) · \(song.album)")
                    .font(FontRole.songSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.Spacing.xs)
            if isOriginal {
                Text("原唱")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(Tokens.Palette.vermilion.opacity(0.5), lineWidth: 0.5))
            }
            Text(song.durationText)
                .font(FontRole.metadata)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: Tokens.Size.songRowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.name)，\(song.singer)\(isOriginal ? "，原唱" : "")")
    }

    /// 所有"点一行就播"的地方走这一个口（其他版本 / 最近识过）。
    /// 第三十三轮：点歌不再给触觉——老板要的是 Light Player 那种高亮，不是震动。
    private func play(_ song: Song) {
        // 第三十九轮：让行高亮先铺满，再起播/弹悬浮栏/开播放页
        RowTap.afterHighlight {
            player.playSingle(song)
            library.recordPlayed(song)
            router.showPlayer = true
        }
    }

    // MARK: 最近识过

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(title: "最近识过")
            if library.recognizeHistory.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("第一次用？")
                        .font(.footnote.weight(.semibold))
                    ForEach(["外放不用开到最大，正常音量就够",
                             "一米内，别用手挡住麦克风",
                             "环境太吵就换个地方"], id: \.self) { tip in
                        Text("· \(tip)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Tokens.Spacing.pageMargin)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.recognizeHistory.prefix(10)) { song in
                        // r79（老板："识曲的历史现在无法点击播放"）：以前这里只是一行 `SongRow`，
                        // 没有任何手势——点上去什么都不发生。现在整行可点，行为与「其他版本」
                        // 那一段完全一致：起播这首 + 记一次播放 + 打开播放页。
                        Button {
                            play(song)
                        } label: {
                            SongRow(song: song)
                        }
                        .padding(.horizontal, Tokens.Spacing.pageMargin)
                        .buttonStyle(.rowPress)
                        .accessibilityHint("轻点播放这首歌")
                    }
                }
            }
        }
    }

    // MARK: 状态机

    private func handleMicTap() {
        switch phase {
        case .listening, .recognizing:
            cancelListen()
        case .idle, .noMatch, .failed, .result:
            startListen()
        }
    }

    private func startListen() {
        task?.cancel()
        recognized = nil
        resolved = nil
        versions = []
        originalVersionID = nil
        remaining = settings.recognizeSeconds
        task = Task { await listen() }
    }

    private func cancelListen() {
        task?.cancel()
        task = nil
        // 只在**真的在录**的时候收尾。
        // 以前这里无条件 `capture.cancel()` → `AudioCapture.stop()` → `restorePlaybackSession()`
        // 会 setActive(false) 一次再重开，等于把正在放歌的音频会话掐断（表现为"切个 Tab 歌就停了"）。
        if capture.isRunning { capture.cancel() }
        phase = .idle
        remaining = settings.recognizeSeconds
        level = 0
    }

    private func listen() async {
        // 权限：被拒时给一句能执行的话，不弹系统说明
        let granted = await capture.requestPermission()
        guard granted else {
            phase = .failed("没有麦克风权限。到「设置 → JZ 音乐 → 麦克风」里打开再试。")
            return
        }
        if Task.isCancelled { return }

        // 识曲前一定先暂停自己的播放（否则麦克风收的是自己放的歌）。
        // 第四十轮：这条不再是设置项——不暂停就根本识别不了，没得选。
        if player.isPlaying {
            player.toggle()
        }

        capture.onLevel = { value in
            // RMS 原始值很小（外放音乐大约 0.02…0.2），直接画频谱几乎不动。
            // 先放大 5.5 倍再夹到 0…1，并做一次低通（新值 45%），条子才不会一格一格跳。
            let boosted = Float(min(max(Double(value) * 5.5, 0), 1))
            level = level * 0.55 + boosted * 0.45
        }
        do {
            try capture.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .listening
        remaining = settings.recognizeSeconds

        var tick = 0
        var earlyTried = false
        while tick < settings.recognizeSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            tick += 1
            remaining = max(0, settings.recognizeSeconds - tick)

            // 6 秒先问一次：命中就提前收工，常见情况 6~7 秒出结果
            if !earlyTried, tick >= earlySeconds {
                earlyTried = true
                let snapshot = capture.snapshot()
                if await earlyHit(pcm: snapshot.pcm) {
                    capture.stop()
                    return
                }
            }
        }

        let final = capture.stop()
        phase = .recognizing

        if final.pcm.count < 8_000 * 2 {
            phase = .failed("麦克风没采到声音（可能是被别的 App 占着），再试一次。")
            return
        }
        if final.peak < 0.008 {
            phase = .failed("几乎没听到声音。把手机靠近音箱、音量开大一点再试。")
            return
        }
        await recognizeChannels(pcm: final.pcm)
    }

    /// 提前收工：只要酷狗这条通道有命中就先用它（网易要 12 秒窗口，这时候还没采够）
    private func earlyHit(pcm: Data) async -> Bool {
        guard pcm.count >= 8_000 * 2 else { return false }
        guard let hits = try? await KugouRecognizer.recognize(pcm: pcm), !hits.isEmpty else { return false }
        guard let result = RecognizeScore.fuse(kugou: hits, netease: []),
              let top = result.ranked.first else { return false }
        recognized = top.rep
        phase = .result
        // 触觉统一由 RecognizeStage 在 phase 变化时给（这里再给一次会成功两下）
        await resolveVersions(top.rep)
        return true
    }

    /// 双通道并发：酷狗（PCM）+ 网易（afp 指纹），结果统一交给 RecognizeScore 打分
    private func recognizeChannels(pcm: Data) async {
        async let kugou = kugouHits(pcm: pcm)
        async let netease = neteaseHits(pcm: pcm)
        let (kg, ne) = await (kugou, netease)

        guard let result = RecognizeScore.fuse(kugou: kg, netease: ne),
              let top = result.ranked.first else {
            if let channelError {
                phase = .failed(channelError)
            } else {
                phase = .noMatch
            }
            return
        }
        recognized = top.rep
        phase = .result
        await resolveVersions(top.rep)
    }

    private func kugouHits(pcm: Data) async -> [RecognizeCandidate] {
        do {
            return try await KugouRecognizer.recognize(pcm: pcm)
        } catch {
            channelError = "酷狗通道：\(error.localizedDescription)"
            return []
        }
    }

    private func neteaseHits(pcm: Data) async -> [RecognizeCandidate] {
        // 网易指纹要 12 秒窗口，喂 8 秒会直接 noMatchReason=10
        guard pcm.count >= 8_000 * 2 * 11 else { return [] }
        guard await NeteaseFingerprint.shared.waitReady() else { return [] }
        guard let fingerprint = await NeteaseFingerprint.shared.encode(pcm16: pcm) else {
            channelError = "网易通道：指纹生成失败"
            return []
        }
        do {
            return try await NeteaseRecognizer.recognize(fingerprint: fingerprint)
        } catch {
            channelError = "网易通道：\(error.localizedDescription)"
            return []
        }
    }

    /// 拿到真实 Song + 「其他版本」：仍走现有跨平台搜索，播放也用它
    private func resolveVersions(_ candidate: RecognizeCandidate) async {
        isResolvingVersions = true
        let keyword = "\(candidate.title) \(candidate.artist)".trimmingCharacters(in: .whitespaces)
        let ranked = await SearchService.shared.searchRanked(keyword: keyword, limit: 20)
        let songs = ranked.songs

        let studio = songs.first {
            NameMatch.titleMatches(candidate.title, $0.name)
                && NameMatch.singerMatches(candidate.artist, $0.singer)
                && StudioPick.isCleanTitle($0.name)
        }
        // 2026-11-22：主结果**必须**歌名对得上。
        //   允许：归一化歌名一致（`下一个天亮` vs `下一个天亮 (Live)`，括号会被剥掉）；
        //        或「歌名像 + 歌手对得上」（多歌手串/副标题差异）。
        // 以前这里是 `titleMatches` 单条，且末尾还有 `?? songs.first` 兜底——
        // 那一档**完全不校验身份**，《下一个天亮》这种"歌名被频道号/翻唱占满"的搜索页，
        // 第一条常常是别的歌，识曲结果就"跳"了。
        let titleOnly = songs.first {
            NameMatch.normTitle(candidate.title) == NameMatch.normTitle($0.name)
                || (NameMatch.titleMatches(candidate.title, $0.name)
                    && NameMatch.singerMatches(candidate.artist, $0.singer))
        }
        resolved = studio ?? titleOnly

        if let resolved {
            library.recordRecognized(resolved)
        }

        // 同名不同版本最多 6 条：
        //   ① 先按核心歌名严格过滤（繁简折叠），把同歌手的**别的歌**挡在外面；
        //   ② 跨平台同一条录音去重，并剔掉主结果那条（含它在别的平台的副本）；
        //   ③ 最多只挑一条原唱（时长对得上）；原唱优先、同歌手优先、裸名优先。
        let sameSong = StudioPick.sameSongVersions(songs, matching: candidate.title)
        let distinct = StudioPick.dedupeRecordings(sameSong)
        let others = StudioPick.excludingRecording(of: resolved, from: distinct)
        let original = StudioPick.originalVersion(in: others,
                                                 title: candidate.title,
                                                 artist: candidate.artist,
                                                 durationSec: candidate.durationSec)
        originalVersionID = original?.id

        versions = others
            .sorted { a, b in
                let oa = a.id == original?.id
                let ob = b.id == original?.id
                if oa != ob { return oa && !ob }
                let sa = NameMatch.singerMatches(candidate.artist, a.singer)
                let sb = NameMatch.singerMatches(candidate.artist, b.singer)
                if sa != sb { return sa && !sb }
                let ca = StudioPick.isCleanTitle(a.name)
                let cb = StudioPick.isCleanTitle(b.name)
                if ca != cb { return ca && !cb }
                return a.duration < b.duration
            }
            .prefix(6)
            .map { $0 }
        isResolvingVersions = false
    }
}

// MARK: - 指纹引擎宿主（1×1）

private struct FingerprintHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.isUserInteractionEnabled = false
        let web = NeteaseFingerprint.shared.hostWebView()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

