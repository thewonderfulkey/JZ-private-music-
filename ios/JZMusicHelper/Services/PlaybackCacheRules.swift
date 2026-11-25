import Foundation

// MARK: - 播放缓存（2026-11-25）
//
// 老板口径（这一轮定的）：
//   · 取到流就**整首落盘**，边落边播（播放器要字节就向我们要，见 `PlaybackCache`）；
//   · 断流/403 时换一条新 token **续写同一个文件**，播放器只感觉读得慢，不报错、不重载；
//   · 新 token 拿到的如果不是同一份文件（总长/首段指纹不一致）→ 换下一条，全都对不上就停，
//     不播错的、也不从 0 重播；
//   · 再播这一首优先用本地缓存；缓存上限按"首数"配置（设置页），超出按最近播放淘汰。
//
// 这里只放**不依赖 AVFoundation 的纯判定**，CI 的 logic-tests 直接断言。
enum PlaybackCacheRules {

    /// 总开关：真机上要是出现异常，把这里改 false 就退回"边下边播"的老路（一行回滚）
    static let enabled = true

    /// 设置项的键与范围（与 `SettingsStore.playbackCacheLimit` 共用）
    static let key = "playback_cache_limit"
    static let defaultLimit = 50
    static let minLimit = 5
    static let maxLimit = 300

    /// 参照时长的允许误差：**1.5 秒**（2026-11-25《众》播成《侧脸》之后收紧）。
    ///
    /// 演变：±25 秒 → ±5 秒 → ±1.5 秒。为什么必须再收：
    /// 《众》215.5s 被换成了《侧脸》217.89s，差 2.39 秒——±5 秒的闸门**放它过去了**，
    /// 于是"文件长度"这一条最后防线也没拦住。同一平台同一条母带的长度差通常 <0.5 秒，
    /// 跨平台翻录 ≤1.5 秒，1.5 秒是既能拦住 2.4 秒的错歌、又不误杀正常翻录的位置。
    static let durationToleranceSec: Double = 1.5

    /// 超过这个差值就**判定不是同一份文件**（触发换源；全都不符就停下，不播错的）。
    ///
    /// 1.5–2.0 秒之间算"未核实"：允许播，但不显示百分比、不判播完（`durationVerified=false`）。
    /// 这段灰区留给"母带尾部静音差异"这类真实存在的情况；2.0 秒以上一律不认。
    static let durationMismatchSec: Double = 2.0

    /// 缓存条目复核用的容差（比闸门更严：条目里存了"写的时候是哪条候选"）
    static let cacheDurationToleranceSec: Double = 1.5

    /// 一首 320k / 4 分钟的歌大约这么大，只用于设置页显示"约 XX MB"
    static let averageSongBytes: Int64 = 9_600_000

    static func clampLimit(_ n: Int) -> Int {
        min(max(n, minLimit), maxLimit)
    }

    static func estimatedMB(limit: Int) -> Int {
        Int(averageSongBytes * Int64(clampLimit(limit)) / 1_000_000)
    }

    /// 缓存文件的"主干名"：只用歌 id 的稳定哈希，避免 id 里的 `/ : ?` 弄坏路径。
    ///
    /// 后缀**不在这里拼**——见 `fileExtension`。2026-11-25 真机事故就是这里写死成 `.audio` 造成的。
    static func fileBase(songID: String) -> String {
        "p_" + String(fnv1a(songID), radix: 16)
    }

    /// 缓存文件的后缀：必须是**真容器**的扩展名。
    ///
    /// 2026-11-25 真机事故（v2.4.115）：缓存下好之后，回放走的是"把本地文件直接交给 AVFoundation"
    /// 这条路。边下边播时格式是**我们在字节层里声明**的（`public.mp3`），可播本地文件时没人声明，
    /// AVFoundation 只能按扩展名判类型——旧代码把文件统一起名 `p_xxx.audio`，`.audio` 不是任何
    /// 音频容器，它认不出来 → item 一起来就失败 → 进度永远 0:00 → 被当成"源失效"去换源，
    /// 换源又命中同一个文件，于是无限抖。删缓存就好，就是因为这条分支没被走。
    static func fileExtension(container: String, format: String) -> String {
        switch container.lowercased() {
        case "mp3": return "mp3"
        case "m4a", "mp4", "aac": return "m4a"
        case "flac": return "flac"
        case "wav": return "wav"
        case "ogg", "opus": return "ogg"
        default:
            let f = format.lowercased()
            return isPlayableExtension(f) ? f : "mp3"
        }
    }

