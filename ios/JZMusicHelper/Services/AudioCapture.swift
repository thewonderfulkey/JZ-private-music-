import AVFoundation
import Foundation

// MARK: - 识曲的麦克风采集
//
// 与 Android `VoiceCapture.kt` 同口径：**从设备原生采样率采**，再降到 8kHz / 单声道 / 16bit 小端。
// 为什么不像 Android 早期那样直接按 8k 采：不少机型的 HAL 对 8k 是"接受但不给数据"，
// 采到一段"合法的静音"，然后一直提示"没听到声音"。iOS 这边原生 48k 采、AVAudioConverter 降采样，
// 信噪比更好，也避开这个坑。
//
// 整段 PCM 只留在内存里：不落盘、不进缓存、不上传（除了送给识曲接口的那一份）。
final class AudioCapture {

    /// 识曲接口要求的采样率（酷狗 / 网易共用）
    static let targetRate: Double = 8_000

    enum CaptureError: LocalizedError {
        case noInput
        case converterFailed(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "拿不到麦克风输入通道"
            case .converterFailed(let m): return "音频转换器创建失败：\(m)"
            case .engineFailed(let m): return "麦克风启动失败：\(m)"
            }
        }
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var pcm = Data()
    private var peak: Float = 0

    private(set) var isRunning = false

    /// 实时电平（0…1，RMS）：界面的呼吸圈用它
    var onLevel: ((Float) -> Void)?

    // MARK: 权限

    /// iOS 17 起麦克风权限走 `AVAudioApplication`（`AVAudioSession.requestRecordPermission` 已废弃）
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: 采集

    func start() throws {
        discardInput()
        let session = AVAudioSession.sharedInstance()
        // 用 measure 模式：关掉大部分 AGC/降噪，音乐不会被削平（Android 那边选 VOICE_RECOGNITION 是同一目的）
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: [])

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Self.targetRate,
                                               channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.converterFailed("\(inputFormat.sampleRate)Hz → 8000Hz")
        }

        self.converter = converter
        self.outFormat = outputFormat
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        peak = 0
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        isRunning = true
    }

    /// 取当前已采到的 PCM 快照（不打断采集）："先问一次酷狗"用
    func snapshot() -> (pcm: Data, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (pcm, peak)
    }

    /// 停止采集并把音频会话还给播放（否则识别完播放没声音）
    ///
    /// 只有在**真的在录**的时候才动音频会话：没在录却 setActive(false) 会把正在播放的歌掐断
    /// （老板反馈「切个 Tab 歌就停了」就是这条路径：识曲页 onDisappear → cancel → 这里）。
    @discardableResult
    func stop() -> (pcm: Data, peak: Float) {
        let wasRunning = isRunning
        if wasRunning, let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
        isRunning = false
        let result = snapshot()
        discardInput()
        if wasRunning { restorePlaybackSession() }
        return result
    }

    func cancel() {
        _ = stop()
    }

    // MARK: 内部

    private func discardInput() {
        converter = nil
        outFormat = nil
        lock.lock()
        pcm.removeAll(keepingCapacity: false)
        peak = 0
        lock.unlock()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outFormat else { return }
        let ratio = Self.targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }

        let frames = Int(out.frameLength)
        let chunk = Data(bytes: samples[0], count: frames * 2)

        var sum: Double = 0
        var localPeak: Float = 0
        for i in 0..<frames {
            let value = Float(samples[0][i]) / 32768
            sum += Double(value * value)
            localPeak = max(localPeak, abs(value))
        }
        let rms = frames > 0 ? Float((sum / Double(frames)).squareRoot()) : 0

        lock.lock()
        pcm.append(chunk)
        peak = max(peak, localPeak)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(rms)
        }
    }

    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        // 注意：这里**不能**先 setActive(false, .notifyOthersOnDeactivation)。
        // 那一下会把"当前正在播但已暂停"的音频会话整个掐掉，等再 setActive(true) 时
        // AVPlayer 不会自己恢复——用户看到的就是"切个 Tab/识个曲，歌停了"。
        // 只要把类别切回 playback 并确保会话是激活的，下一次 play 就能出声。
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])
    }
}
