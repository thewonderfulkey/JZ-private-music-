import AVFoundation
import MediaPlayer
import Observation

// MARK: - 助眠多轨播放器
//
// 和「放歌」完全分开的一套引擎：`PlayerEngine`（AVPlayer，单实例）只管歌，
// 这里用 `AVAudioEngine` + 每层一个 `AVAudioPlayerNode`，负责 **8 层任意叠加、
// 每层独立音量、整夜无缝循环、定时淡出**。
//
// 三条关键设计：
//
// 1) **无缝循环靠"两份文件交替排队"，不靠 `AVAudioPlayer.numberOfLoops`。**
//    压缩格式循环那一下会有编码器 padding 造成的缝隙，五分钟一次、一夜几百次很致命。
//    这里给每层开两个 `AVAudioFile`（同一个 URL，各自独立的读指针），永远提前排好两份，
//    播完一份就在回调里补一份——队列里始终有 300 秒余量，回调晚几秒也不会断。
//
// 2) **淡入淡出全部走 `node.volume` 的 30 Hz 包络，不碰引擎的 start/stop。**
//    引擎一停一启会有一次硬件重配，夜里能听到"咔"；只改音量最平滑。
//
// 3) **音频会话只在第一次真正播放时激活**，退出助眠页不主动关——用户可能只是切去别的页。
//    真正释放发生在 `stopAll()`（定时到点 / 手动全停）。
@MainActor
@Observable
final class SleepAudioEngine {

    static let shared = SleepAudioEngine()

    // MARK: 对外状态

    /// 当前开着的层（顺序 = 打开顺序）
    private(set) var activeIDs: [String] = []
    /// 每层的用户音量 0...1（默认 0.7）
    private(set) var levels: [String: Float] = [:]
    /// 总开关：有层在响就是 true
    private(set) var isPlaying = false
    /// 定时关闭：到点时间（nil = 没开）
    private(set) var timerEndsAt: Date?
    /// 定时关闭：当前选中的档位（nil = 没开）
    private(set) var timerSelection: SleepTimerMinutes?
    /// 上一次是"被定时关掉的"——底部条据此提示"点播放就原样回来"
    private(set) var stoppedByTimer = false

    /// 助眠是否正在占用音频会话——`NowPlayingCenter` 用它决定要不要让路。
    /// 注意这里看的是**会话**不是"选了几层"：定时关掉之后会话要还回去，
    /// 否则锁屏卡会永远停在助眠上。
    var isSleeping: Bool { sessionActive }

    // MARK: 私有

    private final class Track {
        let sound: SleepSound
        let node = AVAudioPlayerNode()
        var files: [AVAudioFile] = []
        var cursor = 0
        /// 淡入淡出包络 0...1
        var envelope: Float = 0
        var connected = false
        /// 队列里是否还压着音频（stop() 之后要重新排，pause() 之后不用）
        var queued = false

        init(_ sound: SleepSound) { self.sound = sound }
    }

    private let engine = AVAudioEngine()
    private var tracks: [String: Track] = [:]
    private var engineStarted = false
    private var sessionActive = false
    private var masterGain: Float = 1
    private var ticker: Timer?
    private var timerTask: Task<Void, Never>?
    /// 到点后那段 30 秒淡出的任务（中途取消定时要能掐掉）
    private var fadeTask: Task<Void, Never>?
    private var observersWired = false

    private init() {
        for s in SleepSound.all { levels[s.id] = 0.7 }
    }

    // MARK: - 层开关

    func toggle(_ id: String) {
        // 定时到点停过之后，点任意一层 = "原样恢复"（老板口径）。
        // 这一状态下想单独关掉某层，走长按弹出的音量面板。
        if stoppedByTimer && !isPlaying {
            resume()
            return
        }
        if activeIDs.contains(id) {
            switchOff(id)
        } else {
            switchOn(id)
        }
    }

    func switchOn(_ id: String) {
        guard let sound = SleepSound.find(id) else { return }
        guard let track = makeTrackIfNeeded(sound) else { return }
        if !activeIDs.contains(id) { activeIDs.append(id) }
        startEngineIfNeeded()
        if !track.connected { connect(track) }
        // 已经排空（上一轮停过）就重新排两份
        if track.envelope <= 0.001 {
            reschedule(track)
            track.node.play()
        }
        masterGain = 1
        isPlaying = true
        stoppedByTimer = false
        startTicker()
        applyVolumes()
        publishNowPlaying()
    }

