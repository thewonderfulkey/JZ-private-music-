import AVFoundation
import MediaPlayer
import Observation

// MARK: - 助眠多轨播放器（v2：声音按 URL 取，不打包）
//
// 和「放歌」完全分开：`PlayerEngine`（AVPlayer，单实例）只管歌，
// 这里用 `AVAudioEngine` + 每层一个 `AVAudioPlayerNode`，负责 **多层叠加、每层独立音量、
// 整夜无缝循环、定时淡出**。
//
// 三条关键设计（第一条是 v2.4.102 闪退的教训）：
//
// 1) **图先建好、再 start。** 上一版是「先 engine.start() 再 connect + 首次访问 mainMixerNode」，
//    CoreAudio 在运行中的引擎上首次接线会抛 **ObjC 异常**，Swift 的 try/catch 接不住 → 秒闪。
//    现在 init 里就把 mainMixerNode 拆出来（output 链先成型），每个节点也是「先 connect 再 start」。
//
// 2) **音频按 URL 取，但落进缓存目录再播。**
//    纯流式循环会每圈重新请求一次（2 分钟 3 MB 的文件，8 层开一夜 ≈ 5 GB 流量）。
//    这里第一次拉下来就存 `Caches/SleepSounds/<id>.mp3`，之后全部走本地文件；缓存上限 200 MB，LRU 清理。
//
// 3) **无缝循环靠"两份 AVAudioFile 交替排队"，不靠 numberOfLoops。**
//    压缩格式 loop 那一下有编码器 padding 的缝，五分钟一次、一夜几百次很致命。
//    每层开两个读指针（同一个 URL、各自独立），永远提前排好两份——队列里始终有整段余量。
@MainActor
@Observable
final class SleepAudioEngine {

    static let shared = SleepAudioEngine()

    // MARK: 对外状态

    private(set) var activeIDs: [String] = []
    private(set) var levels: [String: Float] = [:]
    private(set) var isPlaying = false
    private(set) var timerEndsAt: Date?
    private(set) var timerSelection: SleepTimerMinutes?
    /// 正在下载/准备的那几层（UI 上显示转圈）
    private(set) var preparing: Set<String> = []
    /// 定时到点停过：保留层记忆，点一下原样回来
    private(set) var stoppedByTimer = false
    /// 最近一次出错（给 UI 提示用）
    private(set) var lastError: String?

    private var errorTask: Task<Void, Never>?

    func clearError() { lastError = nil }

