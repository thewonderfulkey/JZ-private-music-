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
    @State private var pulse = false
    @State private var level: Float = 0

    @State private var recognized: RecognizeCandidate?
    @State private var resolved: Song?
    @State private var versions: [Song] = []
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
                stage
                phaseText
                if phase == .result {
                    resultSection
                }
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

    // MARK: 麦克风舞台

    private var stage: some View {
        ZStack {
            Circle()
                .fill(Tokens.Palette.vermilion.opacity(0.06))
                .frame(width: 210, height: 210)
                .scaleEffect(pulseScale)
                .opacity(phase == .listening ? 1 : 0.5)
            Circle()
                .fill(Tokens.Palette.vermilion.opacity(0.10))
                .frame(width: 176, height: 176)
            Circle()
                .fill(Tokens.Palette.paperElevated)
                .frame(width: 146, height: 146)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            Image(systemName: phase == .listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(phase == .listening ? Tokens.Palette.vermilion : Color.primary)
        }
        .frame(height: 220)
        .contentShape(Rectangle())
        .onTapGesture(perform: handleMicTap)
        .accessibilityElement()
        .accessibilityLabel(phase == .listening ? "停止聆听" : "开始识曲")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { handleMicTap() }
        .animation(.easeInOut(duration: 0.6), value: phase)
        .onChange(of: phase) { _, newValue in
            if newValue == .listening {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    /// 呼吸圈 + 实时电平：安静时也有轻微起伏，不至于像卡死
    private var pulseScale: CGFloat {
        guard phase == .listening else { return 1.0 }
        let base: CGFloat = pulse ? 1.06 : 0.98
        return base + CGFloat(min(max(level, 0), 1)) * 0.18
    }

    // MARK: 阶段文案

    @ViewBuilder
    private var phaseText: some View {
        VStack(spacing: Tokens.Spacing.xxs) {
            switch phase {
            case .idle:
                Text("点一下麦克风，开始听")
                    .font(.title3)
                Text("把手机靠近正在外放的音箱")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .listening:
                Text("正在聆听…")
                    .font(.title3)
                Text("还能听 \(remaining) 秒 · 再点一下可取消")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .recognizing:
                Text("正在辨认…")
                    .font(.title3)
                Text("比对曲库中")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .result:
                Text("听出来了")
                    .font(.title3)
            case .noMatch:
                Text("这次没听出来")
                    .font(.title3)
                Text("靠近一点、音量别太小，或者换个安静点的地方再试")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.l)
                Button("再听一次") { handleMicTap() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Tokens.Spacing.xs)
            case .failed(let message):
                Text("识别没成功")
                    .font(.title3)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Tokens.Spacing.l)
                Button("再试一次") { handleMicTap() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Tokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 结果

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
                            Text(recognized.title)
                                .font(.headline)
                                .lineLimit(2)
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
                                player.playSingle(resolved)
                                library.recordPlayed(resolved)
                                Haptics.playbackToggle()
                                router.showPlayer = true
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
                                player.playSingle(song)
                                library.recordPlayed(song)
                                Haptics.playbackToggle()
                                router.showPlayer = true
                            } label: {
                                versionRow(song)
                            }
                            .buttonStyle(.press)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
                            Divider().padding(.leading, Tokens.Spacing.pageMargin + 48 + Tokens.Spacing.s)
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

    private func channelName(_ source: String) -> String {
        switch source {
        case RecognizeScore.sourceKugou: return "酷狗"
        case RecognizeScore.sourceNetease: return "网易"
        default: return "指纹通道"
        }
    }

    /// 版本行：原唱标记只在"裸名 + 同歌手"时给，避免把所有翻唱都盖上原唱印
    private func versionRow(_ song: Song) -> some View {
        let isStudio = StudioPick.isCleanTitle(song.name)
            && (recognized.map { NameMatch.singerMatches($0.artist, song.singer) } ?? false)
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
            if isStudio {
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
        .accessibilityLabel("\(song.name)，\(song.singer)\(isStudio ? "，原唱" : "")")
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
                        SongRow(song: song)
                            .padding(.horizontal, Tokens.Spacing.pageMargin)
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

        // 识曲前先暂停自己的播放（否则麦克风收的是自己放的歌）
        if settings.pauseBeforeRecognize, player.isPlaying {
            player.toggle()
        }

        capture.onLevel = { value in level = value }
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
        Haptics.success()
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
        Haptics.success()
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
        let titleOnly = songs.first { NameMatch.titleMatches(candidate.title, $0.name) }
        resolved = studio ?? titleOnly ?? songs.first

        if let resolved {
            library.recordRecognized(resolved)
        }

        // 同名不同版本最多 6 条，按"原唱优先"排
        versions = StudioPick.dedupeByCore(songs)
            .sorted { a, b in
                let sa = StudioPick.isCleanTitle(a.name) && NameMatch.singerMatches(candidate.artist, a.singer)
                let sb = StudioPick.isCleanTitle(b.name) && NameMatch.singerMatches(candidate.artist, b.singer)
                if sa != sb { return sa && !sb }
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