    func switchOff(_ id: String) {
        guard tracks[id] != nil else { return }
        activeIDs.removeAll { $0 == id }
        // 包络降到 0 由 ticker 收尾（停 node、全关后放掉会话）
        startTicker()
        publishNowPlaying()
    }

    /// 总暂停：所有层一起停（保留"开着哪几层"的记忆，恢复时原样回来）
    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        for t in tracks.values { t.node.pause() }
        publishNowPlaying()
    }

    func resume() {
        guard !activeIDs.isEmpty else { return }
        startEngineIfNeeded()
        for id in activeIDs {
            guard let t = tracks[id] else { continue }
            if !t.connected { connect(t) }
            // 被定时关掉过 → 队列已经被 stop() 冲掉了，要重排；
            // 只是手动暂停 → 队列还在（5 分钟余量），直接接着放。
            if !t.queued { reschedule(t) }
            t.node.play()
        }
        isPlaying = true
        stoppedByTimer = false
        masterGain = 1
        startTicker()
        applyVolumes()
        publishNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    // MARK: - 每层音量

    func setLevel(_ v: Float, for id: String) {
        levels[id] = min(max(v, 0), 1)
        applyVolumes()
    }

    func level(for id: String) -> Float { levels[id] ?? 0.7 }

    // MARK: - 定时关闭

    func startTimer(_ minutes: SleepTimerMinutes) {
        timerTask?.cancel()
        timerSelection = minutes
        let deadline = Date().addingTimeInterval(TimeInterval(minutes.rawValue * 60))
        timerEndsAt = deadline
        timerTask = Task { [weak self] in
            let seconds = TimeInterval(minutes.rawValue * 60)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.beginTimerFadeOut() }
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
        fadeTask?.cancel()
        timerTask = nil
        timerEndsAt = nil
        timerSelection = nil
        // 已经淡到一半的话，拉回来
        if isPlaying {
            masterGain = 1
            applyVolumes()
        }
    }

    /// 到点：30 秒线性淡出，然后全停
    private func beginTimerFadeOut() {
        timerEndsAt = nil
        timerSelection = nil
        guard isPlaying else { return }
        startTicker()
        let seconds = SleepTimerMinutes.fadeOutSeconds
        // 用一个独立的收尾任务按 30 Hz 把 masterGain 推到 0
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            let steps = Int(seconds * 30)
            for i in 1...max(steps, 1) {
                guard !Task.isCancelled else { return }
                masterGain = 1 - Float(i) / Float(steps)
                applyVolumes()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            guard !Task.isCancelled else { return }
            finishTimerStop()
        }
    }

    /// 定时到点：淡完就静音收工，但**保留"开着哪几层"和各自音量**——
    /// 下次点一下播放（或明晚再进助眠页）原样回来。老板口径。
    private func finishTimerStop() {
        ticker?.invalidate()
        ticker = nil
        for t in tracks.values {
            t.node.stop()
            t.envelope = 0
            t.queued = false
        }
        isPlaying = false
        masterGain = 1
        applyVolumes()
        if engineStarted {
            engine.stop()
            engineStarted = false
        }
        deactivateSession()
        clearNowPlaying()
        stoppedByTimer = true
    }

    // MARK: - 全停

    /// 立即（或很快）把一切收干净：层全关、引擎停、会话释放、锁屏卡清掉。
    func stopAll() {
        timerTask?.cancel()
        fadeTask?.cancel()
        timerTask = nil
        timerEndsAt = nil
        timerSelection = nil
        ticker?.invalidate()
        ticker = nil
        for t in tracks.values {
            t.node.stop()
            t.envelope = 0
            t.queued = false
        }
        activeIDs.removeAll()
        isPlaying = false
        stoppedByTimer = false
        masterGain = 1
        if engineStarted {
            engine.stop()
            engineStarted = false
        }
        deactivateSession()
        clearNowPlaying()
    }

    /// 正在播的层名（给锁屏卡和底部条用）
    var summary: String {
        activeIDs.compactMap { SleepSound.find($0)?.name }.joined(separator: " + ")
    }

    // MARK: - 引擎装配

    private func makeTrackIfNeeded(_ sound: SleepSound) -> Track? {
        if let t = tracks[sound.id] { return t }
        guard let url = sound.fileURL else {
            #if DEBUG
            print("[Sleep] 缺少素材：\(sound.id).m4a")
            #endif
            return nil
        }
        let t = Track(sound)
        do {
            // 两份独立读指针，交替排队 → 无缝
            t.files = [try AVAudioFile(forReading: url), try AVAudioFile(forReading: url)]
        } catch {
            #if DEBUG
            print("[Sleep] 打不开素材 \(sound.id)：\(error)")
            #endif
            return nil
        }
        engine.attach(t.node)
        tracks[sound.id] = t
        return t
    }

    private func connect(_ t: Track) {
        guard let fmt = t.files.first?.processingFormat else { return }
        engine.connect(t.node, to: engine.mainMixerNode, format: fmt)
        t.connected = true
    }

    private func startEngineIfNeeded() {
        activateSession()
        if !engineStarted {
            engine.prepare()
            do {
                try engine.start()
                engineStarted = true
            } catch {
                #if DEBUG
                print("[Sleep] 引擎启动失败：\(error)")
                #endif
            }
        }
        wireObserversIfNeeded()
    }

    /// 排两份，之后每播完一份补一份
    private func reschedule(_ t: Track) {
        t.cursor = 0
        t.queued = false
        scheduleTail(t)
        scheduleTail(t)
    }

    private func scheduleTail(_ t: Track) {
        guard t.files.count == 2 else { return }
        let f = t.files[t.cursor]
        t.cursor = (t.cursor + 1) % 2
        f.framePosition = 0
        t.queued = true
        t.node.scheduleFile(f, at: nil) { [weak self, weak t] in
            guard let t else { return }
            Task { @MainActor in
                guard let self, self.tracks[t.sound.id] === t else { return }
                // 只有还开着、还在播才继续补，否则让队列自然排空
                guard self.activeIDs.contains(t.sound.id), t.envelope > 0.001 else { return }
                self.scheduleTail(t)
            }
        }
    }

    // MARK: - 包络（30 Hz）

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        var moving = false
        let step: Float = 1.0 / 15.0          // 30 Hz × 0.5 s = 15 拍淡完
        for (id, t) in tracks {
            let want: Float = activeIDs.contains(id) ? 1 : 0
            if t.envelope < want {
                t.envelope = min(t.envelope + step, want)
                moving = true
            } else if t.envelope > want {
                t.envelope = max(t.envelope - step, want)
                moving = true
            }
            if want == 0 && t.envelope <= 0.0005 {
                t.envelope = 0
                if t.node.isPlaying { t.node.stop() }
            }
        }
        applyVolumes()
        // 全部淡完、又没在等定时 → 收工（放掉音频会话和锁屏卡）
        if !moving && activeIDs.isEmpty {
            ticker?.invalidate()
            ticker = nil
            if isPlaying {
                isPlaying = false
                publishNowPlaying()
            }
            shutDownEngine()
        }
    }

    private func applyVolumes() {
        // 层数越多越往下让：叠加时整体响度大致不变，也不会在 6~8 层时顶爆输出。
        // 这是混音台常见的"恒定响度"做法，不是压缩——单层的动态一点没动。
        let trim: Float = 1.0 / Float(max(1.0, Double(activeIDs.count).squareRoot()))
        for (id, t) in tracks {
            let lv = levels[id] ?? 0.7
            t.node.volume = max(0, min(1, t.envelope * lv * masterGain * trim))
        }
    }

    /// 层全淡完了：停引擎、放会话、清锁屏卡（下次点亮会重新起）
    private func shutDownEngine() {
        if engineStarted {
            engine.stop()
            engineStarted = false
        }
        for t in tracks.values {
            t.envelope = 0
            t.node.stop()
        }
        deactivateSession()
        clearNowPlaying()
    }

    // MARK: - 音频会话 / 中断

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
        sessionActive = true
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    private func wireObserversIfNeeded() {
        guard !observersWired else { return }
        observersWired = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self, self.isSleeping else { return }
                switch type {
                case .began:
                    self.pause()
                case .ended:
                    let o = AVAudioSession.InterruptionOptions(
                        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    if o.contains(.shouldResume) { self.resume() }
                @unknown default:
                    break
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                guard let self, self.isSleeping else { return }
                self.pause()
            }
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func publishNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "助眠模式",
            MPMediaItemPropertyArtist: activeIDs.isEmpty ? "未选择声音" : summary,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyComments: "睡眠环境音",
        ]
        if let ends = timerEndsAt {
            info[MPMediaItemPropertyAlbumTitle] = "\(Int(ends.timeIntervalSinceNow / 60)) 分钟后关闭"
        } else {
            info[MPMediaItemPropertyAlbumTitle] = "整夜循环"
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

