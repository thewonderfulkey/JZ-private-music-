import AVFoundation
import Foundation
import Observation

// MARK: - 播放引擎
//
// 职责：队列 + 播放模式 + 取流（复用网络层）+ 时长校验 + 无源跳歌 + 进度/缓冲 + 锁屏信息。
// 与 Android `PlayerManager` / `AppState` 的口径对齐，但实现换成 AVPlayer：
//   · 单后端 12s 超时、三级取流链、音质按「探测到的事实」挑（都在网络层，这里只调用）
//   · 播完按 PlayMode 推进（单曲循环是重播当前曲，不是停止）
//   · 实际时长与曲目时长差 >5s 判为坏源 → 拒播并换源
//   · 连续 3 首无源就停下并给一句人话
@MainActor
@Observable
final class PlayerEngine {

    // MARK: 对外状态

    private(set) var queue: [Song] = []
    private(set) var index: Int = -1
    private(set) var currentSong: Song?
    private(set) var source: StreamSource?

    private(set) var isPlaying = false
    private(set) var isResolving = false
    /// 状态行（解析中 / 音源信息 / 跳歌提示）
    private(set) var statusText: String?
    /// 错误行（无源、播放失败）
    private(set) var errorText: String?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// 精确播放位置（秒）：直接向 AVPlayer 取，供逐字歌词按 30fps 推进使用。
    /// 常规 UI 仍用 `currentTime`（0.5 秒一次的时间观察者），避免全页高频重绘。
    var preciseTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : currentTime
    }

    // 歌词（由 LyricsService 取，酷我官方优先、失败回退 LDDC）
    private(set) var lyrics: [LyricLine] = []
    private(set) var lyricsSource: String = ""
    private(set) var lyricIndex: Int = -1
    private(set) var isLoadingLyrics = false
    var hasLyrics: Bool { !lyrics.isEmpty }
    var currentLyricLine: LyricLine? {
        guard lyricIndex >= 0, lyrics.indices.contains(lyricIndex) else { return nil }
        return lyrics[lyricIndex]
    }
    /// 已缓冲到的位置（进度条上那条浅色带）
    private(set) var bufferedTime: Double = 0

    /// 播放模式（持久化，键名与 Android 一致：`play_mode`）
    var mode: PlayMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.keyMode) }
    }

    /// 音质偏好（持久化，键名 `quality`；Android 默认 HIGH）
    var quality: QualityLevel {
        didSet { defaults.set(quality.rawValue, forKey: Self.keyQuality) }
    }

    // MARK: 内部

    private let player = AVPlayer()
    private let defaults = UserDefaults.standard
    private static let keyMode = "play_mode"
    private static let keyQuality = "quality"

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    private var consecutiveSkips = 0
    /// 被判为坏源（时长不符 / 放不出来）的 URL，换源时跳过，避免同一首歌反复撞同一条
    private var rejectedSourceURLs: Set<String> = []

    var hasCurrentSong: Bool { currentSong != nil }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    // MARK: 生命周期

    /// 系统面（音频会话 / 远程命令 / 进度观察）推迟到第一次真正播放时再装配
    /// （见 `attachSystemIfNeeded`），这样 View 里创建引擎只付一个 UserDefaults 读取的代价。
    init() {
        let store = UserDefaults.standard
        let savedMode = store.string(forKey: Self.keyMode).flatMap(PlayMode.init(rawValue:))
        let savedQuality = store.string(forKey: Self.keyQuality).flatMap(QualityLevel.init(rawValue:))
        mode = savedMode ?? .listLoop
        quality = savedQuality ?? .high
    }

    private var systemAttached = false

    /// 首次播放前把锁屏/远程命令/进度观察装起来（幂等）
    private func attachSystemIfNeeded() {
        guard !systemAttached else { return }
        systemAttached = true
        NowPlayingCenter.shared.attach(engine: self)
        installTimeObserver()
    }

    // MARK: 播放入口

    /// 单曲播放（搜索结果、识曲结果、歌单里点一首）
    func playSingle(_ song: Song) {
        play(queue: [song], startAt: 0)
    }

    /// 以给定队列起播（搜索结果的"整列当队列"、收藏的"播放全部"）
    func play(queue songs: [Song], startAt start: Int) {
        guard !songs.isEmpty else { return }
        attachSystemIfNeeded()
        queue = songs
        index = min(max(start, 0), songs.count - 1)
        currentSong = songs[index]
        rejectedSourceURLs.removeAll()
        consecutiveSkips = 0
        resetProgress()
        prepareLyrics(for: songs[index])
        Task { await loadCurrent() }
    }

    func toggle() {
        guard currentSong != nil else { return }
        attachSystemIfNeeded()
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if player.currentItem != nil {
            player.play()
            isPlaying = true
        } else {
            Task { await loadCurrent() }
            return
        }
        updateNowPlaying()
    }

    /// 下一首（用户点的，或播完自动推进）
    func nextTrack() {
        guard !queue.isEmpty else { return }
        guard let next = PlaybackRules.nextIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(next)
    }

    func previousTrack() {
        guard !queue.isEmpty else { return }
        guard let prev = PlaybackRules.previousIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(prev)
    }

    func cycleMode() {
        mode = mode.cycled()
        statusText = mode.displayName
    }

    /// 直接指定播放模式（播放页菜单里选某一档）
    func setMode(_ newMode: PlayMode) {
        guard mode != newMode else { return }
        mode = newMode
        statusText = newMode.displayName
        updateNowPlaying()
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(duration, duration * fraction))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        updateNowPlaying()
    }

    /// 队列整体替换（收藏页「播放全部」/ 资料库「随机播放」）
    func replaceQueue(_ songs: [Song], startAt start: Int = 0, shuffle: Bool = false) {
        if shuffle { mode = .shuffle }
        play(queue: songs, startAt: start)
    }

    // MARK: 内部流程

    private func goTo(_ newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        currentSong = queue[newIndex]
        rejectedSourceURLs.removeAll()
        resetProgress()
        prepareLyrics(for: queue[newIndex])
        Task { await loadCurrent() }
    }

    private func resetProgress() {
        currentTime = 0
        duration = Double(currentSong?.durationSec ?? 0)
        bufferedTime = 0
        errorText = nil
    }

    private func loadCurrent() async {
        guard let song = currentSong else { return }
        isResolving = true
        errorText = nil
        statusText = "正在解析音源…"

        let resolved = await resolveStream(for: song)
        isResolving = false

        guard let src = resolved else {
            handleNoSource()
            return
        }
        guard let url = URL(string: src.url) else {
            handleNoSource()
            return
        }

        source = src
        statusText = "音源 \(src.backendName) · \(src.format.uppercased()) · \(src.kbps) kbps"
        consecutiveSkips = 0

        let item = AVPlayerItem(url: url)
        wire(item: item, song: song, source: src)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    /// 三级取流 + 3 轮重试（与 Android `AppState.resolveAndPlayIfNeeded` 同口径：
    /// 本平台后端 → 同曲跨平台补位 → 间隔 2s / 2.5s / 3s 再试）
    private func resolveStream(for song: Song) async -> StreamSource? {
        let triedCandidates = TriedKeys()
        for attempt in 0..<3 {
            if attempt > 0 {
                let delays: [Double] = [2, 2.5, 3]
                let delay = delays[min(attempt - 1, delays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let local = await URLResolver.shared.resolveResult(song: song, quality: quality)
            if let pick = SourcePicker.pick(local.sources, want: quality),
               !rejectedSourceURLs.contains(pick.url) {
                return pick
            }
            if let cross = await SameSongCrossResolver.resolve(
                song: song, quality: quality, triedKeys: triedCandidates),
               !rejectedSourceURLs.contains(cross.url) {
                return cross
            }
        }
        return nil
    }

    // MARK: 播放项装配

    private func wire(item: AVPlayerItem, song: Song, source: StreamSource) {
        teardownObservers()

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let actual = item.duration.seconds
                    if actual.isFinite, actual > 0 {
                        self.duration = actual
                    }
                    // 时长防线：与曲目时长差 >5s 就是"标着这首歌、给的是别的版本"
                    if PlaybackRules.durationMismatch(actual: actual, expected: song.duration) {
                        self.rejectSource(source, reason: "拿到的音频时长 \(Int(actual))s 与曲目 \(Int(song.duration))s 不符（±5s），已换源")
                    }
                    self.updateNowPlaying()
                case .failed:
                    self.rejectSource(source, reason: "播放失败（源可能已失效），已换源")
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished() }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rejectSource(source, reason: "播放中断（源失效），已换源")
            }
        }
    }

    private func handleTrackFinished() {
        switch mode {
        case .singleLoop:
            // 单曲循环：同一份音频重播，不重新解析（省 1~12s）
            player.seek(to: .zero)
            player.play()
            currentTime = 0
            isPlaying = true
        case .listLoop, .shuffle:
            guard let next = PlaybackRules.nextIndex(
                count: queue.count, current: index, mode: mode,
                randomIn: { Int.random(in: $0) }) else { return }
            goTo(next)
        }
    }

    private func rejectSource(_ source: StreamSource, reason: String) {
        rejectedSourceURLs.insert(source.url)
        errorText = reason
        consecutiveSkips += 1
        if PlaybackRules.shouldStopAfterSkips(consecutiveSkips) {
            isPlaying = false
            errorText = PlaybackRules.skipMessage(consecutiveSkips)
            return
        }
        // 还有余量：换下一首（同一首的其它源会在 loadCurrent 里被重新解析）
        guard let next = PlaybackRules.nextIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(next)
    }

    private func handleNoSource() {
        consecutiveSkips += 1
        errorText = PlaybackRules.skipMessage(consecutiveSkips)
        isPlaying = false
        if PlaybackRules.shouldStopAfterSkips(consecutiveSkips) { return }
        guard let next = PlaybackRules.nextIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(next)
    }

    // MARK: 进度观察

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    self.currentTime = seconds
                    self.updateLyricIndex()
                }
                if let item = self.player.currentItem {
                    let ranges = item.loadedTimeRanges
                    if let last = ranges.last {
                        let range = last.timeRangeValue
                        let end = range.start.seconds + range.duration.seconds
                        if end.isFinite { self.bufferedTime = end }
                    }
                }
                self.updateNowPlaying()
            }
        }
    }

    private func teardownObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        failedObserver = nil
    }

    // MARK: 系统面

    func pauseForInterruption() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resumeAfterInterruption() {
        guard player.currentItem != nil, !isPlaying else { return }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    // MARK: 歌词

    /// 切歌时先清空，再异步取词（不阻塞起播：Android 同样是"起播前并发预热歌词"）
    private func prepareLyrics(for song: Song) {
        lyrics = []
        lyricsSource = ""
        lyricIndex = -1
        isLoadingLyrics = true
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(song)
            guard let self else { return }
            // 期间可能又切歌了，只有仍停在同一个 ID 才落地
            guard self.currentSong?.id == song.id else { return }
            self.lyrics = result?.lines ?? []
            self.lyricsSource = result?.source ?? ""
            self.isLoadingLyrics = false
            self.updateLyricIndex()
        }
    }

    private func updateLyricIndex() {
        let idx = LyricsCleaning.indexAt(lyrics, positionMs: Int(currentTime * 1000))
        if idx != lyricIndex { lyricIndex = idx }
    }

    private func updateNowPlaying() {
        NowPlayingCenter.shared.update(
            song: currentSong,
            source: source,
            isPlaying: isPlaying,
            currentTime: currentTime,
            duration: duration,
            buffered: bufferedTime,
            playMode: mode
        )
    }
}