    /// 这个后缀 AVFoundation 认不认得出是音频容器（`load()` 用它清理历史遗留的 `.audio` 条目）
    static func isPlayableExtension(_ ext: String) -> Bool {
        ["mp3", "m4a", "mp4", "aac", "flac", "wav", "ogg", "opus", "aif", "aiff", "caf"]
            .contains(ext.lowercased())
    }

    /// 这个 backendName 是不是"播本地缓存文件"（不是网络源）。
    ///
    /// 有两处必须认它，漏一处就是老 bug 复发：
    /// ① 时长闸门豁免（本地文件不该被 ±25 秒的接口时长判成坏源）；
    /// ② 播放失败时"这是个坏缓存文件，删掉改网络"的判定。
    static func isCacheBackedLocalSource(_ backendName: String) -> Bool {
        backendName == "播放缓存"
    }

    /// 一个坏缓存文件最多让 App 重试几次（0 = 只回网络重取一次，不许原地打转）
    static let maxCachedFileFallbacks = 1

    /// 时长闸门：能确定"不是同一份"就不许播；读不出索引时算"未知"，允许播但不显示百分比、不判播完
    enum DurationGate: Equatable {
        case match(Double)
        case mismatch(Double)
        case unverified
    }

    static func gate(candidate: Double?, expected: Double,
                     tolerance: Double = durationToleranceSec) -> DurationGate {
        guard let c = candidate, c.isFinite, c > 1 else { return .unverified }
        // 参照时长本身要先像个正经时长：历史上有接口回过 4 / 41 / 107 秒这种垃圾值，
        // 拿它当标准会把好源全判成"不是同一份"→ 一首歌都放不出来。
        guard expected.isFinite, expected >= 60, expected <= 15 * 60 else { return .unverified }
        let diff = abs(c - expected)
        if diff <= tolerance { return .match(c) }
        // 灰区（1.5–2.0 秒）：允许播但不认；超过 2 秒直接判"不是同一份"
        return diff > durationMismatchSec ? .mismatch(diff) : .unverified
    }

    /// 断流后换到的新直链，是不是**同一份文件**：
    /// 总长一致（两边都已知时）+ 首段指纹一致（SHA256 由调用方算，这里只比字符串）。
    /// 总长缺失时只认指纹；指纹缺失时只认总长——两样都没有就不算同一份。
    static func sameFile(oldBytes: Int64, newBytes: Int64,
                         oldHash: String?, newHash: String?) -> Bool {
        let hasBytes = oldBytes > 0 && newBytes > 0
        let hasHash = !(oldHash ?? "").isEmpty && !(newHash ?? "").isEmpty
        guard hasBytes || hasHash else { return false }
        if hasBytes && oldBytes != newBytes { return false }
        if hasHash && oldHash != newHash { return false }
        return true
    }

    /// **半截的 .part 能不能接着写**（2026-11-25 真机事故后加的硬规则）。
    ///
    /// 事故：第一遍把某首歌下了一半，切走再回来时重新解析可能拿到**另一个版本/另一个后端**，
    /// 旧代码直接从 .part 的末尾续写 —— 两个文件的字节混在一个文件里，播放器读出来的就是垃圾，
    /// 表现为"一直抖、一直失败、换源也放不出来"（因为每次重试都续写同一个坏文件）。
    ///
    /// 现在的口径：**.part 必须带身份（首段指纹）**，而且这次要写的源必须指纹一致才允许续；
    /// 没有身份、指纹不同、或旧文件比新源还长 → 一律不要这段，从 0 重下。
    static func canResume(partBytes: Int64, partHash: String?,
                          newHash: String?, newBytes: Int64) -> Bool {
        guard partBytes > 0 else { return false }
        guard let ph = partHash, !ph.isEmpty else { return false }
        guard let nh = newHash, !nh.isEmpty else { return false }
        guard ph == nh else { return false }
        if newBytes > 0, partBytes > newBytes { return false }
        return true
    }

