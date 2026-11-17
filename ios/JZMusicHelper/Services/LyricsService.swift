import Foundation

// MARK: - 歌词服务（唯一入口）
//
// r72 起整条链只有四步，**每一步都是"整首同一版"的来源**：
//
//   酷我的歌：酷我官方词（行级）→ 有逐字就升级 → LDDC（酷狗）→ LRCLIB → 网易云
//   其它平台的歌：LDDC（酷狗，LDDC 打分口径）→ 酷我官方词 → LRCLIB → 网易云
//
// 为什么这样排：
//   · LDDC（酷狗）的 KRC 带逐字时间、时间轴最准，排第一；
//   · 酷我官方词是**按歌曲 ID 精确取**的行级词，稳、命中率高，排第二；
//   · LRCLIB 是一条**完全独立**的公开源（无需签名、不受酷狗限流影响，实测《发如雪》《七里香》
//     《晴天》都有同步歌词）。老板报"酷狗能取到词、App 取不到"时，它就是那条兜得住的命；
//   · 网易云最后（周杰伦等曲库在网易基本没有，但对别的歌仍是多一条命）。
//
// 缓存：命中后内存缓存 4 小时；同一首歌的并发请求共享同一个 Task。
// 为什么用 actor：缓存与 in-flight 表是可变状态，且会被多个任务同时访问。
actor LyricsService {

    static let shared = LyricsService()

    private var cache: [String: (result: LyricsResult, at: Date)] = [:]
    private var inflight: [String: Task<LyricsResult?, Never>] = [:]
    private let ttl: TimeInterval = 4 * 60 * 60
    private let cacheLimit = 200

    /// 最近一次取词失败的**人话原因**（播放页空状态里显示，方便下一轮定位；不写日志文件）
    private(set) var lastFailure: String = ""

    /// 给 UI 读的失败原因（actor 隔离，需要 await）
    func failureReason() -> String { lastFailure }

    // MARK: 入口

    /// `audioSec`：真正在放的这条音频时长（0 = 用曲目元数据）；`force` = 绕过缓存重取
    func fetch(_ song: Song, audioSec: Int = 0, force: Bool = false) async -> LyricsResult? {
        let key = cacheKey(song)
        if !force, let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl {
            return hit.result
        }
        if let running = inflight[key] {
            return await running.value
        }

        let task = Task<LyricsResult?, Never> {
            // 四个源全空 → 等 1 秒把整条链再跑一遍（弱网时第一个请求常常是超时）
            if let first = await LyricsService.resolve(song, audioSec: audioSec) { return first }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return await LyricsService.resolve(song, audioSec: audioSec)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil

        if let result {
            cache[key] = (result, Date())
            trimCacheIfNeeded()
        }
        return result
    }

    /// 只清缓存（设置页「清空歌词缓存」用）
    func clearCache() {
        cache.removeAll()
    }

    func cachedCount() -> Int { cache.count }

    // MARK: 内部

    private func cacheKey(_ song: Song) -> String {
        "\(song.platform.rawValue)|\(song.platformID)"
    }

    private func trimCacheIfNeeded() {
        guard cache.count > cacheLimit else { return }
        // 先丢最旧的（歌词缓存丢了大不了重下，不值得做 LRU）
        let sorted = cache.sorted { $0.value.at < $1.value.at }
        for (key, _) in sorted.prefix(cache.count - cacheLimit) {
            cache.removeValue(forKey: key)
        }
    }

    private func noteFailure(_ reason: String) {
        lastFailure = reason
    }
}

// MARK: - 取词主链（不依赖 actor 状态，便于 SelfTest 直接调）

extension LyricsService {

    /// 取词主链（见文件头的四步说明）
    static func resolve(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        if song.platform == .kuwo {
            let official = await kuwoOfficial(song)
            // 官方词拿到就先用它；能升级成逐字（同一首、行数对得上）才换
            if let official {
                let lddc = await LddcLyrics.fetch(song: song, audioSec: audioSec)
                if let upgraded = upgrade(lddc, baseline: official) { return upgraded }
                return official
            }
            if let lddc = await LddcLyrics.fetch(song: song, audioSec: audioSec) { return lddc }
        } else if let lddc = await LddcLyrics.fetch(song: song, audioSec: audioSec) {
            return lddc
        }

        if let result = await kuwoFallback(song) { return result }
        if let result = await LrclibLyrics.fetch(song, audioSec: audioSec) { return result }
        if let result = await NeteaseLyrics.fallback(song, audioSec: audioSec) { return result }

        let diag = LddcLyrics.lastDiagnostics()
        let base = song.platform == .kuwo
            ? "酷我官方 / 酷狗 / LRCLIB / 网易云都没取到词"
            : "酷狗 / 酷我 / LRCLIB / 网易云都没取到词"
        await LyricsService.shared.noteFailure(diag.isEmpty ? base : base + "（" + diag + "）")
        return nil
    }

    /// 把 LDDC 那份词"升级"成逐字版本：必须真的有逐字时间、且行数与官方词兼容。
    /// 对不上就仍用官方词——宁可没有逐字，也不把另一版词的逐字贴上来。
    private static func upgrade(_ lddc: LyricsResult?, baseline: LyricsResult?) -> LyricsResult? {
        guard let lddc, lddc.hasWordTiming else { return nil }
        if let baseline, !baseline.isEmpty {
            guard LyricsCleaning.lineCountsCompatible(baseline.lines.count, lddc.lines.count) else {
                return nil
            }
        }
        var upgraded = lddc
        if !lddc.matchNote.isEmpty { upgraded.matchNote = lddc.matchNote + " · 逐字升级" }
        return upgraded
    }

    /// 酷我歌曲：平台 ID 就是精确的 musicId，直接拿官方行级歌词
    private static func kuwoOfficial(_ song: Song) async -> LyricsResult? {
        guard let lines = await KwLyrics.fetch(platformID: song.platformID),
              lines.count >= 6 else { return nil }
        return alignedResult(lines: lines, declaredMs: 0, song: song, source: "酷我")
    }

    /// 其它平台的歌：按「歌名 歌手」在酷我里找同一首，取它的官方歌词。
    ///
    /// r72：**逐个试前 3 个候选，并且拒收"歌词正文自报是另一个版本"的那份**。
    /// 老板截图里《七里香》拿到「2024 嘉年华世界巡回演唱会台北站」的词，
    /// 就是这里以前"只取时长最接近的一条、不检查歌词正文"造成的。
    static func kuwoFallback(_ song: Song) async -> LyricsResult? {
        let keyword = song.searchKeyword
        guard !keyword.isEmpty else { return nil }
        let adapter = KuwoSearchAdapter()
        guard let results = try? await adapter.search(keyword: keyword, limit: 20),
              !results.isEmpty else { return nil }

        let target = song.durationSec
        let pool = results.filter {
            NameMatch.titleMatches(song.name, $0.name) && NameMatch.singerMatches(song.singer, $0.singer)
        }
        guard !pool.isEmpty else { return nil }
        // 变体（伴奏/live/翻唱）只在没有正片时才用
        let plain = pool.filter { !KuwoParser.isVariant($0.name) }
        let candidates = (plain.isEmpty ? pool : plain).sorted {
            abs($0.durationSec - target) < abs($1.durationSec - target)
        }
        for best in candidates.prefix(3) {
            guard let lines = await KwLyrics.fetch(platformID: best.platformID),
                  lines.count >= 6 else { continue }
            // 歌词正文自己写着是"另一个版本"（演唱会/live/伴奏…）→ 换下一个候选
            if LyricsCleaning.contentVersionRejection(lines: lines, queryTitle: song.name) != nil {
                continue
            }
            return alignedResult(lines: lines, declaredMs: 0, song: song, source: "酷我")
        }
        return nil
    }

    /// 统一出口：按音源实际时长对齐，并把比例写进来源标签（播放页顶部那行小字能看到）
    static func alignedResult(lines: [LyricLine], declaredMs: Int, song: Song,
                              source: String) -> LyricsResult {
        let aligned = LyricsCleaning.alignedToAudio(lines, declaredMs: declaredMs,
                                                    audioSec: song.durationSec)
        let label = aligned.ratio > 1.0001
            ? source + "·已对齐 ×" + String(format: "%.2f", aligned.ratio)
            : source
        return LyricsResult(lines: aligned.lines, source: label)
    }
}
