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

    /// 该被滚到屏幕中间的那一行（比 `lyricIndex` 早 `LyricsUXRules.scrollLeadMs`）。
    ///
    /// r65 老板："歌词现在统一都是滚动晚了一些"——高亮是准的，晚的是滚动动画。
    /// 播放页用 `lyricIndex` 决定哪一行白字，用这个决定 `scrollTo` 滚到哪一行。
    private(set) var lyricScrollIndex: Int = -1

    /// 歌词判定用的位置（毫秒）= 精确播放位置 + 用户设置的偏移。
    ///
    /// 为什么要 `preciseTime` 而不是 0.5 秒才更新一次的 `currentTime`：
    /// 之前高亮用的是时间观察者里的 currentTime，最坏情况整整晚半秒——
    /// 表现出来就是"唱到下一句了，上一句还亮着"。25Hz 的专用 ticker 把这个误差压到 40ms 内。
    var lyricPositionMs: Int { Int(preciseTime * 1000) + SettingsStore.shared.lyricOffsetMs }

    /// 已确认放不出来的歌（搜索结果里会被隐藏，与 Android 的 deadSongKeys 同口径）
    private(set) var deadSongKeys: Set<String> = []
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
    private var lyricTicker: Task<Void, Never>?
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
        startLyricTicker()
    }

    // MARK: 播放入口

    /// 单曲播放（搜索结果、识曲结果、歌单里点一首）
    func playSingle(_ song: Song) {
        play(queue: [song], startAt: 0)
    }

    /// 以给定队列起播（搜索结果的"整列当队列"、收藏的"播放全部"）
    ///
    /// r63（老板反馈 ⑤）：点的是**正在播的这首**时不再重新请求、不再重头播——
    /// 只把播放列表换成这次的整列，然后打开播放页。原来同一点击会走整条取流链，
    /// 表现为"切回去了、转圈、从头开始"。
    func play(queue songs: [Song], startAt start: Int) {
        guard !songs.isEmpty else { return }
        attachSystemIfNeeded()
        let target = min(max(start, 0), songs.count - 1)
        if PlaybackRules.shouldReuseCurrentSong(currentID: currentSong?.id,
                                                targetID: songs[target].id,
                                                hasLoadedItem: player.currentItem != nil,
                                                hasError: errorText != nil) {
            adoptQueue(songs, at: target)
            return
        }
        queue = songs
        index = target
        currentSong = songs[target]
        rejectedSourceURLs.removeAll()
        consecutiveSkips = 0
        resetProgress()
        prepareLyrics(for: songs[target])
        Task { await loadCurrent() }
    }

    /// 同一首歌再次被点：只换列表，不动正在放的音频/进度/歌词
    private func adoptQueue(_ songs: [Song], at newIndex: Int) {
        queue = songs
        index = newIndex
        // currentSong 不变（同一首），进度、歌词、音源全部保留
        updateNowPlaying()
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

    /// 绝对位置跳转（秒）。所有跳转（进度条拖动 / 点歌词 / 无障碍调整）都走这里，
    /// 不再各自乘一遍 `duration`——`duration` 一旦与实际音频有毫秒级差，乘除会把误差放大。
    func seek(toSeconds seconds: Double) {
        guard duration > 0 else { return }
        let safe = seconds.isFinite ? seconds : 0
        let target = max(0, min(duration, safe))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        // 刚 seek 完 `AVPlayer.currentTime()` 还是旧值，而 40ms 的歌词 ticker 只在播放时跑：
        // 暂停状态下如果照旧用 preciseTime 算，就会出现"跳过去了，高亮还停在上上句"。
        lyricIndex = LyricsCleaning.indexAt(
            lyrics,
            positionMs: Int(target * 1000) + SettingsStore.shared.lyricOffsetMs)
        lyricScrollIndex = lyricIndex
        updateNowPlaying()
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(toSeconds: duration * min(max(fraction, 0), 1))
    }

    /// 点某一句歌词 → 跳到那一句。
    ///
    /// 目标是「行时间 − 用户偏移」：跳完以后 `indexAt(位置 + 偏移)` 正好等于这一行，
    /// 所以高亮一定落在被点的那一句上。
    /// 老板说的"点歌词跳转的位置不对"，一半是这个偏移没算进去，一半是按 fraction 乘出来的误差。
    func seek(toLyricLine index: Int) {
        guard lyrics.indices.contains(index) else { return }
        let offset = SettingsStore.shared.lyricOffsetMs
        let targetMs = LyricsCleaning.seekTargetMs(lineMs: lyrics[index].timeMs, userOffsetMs: offset)
        seek(toSeconds: Double(targetMs) / 1000)
        lyricIndex = index
        lyricScrollIndex = index
    }

    /// 播放列表里点某一首（队列不动，只换当前曲）
    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        if newIndex == index {
            if !isPlaying { toggle() }
            return
        }
        goTo(newIndex)
    }

    /// 队列整体替换（收藏页「播放全部」/ 资料库「随机播放」）
    func replaceQueue(_ songs: [Song], startAt start: Int = 0, shuffle: Bool = false) {
        if shuffle { mode = .shuffle }
        play(queue: songs, startAt: start)
    }

    /// 队列追加（发现页「播放全部」先起播 5 首，其余解析完再补进队列；已在队列里的不重复加）
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let existing = Set(queue.map { $0.id })
        let fresh = songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queue.append(contentsOf: fresh)
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
        errorText = nil

        // 已下到本地的歌优先播本地文件：离线也能放，也省掉一次解析
        if let localURL = DownloadManager.shared.localFileURL(for: song) {
            let local = StreamSource(url: localURL.absoluteString,
                                     backendName: "本地文件",
                                     platform: song.platform,
                                     quality: quality,
                                     format: localURL.pathExtension.lowercased(),
                                     note: "已下载")
            statusText = "本地文件 · \(localURL.lastPathComponent)"
            start(item: AVPlayerItem(url: localURL), song: song, source: local)
            return
        }

        isResolving = true
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

        statusText = "音源 \(src.backendName) · \(src.format.uppercased()) · \(src.kbps) kbps"
        start(item: AVPlayerItem(url: url), song: song, source: src)
    }

    /// 装配并起播一个 item（本地文件与在线取流共用这一处）
    private func start(item: AVPlayerItem, song: Song, source: StreamSource) {
        self.source = source
        consecutiveSkips = 0
        wire(item: item, song: song, source: source)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    /// 三级取流 + 可配置重试（与 Android `AppState.resolveAndPlayIfNeeded` 同口径：
    /// 本平台后端 → 同曲跨平台补位 → 间隔 2s / 2.5s / 3s 再试）
    ///
    /// 两个设置开关在这里真正生效：
    ///   · 「无源自动换源」关掉 → 只解析一轮，不做 2s/2.5s/3s 重试
    ///   · 「跨平台补源」关掉 → 不调用同曲跨平台解析
    private func resolveStream(for song: Song) async -> StreamSource? {
        let settings = SettingsStore.shared
        let attempts = settings.autoFallback ? 3 : 1
        let triedCandidates = TriedKeys()
        for attempt in 0..<attempts {
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
            if settings.crossPlatformBackfill,
               let cross = await SameSongCrossResolver.resolve(
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

    /// 连跳上限：设置里关掉「自动跳歌」时只允许跳 1 首就停
    private var skipLimit: Int {
        let settings = SettingsStore.shared
        return settings.autoSkipDeadSongs ? max(1, settings.skipLimit) : 1
    }

    private func rejectSource(_ source: StreamSource, reason: String) {
        rejectedSourceURLs.insert(source.url)
        if let song = currentSong { deadSongKeys.insert(song.id) }
        errorText = reason
        consecutiveSkips += 1
        if PlaybackRules.shouldStopAfterSkips(consecutiveSkips, limit: skipLimit) {
            isPlaying = false
            errorText = PlaybackRules.skipMessage(consecutiveSkips, limit: skipLimit)
            return
        }
        // 还有余量：换下一首（同一首的其它源会在 loadCurrent 里被重新解析）
        guard let next = PlaybackRules.nextIndex(
            count: queue.count, current: index, mode: mode,
            randomIn: { Int.random(in: $0) }) else { return }
        goTo(next)
    }

    private func handleNoSource() {
        if let song = currentSong { deadSongKeys.insert(song.id) }
        consecutiveSkips += 1
        errorText = PlaybackRules.skipMessage(consecutiveSkips, limit: skipLimit)
        isPlaying = false
        if PlaybackRules.shouldStopAfterSkips(consecutiveSkips, limit: skipLimit) { return }
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

    /// 歌词取不到时的原因（播放页空状态里显示给人看，r63 加：下一轮一眼就能定位是哪条链断了）
    private(set) var lyricsFailure: String = ""

    /// 切歌时先清空，再异步取词（不阻塞起播：Android 同样是"起播前并发预热歌词"）
    ///
    /// 第五轮（老板反馈 ⑧）：已下载的歌**先读下载时一起存下的本地 LRC**——
    /// 无网络环境（飞机上、地铁里）点开下载好的歌，也要有词可看，不能只剩播放器。
    /// 本地没有才走网络；网络失败时保持空态（播放页有「重试」+ 失败原因）。
    private func prepareLyrics(for song: Song) {
        lyrics = []
        lyricsSource = ""
        lyricIndex = -1
        lyricScrollIndex = -1
        lyricsFailure = ""

        if let local = DownloadManager.shared.localLyrics(for: song), !local.isEmpty {
            lyrics = local
            lyricsSource = "本地歌词"
            isLoadingLyrics = false
            updateLyricIndex()
            return
        }

        isLoadingLyrics = true
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(song)
            guard let self else { return }
            // 期间可能又切歌了，只有仍停在同一个 ID 才落地
            guard self.currentSong?.id == song.id else { return }
            self.lyrics = result?.lines ?? []
            self.lyricsSource = result?.source ?? ""
            self.isLoadingLyrics = false
            if result == nil {
                let reason = await LyricsService.shared.failureReason()
                guard self.currentSong?.id == song.id else { return }
                self.lyricsFailure = reason
            }
            self.updateLyricIndex()
        }
    }

    private func updateLyricIndex() {
        let position = lyricPositionMs
        let idx = LyricsCleaning.indexAt(lyrics, positionMs: position)
        if idx != lyricIndex { lyricIndex = idx }
        let anchor = LyricsCleaning.scrollAnchorIndex(lyrics, positionMs: position,
                                                     leadMs: LyricsUXRules.scrollLeadMs)
        if anchor != lyricScrollIndex { lyricScrollIndex = anchor }
    }

    /// 25Hz 的歌词定位 ticker（只在播放时推进）
    ///
    /// 为什么不放在 TimeObserver 里：那个是 0.5 秒一次，用来驱动进度条足够，
    /// 用来切歌词就是"永远慢半拍"。这里只在 `isPlaying` 时算，代价是每 40ms 一次
    /// `AVPlayer.currentTime()` + 一次线性扫（歌词几百行，扫到头也就微秒级）。
    private func startLyricTicker() {
        lyricTicker?.cancel()
        lyricTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self else { return }
                if self.isPlaying, !self.lyrics.isEmpty { self.updateLyricIndex() }
            }
        }
    }

    /// 播放页重取歌词（首次取词失败时自动/手动重试；不打断播放）
    ///
    /// 之前「歌词一直是空」有两层原因，都会在这里被兜住：
    ///   ① 取词发生在切歌那一瞬间，弱网/接口抽风失败后没有第二次机会 → 现在播放页打开时会再取一次；
    ///   ② 用户只能看到一句"暂无歌词"，没有重试入口 → 播放页的空状态里给了一个「重试」。
    func reloadLyrics() {
        guard let song = currentSong, !isLoadingLyrics else { return }
        prepareLyrics(for: song)
    }

    private func updateNowPlaying() {
        // r65：实时活动（锁屏黑卡 / 灵动岛）已下线，这里只喂系统自带的锁屏播放器
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