    /// 缓存条数超了要删哪几个：**最早缓存的那首先走**（老板 2026-11-25 定：
    /// "缓存满了就用最新的替换掉最旧的，保持缓存不涨，头进尾出"）。
    ///
    /// 注意这**不是**"最久没听"的 LRU：按入缓存时间排队，新歌从头上进来、最旧的从尾巴挤出去，
    /// 所以总量恒定、行为可预期（一首歌只要还在队列里，不会因为你反复听就一直赖着不走）。
    /// 唯一的例外：`keeping`（正在播的那首）永不淘汰——文件被删它就读不出来了。
    static func victims(orderedByCachedAt: [(id: String, cachedAt: Date)],
                        limit: Int, keeping: String) -> [String] {
        let keepingPresent = orderedByCachedAt.contains { $0.id == keeping }
        let allowedOthers = max(0, limit - (keepingPresent ? 1 : 0))
        let others = orderedByCachedAt.filter { $0.id != keeping }
        guard others.count > allowedOthers else { return [] }
        return others.prefix(others.count - allowedOthers).map { $0.id }
    }

    /// 交给 AVFoundation 的内容类型（写错会让它拒绝播放，所以按容器逐个给）
    static func contentType(container: String, format: String) -> String {
        switch container.lowercased() {
        case "mp3": return "public.mp3"
        case "m4a": return "public.mpeg-4-audio"
        case "flac": return "org.xiph.flac"
        case "wav": return "com.microsoft.waveform-audio"
        case "ogg": return "org.xiph.ogg"
        default:
            return format.lowercased() == "m4a" ? "public.mpeg-4-audio" : "public.audio"
        }
    }

    /// FNV-1a（64 位）：只用它做稳定的文件名/指纹字符串，不是加密用途
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}

// MARK: - 本地文件身份（2026-11-25）
//
// 下载链路用的是同一道身份闸，所以历史上下载下来的文件也可能是"别人的歌"。
// 播放本地文件前先读它自己的头解长度：对不上就不播它（改在线解析），
// 免得"文件是错的、界面是对的"再来一次。
enum LocalAudioFacts {

    /// 只读前 256KB（文件自己的索引），不整首读、不联网
    static func duration(url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 262_144), !head.isEmpty else { return nil }
        let sniffed = StreamVerifier.sniffHead([UInt8](head.prefix(16)))
        return MediaIndexRules.duration(head: head, container: sniffed, totalBytes: 0)
    }
}

// MARK: - 文件自己的索引（2026-11-25）
//
// 老板："能不能给所有的音乐都加上这个校验，只相信文件自己的索引。"
// mp3 的 Xing/Info 帧数、m4a 的 moov/mvhd、flac 的 STREAMINFO 就是"文件自己写的长度"。
// 这里只读**开头那一段**（起播前本来就会 Range 取头），不下载整首、不依赖 AVFoundation。
enum MediaIndexRules {

    /// 从头部字节解出时长；解不出回 nil（= 不可信，不是"零秒"）
    static func duration(head: Data, container: String, totalBytes: Int64) -> Double? {
        let b = [UInt8](head)
        guard b.count >= 16 else { return nil }
        switch container.lowercased() {
        case "flac": return flac(b)
        case "m4a": return m4a(b)
        case "mp3": return mp3(b)
        default:
            if flac(b) != nil { return flac(b) }
            if m4a(b) != nil { return m4a(b) }
            return mp3(b)
        }
    }

    // MARK: flac

