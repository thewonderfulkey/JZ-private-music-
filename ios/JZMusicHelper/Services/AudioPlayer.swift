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

    /// 起播后台换源（先粗后精）：同一首只换一次，换曲时取消
    private var upgradeTask: Task<Void, Never>?
    private var upgradedSongID: String?

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

    /// 进度条 / 时间标签显示用的位置——**必须和歌词用同一个时钟**。
    ///
    /// 为什么不能直接用 `currentTime`：seek 之后 `currentTime` 先被设成目标，但 0.5 秒一次的
    /// 时间观察者随后会把播放头**尚未落地时的旧值**写回来（录屏里表现为：点歌词跳到 1:49，
    /// 标签却回到 1:20；拖到 1:46，标签对而高亮是 0:41）。标签和歌词各自用一套时间，
    /// 用户看到的就永远是"歌词不准"。
    ///
    /// 现在两边都走 `LyricsUXRules.seekClockSource`：seek 未落地用目标位置，落地（±1.2s）或
    /// 窗口到期用真实位置。这样"标签显示的时间"和"高亮那一行"在任何时刻都对得上。
    var displayTime: Double {
        guard let optimistic = seekOptimistic else { return currentTime }
        let rawMs = Int(preciseTime * 1000)
        let source = LyricsUXRules.seekClockSource(
            positionMs: rawMs,
            targetMs: optimistic.targetMs,
            optimisticExpired: Date() >= optimistic.until)
        return source == .useTarget ? Double(optimistic.targetMs) / 1000 : currentTime
    }

    /// 进度条（含迷你条那条 2pt 细线）用的比例：跟着 `displayTime` 走
    var displayProgress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayTime / duration, 0), 1)
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

    /// 歌词判定用的位置（毫秒）= 精确播放位置 + **这首自己的**偏移。
    ///
    /// 为什么要 `preciseTime` 而不是 0.5 秒才更新一次的 `currentTime`：
    /// 之前高亮用的是时间观察者里的 currentTime，最坏情况整整晚半秒——表现出来就是"唱到下一句了，上一句还亮着"。
    /// 25Hz 的专用 ticker 把这个误差压到 40ms 内。
    ///
    /// r71：偏移改成**按单曲**取（`SettingsStore.offsetMs(forSong:)`）。以前读的是全局一个数，
    /// 为了对齐某一首调出来的偏移会把其它所有歌一起推走。
    var lyricPositionMs: Int { Int(preciseTime * 1000) + lyricOffsetMs }

    /// 当前这首实际生效的歌词偏移（毫秒）
    var lyricOffsetMs: Int {
        SettingsStore.shared.offsetMs(forSong: currentSong?.id)
    }

    /// 每次跳转 +1。歌词面板监听它，跳完强制重排一次（r68：快进/快退后滚动不准）
    private(set) var seekNonce: Int = 0

    /// seek 之后的**乐观窗口**：窗口内用"目标位置"推歌词（画面不倒退），
    /// 窗口一到就改用播放头真实位置（宁可跳一下，也绝不冻住）。
    ///
    /// 历史：r76 写死 0.7 秒（太短，远端流还没落地就被旧位置拽回上一句）；
    /// r77 改成"等追上目标才解，兜底 10 秒"——结果远端流的 seek 完成回调经常不回来，
    /// 高亮/滚动整整冻 10 秒（老板 r85："一跳就瞬间对不上，滚动时间也不对"）。
    /// 第二十二轮：窗口上限 **1.5 秒**，并且**永远给出一个位置**（见 `LyricsUXRules.seekClockSource`），
    /// 播放头一旦落到目标 ±1.2 秒内立刻切回真实位置。规则与歌曲无关，所以所有歌表现一致。
    private var seekOptimistic: (targetMs: Int, until: Date)?
    /// 每次 seek +1：完成回调回来时如果已经不是最新那次，直接丢掉
    private var seekToken: Int = 0

    /// 点某一句歌词跳转后"还没唱到的那一行"。播放头走到这一行的时间之前，高亮与滚动都钉在它上面。
    ///
    /// 为什么需要：`AVPlayer.seek` 真机上常落到目标**之前**几百毫秒（关键帧对齐），
    /// 而 `indexAt` 是「行时间 ≤ 位置」，早 1ms 就推成上一句 —— 于是"点下去是对的、
    /// 下一拍又退回上一句"，正是老板反复提的"用歌词快进/后退之后就不准了"。
    /// 规则见 `LyricsCleaning.lyricSeekHoldDecision`（纯函数，CI 有断言），与歌曲无关。
    private var pendingLyricLine: Int?

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
    ///
    /// 切换统一走 `didSet`：进/出心动模式必须同步给引擎（否则从收藏页点「随机播放」
    /// 这种直接赋值的路径会绕过 `setMode`，心动规划在后台继续跑）。
    var mode: PlayMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.keyMode)
            if oldValue != mode { syncHeartbeatMode() }
        }
    }

    /// 音质偏好（持久化，键名 `quality`）。
    ///
    /// 第四十轮：设置页不再暴露这一项——老板口径是"默认就是最高音质，拿不到再逐级往下降"。
    /// 这里仍保留这个值（下载页/诊断要看"我在按哪一档取"），初始化恒为无损；
    /// 真正的降档由 `SourcePicker.score` 完成（无损 > 高品 > 标准，同分优先直连后端）。
    var quality: QualityLevel {
        didSet { defaults.set(quality.rawValue, forKey: Self.keyQuality) }
    }

    // MARK: 内部

    private let player = AVPlayer()

    /// 心动模式（选歌 + 预取 + 负反馈）。播放器只负责"放"，它只负责"选"。
    /// 放在 init 里显式建（而不是属性默认值）：`@MainActor` 类型在属性默认值里初始化，
    /// 在部分 Swift 版本会被判成"nonisolated 上下文里初始化主线程隔离类型"。
    let heartbeat: HeartbeatEngine

    /// 播放页要显示的心动状态（透传，避免视图直接摸引擎内部）
    var heartbeatReason: String { heartbeat.reason }
    var heartbeatNotice: String? { heartbeat.notice }
    var isHeartbeatPlanning: Bool { heartbeat.isPlanning }
    var heartbeatUpcoming: [HeartbeatEngine.Pick] { heartbeat.upcoming }

    private let defaults = UserDefaults.standard
    private static let keyMode = "play_mode"
    private static let keyQuality = "quality"

    private var timeObserver: Any?
    private var lyricTicker: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// `item.duration` 的观察（远端流要读一会儿头才知道总长，可能在 readyToPlay 之后才有效）
    private var durationObservation: NSKeyValueObservation?

    private var consecutiveSkips = 0
    /// 被判为坏源（时长不符 / 放不出来）的 URL，换源时跳过，避免同一首歌反复撞同一条
    private var rejectedSourceURLs: Set<String> = []
    /// 续播断点：等这一条播放项 ready 之后再 seek（见 `play(queue:startAt:positionSeconds:)`）
    private var pendingRestoreSeconds: Double?

    /// 心动模式预取下来的本地文件（切歌那一秒直接用，不再走网络）
    private var pendingLocal: (songID: String, url: URL)?

    /// 心动模式已经解析好的流地址（没来得及下载时用，省掉再解析一遍的 1-8 秒）
    private var pendingStream: (songID: String, url: String)?

    /// 进入心动模式时的队列下标：它之后的才是"心动自己追加的歌"。
    /// 「上一首」之后再按「下一首」要靠它回到刚才那首，而不是在旧歌单里往下走。
    private var heartbeatStartIndex = -1

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
        mode = savedMode ?? .listLoop
        // 第四十轮：音质不再是设置项。恒从最高档起取，拿不到由取流器逐级下降
        // （老用户存过的低档值一并忽略，不再把"以前调过 128k"带着走）。
        quality = .lossless
        heartbeat = HeartbeatEngine()
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
        // 上一首到此为止：把"听了多久"结算掉（心动模式的负反馈与质量分都靠它）
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        stopCurrentForSwitch()
        queue = songs
        index = target
        currentSong = songs[target]
        rejectedSourceURLs.removeAll()
        consecutiveSkips = 0
        resetProgress()
        prepareLyrics(for: songs[target])
        syncHeartbeatSeed(songs[target])
        Task { await loadCurrent() }
    }

    /// 心动模式下用户手点了别的歌：种子跟着换（网易云同款），待播重排。
    private func syncHeartbeatSeed(_ song: Song) {
        guard mode == .heartbeat else { return }
        // 换了一整列歌：从这一列的最后一个下标之后才算"心动自己追加的"
        heartbeatStartIndex = queue.count - 1
        if heartbeat.isActive {
            heartbeat.adoptSeed(song)
        } else {
            heartbeat.activate(seed: song)
        }
    }

    /// 从"上次断点"续播（车载自动播放用）：队列 + 起始位置一起给。
    ///
    /// 位置要等播放项真的 ready 才能 seek（远端流刚 replace 时 `duration` 还是 0），
    /// 所以这里只记 `pendingRestoreSeconds`，由 `wire(item:...)` 的 readyToPlay 分支落地。
    func play(queue songs: [Song], startAt start: Int, positionSeconds: Double) {
        guard !songs.isEmpty else { return }
        attachSystemIfNeeded()
        let target = min(max(start, 0), songs.count - 1)
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        stopCurrentForSwitch()
        queue = songs
        index = target
        currentSong = songs[target]
        rejectedSourceURLs.removeAll()
        consecutiveSkips = 0
        resetProgress()
        pendingRestoreSeconds = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        prepareLyrics(for: songs[target])
        syncHeartbeatSeed(songs[target])
        Task { await loadCurrent() }
    }

    /// 上次播放快照（车载连上时"接着上次没播完的接着放"读它）
    ///
    /// - Parameter finished: 是否"自然播到结尾"结束（这种不算没播完，下次交给热门歌单）
    func flushSnapshot(finished: Bool = false, force: Bool = false) {
        guard let song = currentSong else { return }
        let tail: [Song]
        if queue.indices.contains(index) {
            tail = Array(queue[index...].prefix(50))
        } else {
            tail = [song]
        }
        let total = duration > 0 ? duration : Double(song.durationSec)
        let snapshot = PlaybackSnapshot(song: song,
                                        songs: tail,
                                        positionSec: max(0, currentTime),
                                        durationSec: total,
                                        savedAt: Date(),
                                        finished: finished)
        PlaybackSnapshotStore.shared.save(snapshot, force: force || finished)
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
        // r71：正在换曲解析时不要把上一首又播起来（那时 currentItem 还是旧的）
        if isResolving { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            // 暂停时落一次快照：车载连上要"接着放"，断点就在这一下
            flushSnapshot(force: true)
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
        if mode == .heartbeat {
            // 用户按的"下一首"= 一次"跳过"，<30 秒算负反馈（写进事件，画像自己会用）
            heartbeat.trackEnded(listened: preciseTime, completed: false)
            // 回来过（上一首 → 下一首）就走心动自己追加过的那一首，而不是再算一首新的
            let queuedNext = index + 1
            if queuedNext < queue.count, queuedNext > heartbeatStartIndex {
                goTo(queuedNext)
                return
            }
            if let pick = heartbeat.takeNext() {
                playHeartbeat(pick: pick)
            } else {
                planAndPlayHeartbeat()
            }
            return
        }
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

    /// 进/出心动模式：进去就以当前这首为种子排下一首，出来就停掉规划。
    private func syncHeartbeatMode() {
        if mode == .heartbeat {
            // 原有队列的最后一个下标：它之后才是心动自己追加的歌
            heartbeatStartIndex = queue.count - 1
            heartbeat.activate(seed: currentSong)
        } else {
            heartbeatStartIndex = -1
            heartbeat.deactivate()
        }
    }

    /// 绝对位置跳转（秒）。所有跳转（进度条拖动 / 点歌词 / 无障碍调整）都走这里，
    /// 不再各自乘一遍 `duration`——`duration` 一旦与实际音频有毫秒级差，乘除会把误差放大。
    ///
    /// 第二十二轮：这里只负责"把 seek 发出去 + 记下目标 + 立刻把高亮放到目标那一行"，
    /// 之后由 `updateLyricIndex()` 用乐观窗口 + 真实位置接管（见 `seekOptimistic`）。
    func seek(toSeconds seconds: Double) {
        guard duration > 0 else { return }
        let safe = seconds.isFinite ? seconds : 0
        let target = max(0, min(duration, safe))
        seekToken &+= 1
        let token = seekToken
        // 任何一次绝对位置跳转（进度条拖动 / 无障碍调整）都取消"等它唱到"的钉子；
        // 点歌词那条路径（`seek(toLyricLine:)`）会在下面重新钉住目标行。
        pendingLyricLine = nil
        currentTime = target
        // 乐观窗口：这段时间内以"目标位置"推歌词，落地（或 1.5 秒到）就切回真实位置
        seekOptimistic = (Int(target * 1000),
                          Date().addingTimeInterval(LyricsUXRules.seekOptimisticMaxSeconds))
        seekNonce &+= 1
        // 刚 seek 完 `AVPlayer.currentTime()` 还是旧值，而 40ms 的歌词 ticker 只在播放时跑：
        // 暂停状态下如果照旧用 preciseTime 算，就会出现"跳过去了，高亮还停在上上句"。
        lyricIndex = LyricsCleaning.indexAt(
            lyrics,
            positionMs: Int(target * 1000) + lyricOffsetMs)
        lyricScrollIndex = lyricIndex
        updateNowPlaying()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, let self else { return }
            Task { @MainActor in
                guard self.seekToken == token else { return }
                self.settleSeek()
            }
        }
    }

    /// seek 完成回调：只做"尽早切回真实位置"，不做任何钉住/冻结。
    ///
    /// 回调回来时若播放头已经在目标 ±`seekLandToleranceMs` 内，说明真落地了 → 立刻用真实位置；
    /// 否则什么都不做，等乐观窗口到期（最迟 1.5 秒）自然切换。
    private func settleSeek() {
        let raw = Int(preciseTime * 1000)
        if let opt = seekOptimistic,
           abs(raw - opt.targetMs) <= LyricsUXRules.seekLandToleranceMs {
            seekOptimistic = nil
        }
        updateLyricIndex()
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
        let offset = lyricOffsetMs
        let targetMs = LyricsCleaning.seekTargetMs(lineMs: lyrics[index].timeMs, userOffsetMs: offset)
        seek(toSeconds: Double(targetMs) / 1000)
        lyricIndex = index
        lyricScrollIndex = index
        // seek 落地常提前几百毫秒：在那之前把这一行钉住，否则下一拍 ticker 会退回上一句
        pendingLyricLine = index
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

    private func goTo(_ newIndex: Int, localURL: URL? = nil, streamURL: String? = nil) {
        guard queue.indices.contains(newIndex) else { return }
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        if let localURL {
            pendingLocal = (songID: queue[newIndex].id, url: localURL)
        } else {
            pendingLocal = nil
        }
        if let streamURL {
            pendingStream = (songID: queue[newIndex].id, url: streamURL)
        } else {
            pendingStream = nil
        }
        stopCurrentForSwitch()
        index = newIndex
        currentSong = queue[newIndex]
        rejectedSourceURLs.removeAll()
        resetProgress()
        prepareLyrics(for: queue[newIndex])
        Task { await loadCurrent() }
    }

    /// 换曲前**先把当前这首停下来**（r71，老板："换曲的时候先暂停当前的歌曲，之前好好的，现在又没了"）。
    ///
    /// 为什么必须有：新曲要先解析音源（同平台解析 1~3 秒，跨平台补位最长 12 秒），
    /// 这段时间旧音频还在播——听起来像"点了下一首，上一首又唱了半句"。
    /// 现在点下去立刻静音（`player.pause()` + `isPlaying = false`），解析完 `start(item:)` 再起播。
    ///
    /// 只暂停、不 `replaceCurrentItem`：保留当前 item 和进度，用户在解析期间点播放键还能继续听这首。
    private func stopCurrentForSwitch() {
        upgradeTask?.cancel()
        upgradeTask = nil
        guard PlaybackRules.shouldPauseBeforeSwitch(hasLoadedItem: player.currentItem != nil) else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    private func resetProgress() {
        currentTime = 0
        duration = Double(currentSong?.durationSec ?? 0)
        bufferedTime = 0
        errorText = nil
        // r77：换曲时把 seek 状态也清掉。上一首的 completion 有可能因为 item 被换掉
        // 而回 finished=false，窗口要是留着，新曲开头的高亮会被冻住。
        seekOptimistic = nil
        // 换曲：上一首"还没唱到的那一行"不能带到新曲上（行号会撞到别的歌词）
        pendingLyricLine = nil
        // 换曲：上一首的续播断点也不能带过来（否则这首会莫名其妙跳到那个位置）
        pendingRestoreSeconds = nil
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

        // 心动模式预取下来的那一首：直接本地起播（这就是"切歌无缝"的关键）
        if let pending = pendingLocal, pending.songID == song.id {
            pendingLocal = nil
            pendingStream = nil
            if FileManager.default.fileExists(atPath: pending.url.path) {
                let local = StreamSource(url: pending.url.absoluteString,
                                         backendName: "心动缓存",
                                         platform: song.platform,
                                         quality: .high,
                                         format: pending.url.pathExtension.lowercased(),
                                         note: "播放中预取")
                statusText = "心动缓存 · \(pending.url.lastPathComponent)"
                start(item: AVPlayerItem(url: pending.url), song: song, source: local)
                // 起播后按在线源继续升档（与在线起播同一条链，不牺牲音质）
                scheduleQualityUpgrade(for: song)
                return
            }
        }
        pendingLocal = nil

        // 心动模式现场解析好的流地址：直接用，省掉再走一遍取流链
        if let pending = pendingStream, pending.songID == song.id,
           let url = URL(string: pending.url) {
            pendingStream = nil
            let src = StreamSource(url: pending.url,
                                   backendName: "心动解析",
                                   platform: song.platform,
                                   quality: .high,
                                   format: url.pathExtension.lowercased(),
                                   note: "播放中解析")
            statusText = "心动解析 · \(src.format.isEmpty ? "流" : src.format.uppercased())"
            start(item: AVPlayerItem(url: url), song: song, source: src)
            scheduleQualityUpgrade(for: song)
            return
        }
        pendingStream = nil

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
        // 冷启动续播（快照/车载）走的不是 play(queue:)，这里补一次激活，否则心动引擎是"关着"的
        if mode == .heartbeat, !heartbeat.isActive {
            heartbeatStartIndex = queue.count - 1
            heartbeat.activate(seed: song)
        }
        // 每首真正起播都记一次事件（不限心动模式）：画像是靠全部播放历史学的
        heartbeat.trackStarted(song)
        updateNowPlaying()
        // 起播就记一次（位置 0）：万一进程在这儿被杀，下次车载连上也知道"上一首是它"
        flushSnapshot()
    }

    /// 三级取流（老板 2026-11-19 口径：**播放链允许"先粗后精"**，下载链不允许）：
    ///   ① 本平台 + 妖狐 并发，质量窗口 1.8s 内取分最高的先起播（起播速度优先）；
    ///   ② 窗口内一条都没有 → 等下载链的完整排名（全收集 + 打分）；
    ///   ③ 起播后后台继续跑排名，出现更高档的源就替换（保留进度）；
    ///   ④ 仍然没有才走"跨源补位"并按 2s / 2.5s / 3s 重试。
    private func resolveStream(for song: Song) async -> StreamSource? {
        let attempts = 3
        let triedCandidates = TriedKeys()
        for attempt in 0..<attempts {
            if attempt > 0 {
                let delays: [Double] = [2, 2.5, 3]
                let delay = delays[min(attempt - 1, delays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if attempt == 0,
               let quick = await DownloadResolver.quickPick(song: song, want: quality),
               !rejectedSourceURLs.contains(quick.source.url) {
                scheduleQualityUpgrade(for: song)
                return quick.source
            }
            let plan = await DownloadResolver.plan(song: song, want: quality)
            if let picked = plan.picked, !rejectedSourceURLs.contains(picked.source.url) {
                scheduleQualityUpgrade(for: song)
                return picked.source
            }
            if let cross = await SameSongCrossResolver.resolve(
                song: song, quality: quality, triedKeys: triedCandidates),
               !rejectedSourceURLs.contains(cross.url) {
                return cross
            }
        }
        return nil
    }

    // MARK: 后台换更高档（先粗后精的"后精"）

    /// 起播后按下载链的排名再找一次；只有"档位更高"才换，避免来回横跳。
    /// 当前已经是无损（tier 1000）就不启动，省掉一轮 15s 的收集。
    private func scheduleQualityUpgrade(for song: Song) {
        guard let cur = source, DownloadResolver.tierOf(cur) < 1000 else { return }
        guard upgradedSongID != song.id else { return }
        upgradeTask?.cancel()
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            let plan = await DownloadResolver.plan(song: song, want: self.quality)
            guard !Task.isCancelled else { return }
            guard self.currentSong?.id == song.id else { return }
            guard let better = plan.picked?.source,
                  DownloadResolver.isBetter(better, than: self.source) else { return }
            self.upgradedSongID = song.id
            self.swapToBetterSource(better)
        }
    }

    private func swapToBetterSource(_ src: StreamSource) {
        guard let url = URL(string: src.url), let song = currentSong else { return }
        let pos = player.currentTime().seconds
        // 换源保留进度：ready 之后由 pendingRestoreSeconds 归位（见 wire(item:)）
        pendingRestoreSeconds = (pos.isFinite && pos > 1) ? pos : nil
        statusText = "换源 \(src.backendName) · \(src.format.uppercased()) · \(src.kbps) kbps"
        start(item: AVPlayerItem(url: url), song: song, source: src)
    }

    // MARK: 播放项装配

    private func wire(item: AVPlayerItem, song: Song, source: StreamSource) {
        teardownObservers()

        // r66：时长单独观察。远端渐进式流在 readyToPlay 那一刻 `item.duration` 常是 indefinite，
        // 只在 status 回调里读一次就会永远停在元数据时长（→ 进度条先到头、歌还在唱）。
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            Task { @MainActor in self?.adoptDuration(seconds) }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let actual = item.duration.seconds
                    self.adoptDuration(actual)
                    // 续播断点：ready 之后才能 seek（这时 duration 才可信）
                    if let restore = self.pendingRestoreSeconds {
                        self.pendingRestoreSeconds = nil
                        self.seek(toSeconds: restore)
                    }
                    // 时长防线：与曲目时长差 >25s 就是"标着这首歌、给的是别的版本"
                    if PlaybackRules.durationMismatch(actual: actual, expected: song.duration) {
                        self.rejectSource(source, reason: "拿到的音频时长 \(Int(actual))s 与曲目 \(Int(song.duration))s 不符（±\(Int(PlaybackRules.durationToleranceSec))s），已换源")
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
        // 播到真结尾了：这时 currentTime 就是这条音频的真实长度，覆盖掉容器/元数据那份
        if currentTime > duration { duration = currentTime }
        // 这一轮已经放完：快照标 finished，下次车载连上就不"续播"它，改放热门
        flushSnapshot(finished: true)
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
        case .heartbeat:
            // 播完这首才算"听完"（负反馈只看 userSkipped/nextTrack 那条路径）
            heartbeat.trackEnded(listened: duration > 0 ? duration : currentTime, completed: true)
            if let pick = heartbeat.takeNext() {
                playHeartbeat(pick: pick)
            } else {
                // 预取还没来得及（弱网/刚切进来）：现场算一首，算不出来就停在这里，不静默跳走
                planAndPlayHeartbeat()
            }
        }
    }

    // MARK: 心动模式

    /// 把引擎选的下一首接进队列并起播。
    ///
    /// 队列语义：心动模式下的 `queue` 就是"本次心动的会话队列"（已播 + 当前 + 即将），
    /// 所以新歌追加在后面，`index` 跟过去；上一首/播放列表因此天然可用。
    private func playHeartbeat(pick: HeartbeatEngine.Pick) {
        if let existing = queue.firstIndex(where: { $0.id == pick.song.id }) {
            guard existing != index else { return }
            goTo(existing, localURL: pick.localURL, streamURL: pick.streamURL)
            return
        }
        queue.append(pick.song)
        goTo(queue.count - 1, localURL: pick.localURL, streamURL: pick.streamURL)
    }

    /// 待播空了：现场算一首（最多等一次解析）。算不出来就停住并给一句人话。
    private func planAndPlayHeartbeat() {
        guard !isResolving else { return }
        isResolving = true
        statusText = "心动模式正在选下一首…"
        Task { [weak self] in
            guard let self else { return }
            // 预取可能正在跑：先等它（最多 10 秒），别在"快好了"的时候判死刑
            for _ in 0..<20 {
                if let pick = self.heartbeat.takeNext() {
                    self.isResolving = false
                    self.statusText = nil
                    self.playHeartbeat(pick: pick)
                    return
                }
                if !self.heartbeat.isPlanning { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let pick = await self.heartbeat.planOneNow()
            self.isResolving = false
            if let pick {
                self.statusText = nil
                self.heartbeat.setNotice(nil)
                self.playHeartbeat(pick: pick)
            } else {
                self.fallbackFromQueue()
            }
        }
    }

    /// 心动模式四级梯子全空时的最后一手：**退回队列顺序**，绝不静默停在这里。
    ///
    /// - 队列里还有别的歌 → 按列表循环继续（"先别停"，不是把模式改掉）；
    /// - 队列只有这一首 → 重播这首。
    /// 一首可播的都没有（外面已经连跳 3 次）才会真停。
    private func fallbackFromQueue() {
        guard !queue.isEmpty, let song = currentSong else {
            isPlaying = false
            errorText = "心动模式暂时选不出下一首（没有可用数据与歌源），点播放再试一次。"
            return
        }
        errorText = nil
        if queue.count > 1 {
            heartbeat.setNotice("暂无新歌，先按列表继续")
            goTo((index + 1) % queue.count)
        } else {
            heartbeat.setNotice("暂无新歌，先重播这首")
            heartbeat.trackEnded(listened: duration > 0 ? duration : currentTime, completed: true)
            player.seek(to: .zero)
            player.play()
            isPlaying = true
            currentTime = 0
            heartbeat.trackStarted(song)
            updateNowPlaying()
        }
    }

    /// 「不感兴趣」：这首歌不再出现、同歌手降权，并立刻跳过当前这首。
    func dislikeCurrentSong() {
        guard let song = currentSong else { return }
        heartbeat.dislike(song)
        statusText = "已减少《\(song.name)》这类推荐"
        if mode == .heartbeat { nextTrack() }
    }

    /// 播放列表里点"即将播放"的某一首（心动模式）
    func playUpcoming(id: String) {
        guard let pick = heartbeat.removeUpcoming(id: id) else { return }
        heartbeat.trackEnded(listened: preciseTime, completed: false)
        playHeartbeat(pick: pick)
    }

    /// 连跳上限：第四十轮起不再是设置项，恒为 `PlaybackRules.autoSkipLimit`（3 首）。
    /// 连续 3 首都没源就停下来给一句人话，不把整个队列烧光。
    private var skipLimit: Int { PlaybackRules.autoSkipLimit }

    /// 采纳播放项的时长（只往"更可信"的方向走：有效、且和现有值差 > 0.5 秒）
    private func adoptDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        guard abs(seconds - duration) > 0.5 else { return }
        duration = max(seconds, currentTime)
        refetchLyricsIfDurationChanged()
    }

    /// 真实时长与"取词时用的目标时长"差了 8 秒以上 → 重取一次词（r69）。
    ///
    /// 为什么值一次重取：歌词候选的分数里有"时长差"这一档，差 8 秒足够让排序翻盘
    /// （《发如雪》那次就是元数据 5:00、候选 5:13 的醇享版压过了原版）。
    private func refetchLyricsIfDurationChanged() {
        guard !lyricsRefetched, !isLoadingLyrics, lyricsTargetSec > 0 else { return }
        let actual = Int(duration)
        guard actual > 0, abs(actual - lyricsTargetSec) > 8 else { return }
        guard let song = currentSong else { return }
        lyricsRefetched = true
        lyricsTargetSec = actual
        isLoadingLyrics = true
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(song, audioSec: actual, force: true)
            guard let self else { return }
            guard self.currentSong?.id == song.id else {
                self.isLoadingLyrics = false
                return
            }
            if let result, !result.lines.isEmpty {
                self.adoptLyrics(result, for: song)
                return
            }
            self.isLoadingLyrics = false
        }
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
        advanceAfterFailure()
    }

    private func handleNoSource() {
        if let song = currentSong { deadSongKeys.insert(song.id) }
        consecutiveSkips += 1
        errorText = PlaybackRules.skipMessage(consecutiveSkips, limit: skipLimit)
        isPlaying = false
        if PlaybackRules.shouldStopAfterSkips(consecutiveSkips, limit: skipLimit) { return }
        advanceAfterFailure()
    }

    /// 这首放不出来时往哪走：普通模式按队列规则；心动模式换引擎里的下一首（或现场算）。
    private func advanceAfterFailure() {
        if mode == .heartbeat {
            if let pick = heartbeat.takeNext() {
                playHeartbeat(pick: pick)
            } else {
                planAndPlayHeartbeat()
            }
            return
        }
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
                    // 播放中每 10 秒落一次断点（store 内部还会再夹一次间隔）
                    if self.isPlaying, Int(seconds) % 10 == 0 {
                        self.flushSnapshot()
                    }
                }
                if let item = self.player.currentItem {
                    self.adoptDuration(item.duration.seconds)
                    // 容器/元数据说已经结束，但音频还在走：以实际播放位置为准，
                    // 别让界面停在"剩余 0:00"（老板 r66：明明进度完了还在唱）
                    if self.currentTime > self.duration + 0.5 {
                        self.duration = self.currentTime + 0.5
                    }
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
        durationObservation?.invalidate()
        durationObservation = nil
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
        // 拔耳机 / 断开蓝牙（含下车）：把断点落盘，下次连上从这儿接着放
        flushSnapshot(force: true)
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

    /// 「这份词是怎么选出来的」——候选标题 / 时长 / 各档分数（r69，详情页可见）
    private(set) var lyricsMatchNote: String = ""

    /// 取词时用的"目标时长"（秒）：真实时长远晚于它时才值得重取一次
    private var lyricsTargetSec: Int = 0
    /// 歌空态出来之后的那一次静默重试（换歌时取消）
    private var lyricsRetryTask: Task<Void, Never>?
    /// 这首歌是否已经因为"时长后知后觉"重取过（每首最多一次，避免循环）
    private var lyricsRefetched = false

    /// 切歌时先清空，再异步取词（不阻塞起播：Android 同样是"起播前并发预热歌词"）
    ///
    /// 第五轮（老板反馈 ⑧）：已下载的歌**先读下载时一起存下的本地 LRC**——
    /// 无网络环境（飞机上、地铁里）点开下载好的歌，也要有词可看，不能只剩播放器。
    /// 本地没有才走网络；网络失败时保持空态（播放页有「重试」+ 失败原因）。
    /// 同一首歌的歌词来源变了（酷我 → LDDC → LRCLIB…）→ 把这首的偏移归零。
    ///
    /// 老板 r74 口径：「快一点/慢一点保留，但默认 0、换歌或换歌词来源时归零，只在用户手动调过之后生效」。
    /// 不同来源的时间轴基准本来就不同，沿用上一个来源的偏移只会更不准。
    private var lyricSourceBySong: [String: String] = [:]

    private func adoptLyrics(_ result: LyricsResult?, for song: Song) {
        if let result {
            let previous = lyricSourceBySong[song.id]
            // 只比"来源名"（标签里有耗时，如 `LDDC · 逐字 · 1.8s`，按首个 · 前的前缀比）
            let tag = result.source.split(separator: "·").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? result.source
            if let previous, previous != tag {
                SettingsStore.shared.resetOffset(forSong: song.id)
            }
            lyricSourceBySong[song.id] = tag
        }
        lyrics = result?.lines ?? []
        lyricsSource = result?.source ?? ""
        lyricsMatchNote = result?.matchNote ?? ""
        isLoadingLyrics = false
        // 词被换掉了：旧的"还没唱到的那一行"行号已无意义，按当前位置重新推导
        pendingLyricLine = nil
        updateLyricIndex()
    }

    /// 上一首（用来在换歌时清掉它那次手动调的偏移，老板 r74：「换歌…归零」）
    private var previousLyricSongID: String?

    private func prepareLyrics(for song: Song) {
        if let previous = previousLyricSongID, previous != song.id {
            SettingsStore.shared.resetOffset(forSong: previous)
        }
        previousLyricSongID = song.id
        lyricsRetryTask?.cancel()
        lyricsRetryTask = nil
        lyrics = []
        lyricsSource = ""
        lyricIndex = -1
        lyricScrollIndex = -1
        pendingLyricLine = nil
        lyricsFailure = ""
        lyricsMatchNote = ""
        lyricsRefetched = false
        lyricsTargetSec = duration > 2 ? Int(duration) : song.durationSec

        if let local = DownloadManager.shared.localLyrics(for: song), !local.isEmpty {
            lyrics = local
            lyricsSource = "本地歌词"
            isLoadingLyrics = false
            updateLyricIndex()
            return
        }

        isLoadingLyrics = true
        let targetSec = lyricsTargetSec
        Task { [weak self] in
            let result = await LyricsService.shared.fetch(song, audioSec: targetSec)
            guard let self else { return }
            // 期间可能又切歌了，只有仍停在同一个 ID 才落地
            guard self.currentSong?.id == song.id else { return }
            self.adoptLyrics(result, for: song)
            if result == nil {
                let reason = await LyricsService.shared.failureReason()
                guard self.currentSong?.id == song.id else { return }
                self.lyricsFailure = reason
                self.scheduleLyricsRetry(for: song, targetSec: targetSec)
            }
        }
    }

    /// 空态画出来之后**静默再试一次**（1.5 秒后，仍停在这首、仍然没词才动手）。
    ///
    /// r74 去掉的是"整条链重跑"——那会让一次取词拖到几十秒、还挡着界面。
    /// 这里改在空态已经出现之后补一次：用户看到的是"过一两秒词自己出来了"，
    /// 而第二次也失败也不会让他多等一轮（不占首屏时间）。
    private func scheduleLyricsRetry(for song: Song, targetSec: Int) {
        lyricsRetryTask?.cancel()
        lyricsRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.currentSong?.id == song.id, self.lyrics.isEmpty,
                  !self.isLoadingLyrics else { return }
            self.isLoadingLyrics = true
            let result = await LyricsService.shared.fetch(song, audioSec: targetSec, force: true)
            guard self.currentSong?.id == song.id else {
                self.isLoadingLyrics = false
                return
            }
            if let result, !result.lines.isEmpty {
                self.adoptLyrics(result, for: song)
                self.lyricsFailure = ""
            } else {
                self.isLoadingLyrics = false
            }
        }
    }

    private func updateLyricIndex() {
        let offset = lyricOffsetMs
        let rawMs = Int(preciseTime * 1000)

        // ① 点歌词跳转的"等它唱到"窗口：
        // seek 常落在目标之前几百毫秒，而 `indexAt` 早 1ms 就会推成上一句。
        // 还没走到被点那一行之前，高亮与滚动都钉在那一行；走到了立刻交还给正常推导。
        // 用**播放头真实位置**判断"唱到了没有"，所以与歌曲无关。
        if let pending = pendingLyricLine {
            guard lyrics.indices.contains(pending) else {
                pendingLyricLine = nil
                // 歌词换了（重取/换歌），继续走正常推导
                return finishLyricIndex(position: rawMs + offset)
            }
            let decision = LyricsCleaning.lyricSeekHoldDecision(
                positionMs: rawMs + offset,
                lineMs: lyrics[pending].timeMs,
                toleranceMs: LyricsUXRules.lyricSeekHoldToleranceMs)
            if decision == .hold {
                if lyricIndex != pending { lyricIndex = pending }
                if lyricScrollIndex != pending { lyricScrollIndex = pending }
                return
            }
            pendingLyricLine = nil
        }

        // ② seek 之后的时钟（进度条拖动也走这条）：窗口内用目标位置，落地或 1.5 秒后
        //    用播放头真实位置。**永远给出一个位置**——旧实现会 return（=冻住），
        //    一旦 completion 不回来就冻 10 秒，正是老板说的"一跳就瞬间对不上"。
        var effectiveMs = rawMs
        if let optimistic = seekOptimistic {
            let source = LyricsUXRules.seekClockSource(
                positionMs: rawMs,
                targetMs: optimistic.targetMs,
                optimisticExpired: Date() >= optimistic.until)
            if source == .useTarget {
                effectiveMs = optimistic.targetMs
            } else {
                seekOptimistic = nil
            }
        }

        finishLyricIndex(position: effectiveMs + offset)
    }

    /// 正常推导：高亮与滚动走同一份位置，保证"亮的行"和"滚到中间的行"不打架
    private func finishLyricIndex(position: Int) {
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