    private func setError(_ text: String) {
        lastError = text
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lastError = nil }
        }
    }

    /// 助眠是否正在占用音频会话——`NowPlayingCenter` 用它决定要不要让路
    var isSleeping: Bool { sessionActive }

    var summary: String {
        activeIDs.compactMap { SleepSound.find($0)?.name }.joined(separator: " + ")
    }

    // MARK: 内部

    private final class Layer {
        let sound: SleepSound
        let node = AVAudioPlayerNode()
        var files: [AVAudioFile] = []
        var cursor = 0
        var envelope: Float = 0
        var connected = false
        var queued = false

        init(_ s: SleepSound) { self.sound = s }
    }

    private let engine = AVAudioEngine()
    private var layers: [String: Layer] = [:]
    private var engineRunning = false
    private var sessionActive = false
    private var master: Float = 1
    private var ticker: Timer?
    private var timerTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var observersWired = false

    private init() {
        for s in SleepSound.all { levels[s.id] = 0.7 }
        // 关键：先把 output 链建出来（mainMixerNode 一旦被访问就自动接到 outputNode），
        // 之后的 attach/connect 都是在"已经有一条合法链路"的图上做，避免运行中首次成形。
        _ = engine.mainMixerNode
    }

    // MARK: - 开关

    func toggle(_ id: String) {
        if stoppedByTimer && !isPlaying { resume(); return }
        if activeIDs.contains(id) { switchOff(id) } else { switchOn(id) }
    }

    func switchOn(_ id: String) {
        guard let sound = SleepSound.find(id) else { return }
        if !activeIDs.contains(id) { activeIDs.append(id) }
        stoppedByTimer = false
        isPlaying = true
        master = 1
        startTicker()
        applyVolumes()
        publishNowPlaying()

        if layers[id]?.connected == true {
            // 已经准备好了，直接拉起
            if let layer = layers[id] {
                if !layer.queued { schedule(layer) }
                layer.node.play()
            }
            return
        }
        guard preparing.contains(id) == false else { return }
        preparing.insert(id)
        Task { await prepareAndStart(sound) }
    }

    /// 下载（或读缓存）→ 建节点 → 接线 → 起引擎 → 排两份 → play
    private func prepareAndStart(_ sound: SleepSound) async {
        defer { preparing.remove(sound.id) }
        do {
            let url = try await SleepLibrary.shared.playableFile(for: sound)
            guard let layer = makeLayer(sound, url: url) else { return }
            connect(layer)                       // ① 先接线
            ensureEngine()                       // ② 再启动引擎
            guard activeIDs.contains(sound.id) else {   // 期间被关掉了
                disconnect(layer)
                return
            }
            schedule(layer)
            schedule(layer)
            layer.node.play()
            applyVolumes()
        } catch {
            setError("「\(sound.name)」没准备好：\(error.localizedDescription)")
            activeIDs.removeAll { $0 == sound.id }
            if activeIDs.isEmpty { isPlaying = false }
        }
    }

    func switchOff(_ id: String) {
        guard layers[id] != nil || activeIDs.contains(id) else { return }
        activeIDs.removeAll { $0 == id }
        startTicker()
        publishNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        for l in layers.values { l.node.pause() }
        publishNowPlaying()
    }

    func resume() {
        guard !activeIDs.isEmpty else { return }
        ensureEngine()
        for id in activeIDs {
            guard let l = layers[id] else {
                // 还没准备好的层：重新走一遍准备流程
                if let s = SleepSound.find(id), !preparing.contains(id) {
                    preparing.insert(id)
                    Task { await prepareAndStart(s) }
                }
                continue
            }
            if !l.queued { schedule(l); schedule(l) }
            l.node.play()
        }
        isPlaying = true
        stoppedByTimer = false
        master = 1
        startTicker()
        applyVolumes()
        publishNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    // MARK: - 音量

    func setLevel(_ v: Float, for id: String) {
        levels[id] = min(max(v, 0), 1)
        applyVolumes()
    }

    func level(for id: String) -> Float { levels[id] ?? 0.7 }

    /// 套用整段预设：先把别的关掉，再按混音打开
    func apply(_ preset: SleepPreset) {
        for id in activeIDs where !preset.mix.contains(where: { $0.0 == id }) {
            activeIDs.removeAll { $0 == id }
        }
        for (id, v) in preset.mix {
            levels[id] = v
            if !activeIDs.contains(id) { switchOn(id) } else { applyVolumes() }
        }
        for id in activeIDs where !preset.mix.contains(where: { $0.0 == id }) {
            if let l = layers[id] { l.node.stop(); l.envelope = 0 }
        }
    }

    // MARK: - 定时

    func startTimer(_ minutes: SleepTimerMinutes) {
        timerTask?.cancel()
        timerSelection = minutes
        timerEndsAt = Date().addingTimeInterval(TimeInterval(minutes.rawValue * 60))
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes.rawValue) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.beginTimerFadeOut() }
        }
    }

    func cancelTimer() {
        timerTask?.cancel(); timerTask = nil
        fadeTask?.cancel(); fadeTask = nil
        timerEndsAt = nil
        timerSelection = nil
        master = 1
        applyVolumes()
    }

    private func beginTimerFadeOut() {
        timerEndsAt = nil
        timerSelection = nil
        guard isPlaying else { return }
        let steps = Int(SleepTimerMinutes.fadeOutSeconds * 10)
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            for i in 1...max(steps, 1) {
                guard !Task.isCancelled else { return }
                master = 1 - Float(i) / Float(steps)
                applyVolumes()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            finishTimerStop()
        }
    }

    /// 定时到点：静音收工，但**保留开着哪几层和各自音量**
    private func finishTimerStop() {
        ticker?.invalidate(); ticker = nil
        for l in layers.values {
            l.node.stop(); l.envelope = 0; l.queued = false
        }
        isPlaying = false
        master = 1
        applyVolumes()
        stopEngine()
        deactivateSession()
        clearNowPlaying()
        stoppedByTimer = true
    }

    // MARK: - 全停

    func stopAll() {
        timerTask?.cancel(); timerTask = nil
        fadeTask?.cancel(); fadeTask = nil
        timerEndsAt = nil; timerSelection = nil
        ticker?.invalidate(); ticker = nil
        for l in layers.values { l.node.stop(); l.envelope = 0; l.queued = false }
        activeIDs.removeAll()
        isPlaying = false
        stoppedByTimer = false
        master = 1
        stopEngine()
        deactivateSession()
        clearNowPlaying()
    }

    // MARK: - 引擎装配

    private func makeLayer(_ sound: SleepSound, url: URL) -> Layer? {
        if let l = layers[sound.id], l.connected { return l }
        let l = Layer(sound)
        do {
            l.files = [try AVAudioFile(forReading: url), try AVAudioFile(forReading: url)]
        } catch {
            setError("「\(sound.name)」打不开：\(error.localizedDescription)")
            return nil
        }
        engine.attach(l.node)
        layers[sound.id] = l
        return l
    }

    private func connect(_ l: Layer) {
        guard !l.connected, let fmt = l.files.first?.processingFormat else { return }
        engine.connect(l.node, to: engine.mainMixerNode, format: fmt)
        l.connected = true
    }

    private func disconnect(_ l: Layer) {
        guard l.connected else { return }
        l.node.stop()
        engine.disconnectNodeOutput(l.node)
        engine.detach(l.node)
        l.connected = false
        l.queued = false
        layers.removeValue(forKey: l.sound.id)
    }

    private func ensureEngine() {
        activateSession()
        guard !engineRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            engineRunning = true
        } catch {
            setError("音频引擎起不来：\(error.localizedDescription)")
        }
        wireObserversIfNeeded()
    }

    private func stopEngine() {
        guard engineRunning else { return }
        engine.stop()
        engineRunning = false
    }

    private func schedule(_ l: Layer) {
        guard l.files.count == 2 else { return }
        let f = l.files[l.cursor]
        l.cursor = (l.cursor + 1) % 2
        f.framePosition = 0
        l.queued = true
        l.node.scheduleFile(f, at: nil) { [weak self, weak l] in
            guard let l else { return }
            Task { @MainActor in
                guard let self, self.layers[l.sound.id] === l else { return }
                guard self.activeIDs.contains(l.sound.id), l.envelope > 0.001 else { return }
                self.schedule(l)
            }
        }
    }

    // MARK: - 包络（30 Hz）

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        var moving = false
        let step: Float = 1.0 / 15.0
        for (id, l) in layers {
            let want: Float = activeIDs.contains(id) ? 1 : 0
            if l.envelope < want {
                l.envelope = min(l.envelope + step, want); moving = true
            } else if l.envelope > want {
                l.envelope = max(l.envelope - step, want); moving = true
            }
            if want == 0 && l.envelope <= 0.0005 {
                l.envelope = 0
                if l.node.isPlaying { l.node.stop() }
                l.queued = false
            }
        }
        applyVolumes()
        if !moving && activeIDs.isEmpty {
            ticker?.invalidate(); ticker = nil
            if isPlaying { isPlaying = false; publishNowPlaying() }
            stopEngine()
            deactivateSession()
            clearNowPlaying()
        }
    }

    private func applyVolumes() {
        // 层数越多越往下让：叠加时整体响度大致不变，也不会在 6~8 层时顶爆
        let trim: Float = 1.0 / Float(max(1.0, Double(max(activeIDs.count, 1)).squareRoot()))
        for (id, l) in layers {
            let lv = levels[id] ?? 0.7
            l.node.volume = max(0, min(1, l.envelope * lv * master * trim))
        }
    }

    // MARK: - 会话 / 中断

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
                case .began: self.pause()
                case .ended:
                    let o = AVAudioSession.InterruptionOptions(
                        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    if o.contains(.shouldResume) { self.resume() }
                @unknown default: break
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

    // MARK: - 锁屏

    private func publishNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "助眠模式",
            MPMediaItemPropertyArtist: activeIDs.isEmpty ? "未选择声音" : summary,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        info[MPMediaItemPropertyAlbumTitle] = timerEndsAt == nil ? "整夜循环" : "定时中"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