    private static func flac(_ b: [UInt8]) -> Double? {
        guard b.count >= 42, b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 else { return nil }
        // 第一个 metadata block 必须是 STREAMINFO（type 0），34 字节
        let type = b[4] & 0x7F
        guard type == 0 else { return nil }
        let info = 8
        guard b.count >= info + 18 else { return nil }
        // 8 字节位域：sampleRate(20) channels(3) bits(5) totalSamples(36)
        var acc: UInt64 = 0
        for i in 0..<8 { acc = (acc << 8) | UInt64(b[info + 10 + i]) }
        let sampleRate = Double((acc >> 44) & 0xFFFFF)
        let totalSamples = acc & 0x0000_000F_FFFF_FFFF
        guard sampleRate > 0, totalSamples > 0 else { return nil }
        return Double(totalSamples) / sampleRate
    }

    // MARK: m4a / mp4

    private static func m4a(_ b: [UInt8]) -> Double? {
        guard b.count >= 16, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 else { return nil }
        var i = 0
        while i + 8 <= b.count {
            let size = Int(be32(b, i))
            let type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            if size < 8 { return nil }
            if type == "moov" {
                return mvhd(in: b, from: i + 8, to: min(i + size, b.count))
            }
            if type == "mdat" { return nil }   // moov 在尾部：头部这段里没有索引
            i += size
        }
        return nil
    }

    private static func mvhd(in b: [UInt8], from: Int, to: Int) -> Double? {
        var i = from
        while i + 8 <= to {
            let size = Int(be32(b, i))
            let type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            if size < 8 { return nil }
            if type == "mvhd", i + 8 + 4 <= to {
                let version = b[i + 8]
                let p = i + 12
                if version == 1 {
                    guard p + 28 <= to else { return nil }
                    let timescale = Double(be32(b, p + 16))
                    let durHi = UInt64(be32(b, p + 20))
                    let durLo = UInt64(be32(b, p + 24))
                    let dur = (durHi << 32) | durLo
                    guard timescale > 0, dur > 0 else { return nil }
                    return Double(dur) / timescale
                } else {
                    guard p + 16 <= to else { return nil }
                    let timescale = Double(be32(b, p + 8))
                    let dur = Double(be32(b, p + 12))
                    guard timescale > 0, dur > 0 else { return nil }
                    return dur / timescale
                }
            }
            if type == "trak" || type == "udta" || type == "meta" { return nil }
            i += size
        }
        return nil
    }

    // MARK: mp3

    private static let mpeg1L3: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mpeg2L3: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    private static let sampleRates: [[Int]] = [[44100, 48000, 32000],
                                               [22050, 24000, 16000],
                                               [11025, 12000, 8000]]

    private static func mp3(_ b: [UInt8]) -> Double? {
        var i = 0
        if b.count > 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            let sz = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14)
                | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
            i = 10 + sz
            if (b[5] & 0x10) != 0 { i += 10 }
        }
        guard i >= 0, i < b.count else { return nil }
        while i + 4 < b.count {
            if b[i] == 0xFF && (b[i + 1] & 0xE0) == 0xE0 {
                let v = (b[i + 1] >> 3) & 0x03     // 3=MPEG1 2=MPEG2 0=MPEG2.5
                let layer = (b[i + 1] >> 1) & 0x03 // 1=Layer III
                let brIdx = Int((b[i + 2] >> 4) & 0x0F)
                let srIdx = Int((b[i + 2] >> 2) & 0x03)
                let mono = ((b[i + 3] >> 6) & 0x03) == 3
                if layer == 1, brIdx > 0, brIdx < 15, srIdx < 3, v != 1 {
                    let mpeg1 = v == 3
                    let side = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
                    let xing = i + 4 + side
                    if xing + 12 <= b.count {
                        let tag = String(bytes: b[xing..<(xing + 4)], encoding: .ascii) ?? ""
                        if tag == "Xing" || tag == "Info" {
                            let flags = be32(b, xing + 4)
                            if flags & 1 != 0 {
                                let frames = Double(be32(b, xing + 8))
                                let sr = Double(sampleRates[mpeg1 ? 0 : (v == 2 ? 1 : 2)][srIdx])
                                let spf = mpeg1 ? 1152.0 : 576.0
                                guard frames > 0, sr > 0 else { return nil }
                                return frames * spf / sr
                            }
                        }
                    }
                    return nil      // 没有 Xing/Info 头 → 这段字节里没有可信长度
                }
            }
            i += 1
        }
        return nil
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16)
            | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
}
