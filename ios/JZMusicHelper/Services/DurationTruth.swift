//  真实时长（2026-11-24）
//
//  老板：「进度条拖到哪就该从哪放，这是最基础的功能」。而总长有三个假来源：
//    · 接口时长（歌单元数据，可能和文件差几十秒）
//    · FLAC/MP3 容器里声明的长度（《不凡2024》声明 4:12、实际 4:47；《半岛铁盒》5:19/5:32）
//    · 我们以前自己标定的数（也是从头里读的，一样假）
//  唯一真值是**解码到 EOF 数出来的帧数**；再拿「真播到结尾时播放头停在哪」交叉校验。
//
//  设计三条硬规矩：
//    1. 一个文件只量一次（缓存键 = 路径 + 大小 + 修改时间，文件一变自动失效）；
//    2. 量的时候不阻塞起播（后台跑），但**拖动落点必须用已确认的值**；
//    3. 播放到真结尾时永远以「播放头停的位置」为准 —— 就算哪天解码也骗人，
//       听一遍之后就再也不会错（这条是"以后不会出错"的兜底）。

import AVFoundation
import Foundation

/// 一首歌的时长事实：值 + 来源 + 是否已由两个以上来源确认
struct DurationFact: Codable, Equatable {
    var seconds: Double
    /// "decode" = 解码到 EOF；"playback" = 播到真结尾时播放头的位置
    var source: String
    /// 两个来源对得上（或播放实测确认过）才算 confirmed
    var confirmed: Bool
    var at: Date
}

/// 时长的事实库（一个 json，按文件指纹索引）
@MainActor
final class DurationTruthStore {
    static let shared = DurationTruthStore()

    private var facts: [String: DurationFact] = [:]
    private var loaded = false
    private var dirty = false
    private var flushTask: Task<Void, Never>?

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DurationTruth.json")
    }

    /// 缓存键：路径 + 大小 + 修改时间（毫秒）。文件被重下/写回标签/合并，键就变了 → 自动重测。
    nonisolated static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64(((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        return "\(path)|\(size)|\(mtime)"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: DurationFact].self, from: data)
        else { return }
        facts = decoded
    }

    func fact(for url: URL) -> DurationFact? {
        loadIfNeeded()
        return facts[Self.key(for: url)]
    }

    /// 记一条事实。`confirmed` 由调用方给（解码+播放一致 / 播放实测）。
    func store(url: URL, seconds: Double, source: String, confirmed: Bool) {
        guard seconds.isFinite, seconds > 1 else { return }
        loadIfNeeded()
        let k = Self.key(for: url)
        if let old = facts[k], abs(old.seconds - seconds) <= 1, old.confirmed == confirmed {
            return
        }
        facts[k] = DurationFact(seconds: seconds, source: source, confirmed: confirmed, at: Date())
        dirty = true
        scheduleFlush()
    }

    /// 播放到真结尾：这个数是**耳朵听到的**，永远优先。差 >1 秒就覆盖。
    func recordPlaybackEnd(url: URL, seconds: Double) {
        guard seconds.isFinite, seconds > 5 else { return }
        loadIfNeeded()
        let k = Self.key(for: url)
        if let old = facts[k], abs(old.seconds - seconds) <= 1 {
            // 和解码值一致 → 从此就是"已确认"
            if !old.confirmed { facts[k]?.confirmed = true; dirty = true; scheduleFlush() }
            return
        }
        facts[k] = DurationFact(seconds: seconds, source: "playback", confirmed: true, at: Date())
        dirty = true
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard dirty else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushNow()
        }
    }

    func flushNow() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(facts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 诊断用：库里一共多少条、其中已确认多少条
    var stats: (total: Int, confirmed: Int) {
        loadIfNeeded()
        return (facts.count, facts.values.filter { $0.confirmed }.count)
    }
}

// MARK: - 解码量真长（唯一真值的来源）

enum TrueDuration {
    /// 解码到 EOF，数出真实帧数 ÷ 采样率。只读文件，不改任何字节。
    ///
    /// 为什么不用 `AVAudioFile.length`：那也是 STREAMINFO 里的 total_samples，头写错它跟着错。
    /// 每块 1<<18 帧（约 6 秒 @44.1k），一首 5 分钟的歌约 50 次 read。
    static func decodedSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(1 << 18))
        else { return nil }
        var total: AVAudioFramePosition = 0
        while true {
            do { try file.read(into: buffer) } catch { break }
            if buffer.frameLength == 0 { break }
            total += AVAudioFramePosition(buffer.frameLength)
        }
        guard total > 0 else { return nil }
        return Double(total) / rate
    }
}
