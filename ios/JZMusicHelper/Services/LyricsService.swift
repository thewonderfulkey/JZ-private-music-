import Foundation

// MARK: - 歌词服务（唯一入口）
//
// 与 Android `LyricsService` 同口径：
//   · 优先级：**酷我歌曲先走酷我官方**（平台 ID 精确、行级时间），空词才回退 LDDC 双源评分
//   · 缓存：命中后内存缓存 **4 小时**，重复切歌不再请求
//   · 并发：同一首歌的并发请求共享同一个 Task（歌词预取与播放页兜底不重复打接口）
//
// r63（老板反馈 ③「歌词压根取不到了」）加了两层兜底：
//   1. **非酷我的歌**：LDDC 双源都取不到时，按「歌名 歌手」去酷我搜同一首，用它的官方行级歌词
//      （酷我歌词接口稳定、命中率高，实测 蓝莲花/后来/倔强 都有）；
//   2. **时间轴对齐**：不管来自哪条链，词的总长与音源时长差超过 2% 就按比例拉一遍
//      （口径在 `LyricsCleaning.alignedToAudio`，CI 有断言）。
//
// 为什么用 actor：缓存与 in-flight 表是可变状态，且会被多个任务同时访问。
// 用 actor 而不是加锁，是为了让"同一个 key 只发一次请求"这件事在类型层面成立。
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
            // r70：整链失败后再等 1.2 秒重来一轮。
            // 《发如雪》那次"整首没词"，打分是对的（真实候选里原版是满分 100），
            // 断的是取词链——酷狗/QQ 那一刻一条候选都没回来。一次抖动就让屏幕写"没取到歌词"代价太大。
            if let first = await LyricsService.resolve(song, audioSec: audioSec) { return first }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let second = await LyricsService.resolve(song, audioSec: audioSec) { return second }
            return nil
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

    /// 取词主链：酷我官方（酷我的歌）→ LDDC（酷狗 + QQ 双源评分）→ 酷我兜底（其它平台的歌）
    ///
    /// r68：酷我官方词**只有行级时间**，所以「逐字染色」永远出不来（老板拿《枫》做对照：
    /// 那首走 LDDC 的 KRC 就有逐字）。现在官方词拿到之后再试一次 LDDC：
    /// 只有行数对得上（±25%）才升级成逐字那份，对不上仍用官方词。
    ///
    /// r71：**兜底档的 LDDC 词不再抢在酷我官方词前面**。老板"其他歌曲的歌词滚动原来还是准的、
    /// 现在又不准了"的根因之一就在这里：r70 的第 4 档让"只要搜到候选就取一份词"生效，
    /// 于是那些本来没有合格 LDDC 词、一直吃**酷我官方行级词**的歌，突然被换成了一份
    /// Live/醇享版的词——词是有的，时间轴是另一条剪辑的，看起来就是"滚动又不准了"。
    /// 现在的优先级：正常过线的 LDDC → 酷我兜底 → 网易云 → 兜底档 LDDC（最后才用）。
    static func resolve(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        // 酷我歌曲：官方词（行级）→ 尝试用 KRC 升级成逐字 → 官方词 → LDDC 词
        // r70：LDDC 只取**一次**（以前"升级失败"和"兜底"各取一次，等于把请求打了两遍）
        if song.platform == .kuwo {
            let official = await kuwoOfficial(song)
            let lddc = await LddcLyrics.fetch(song: song, audioSec: audioSec)
            if let upgraded = upgrade(lddc, baseline: official) { return upgraded }
            if let official { return official }
            if let lddc { return lddc }
        } else if let lddc = await LddcLyrics.fetch(song: song, audioSec: audioSec) {
            if !lddc.isFallback { return lddc }
            if let better = await betterThanFallback(song, audioSec: audioSec) { return better }
            return lddc
        }

        if song.platform != .kuwo, let result = await kuwoFallback(song) { return result }
        if let result = await NeteaseLyrics.fallback(song, audioSec: audioSec) { return result }

        let diag = LddcLyrics.lastDiagnostics()
        let base = song.platform == .kuwo
            ? "酷我官方歌词与本曲都没有词"
            : "LDDC 双源 + 酷我 + 网易云兜底都没取到词"
        await LyricsService.shared.noteFailure(diag.isEmpty ? base : base + "（" + diag + "）")
        return nil
    }

    /// 兜底档 LDDC 词之外，还有没有更可信的词（酷我官方 → 网易云）。
    /// r71：这两条给的是**同一版**的行级词，时间轴比"另一个剪辑的 KRC"准得多。
    private static func betterThanFallback(_ song: Song, audioSec: Int) async -> LyricsResult? {
        if let result = await kuwoFallback(song) { return result }
        if let result = await NeteaseLyrics.fallback(song, audioSec: audioSec) { return result }
        return nil
    }

    /// 把 LDDC 那份词"升级"成逐字版本：必须真的有逐字时间、且行数与官方词兼容。
    ///
    /// r71：兜底档的词不许升级——它本来就是"另一版"的候选，逐字贴上来只会更歪。
    private static func upgrade(_ lddc: LyricsResult?, baseline: LyricsResult?) -> LyricsResult? {
        guard let lddc, lddc.hasWordTiming, !lddc.isFallback else { return nil }
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
        guard let lines = await KwLyrics.fetch(platformID: song.platformID), !lines.isEmpty else {
            return nil
        }
        return alignedResult(lines: lines, declaredMs: 0, song: song, source: "酷我")
    }

    /// 其它平台的歌：按「歌名 歌手」在酷我里找同一首，取它的官方歌词。
    ///
    /// 为什么要这层：LDDC 的两条源都靠"搜歌名"猜版本，酷狗经常只回现场版/伴奏版；
    /// 而酷我搜索 + 官方歌词接口是一条**独立**的链路，实测命中率明显更高。
    /// 只在「歌名像 + 歌手像」的候选里挑（`NameMatch`），最优先时长最接近的。
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
        let candidates = plain.isEmpty ? pool : plain
        let best = candidates.min { a, b in
            abs(a.durationSec - target) < abs(b.durationSec - target)
        }
        guard let best, let lines = await KwLyrics.fetch(platformID: best.platformID),
              !lines.isEmpty else { return nil }
        return alignedResult(lines: lines, declaredMs: 0, song: song, source: "酷我兜底")
    }

    /// 统一出口：按音源实际时长对齐，并把比例写进来源标签（播放页顶部那行小字能看到）
    private static func alignedResult(lines: [LyricLine], declaredMs: Int, song: Song,
                                      source: String) -> LyricsResult {
        let aligned = LyricsCleaning.alignedToAudio(lines, declaredMs: declaredMs,
                                                   audioSec: song.durationSec)
        let label = aligned.ratio > 1.0001
            ? source + "·已对齐 ×" + String(format: "%.2f", aligned.ratio)
            : source
        return LyricsResult(lines: aligned.lines, source: label)
    }
}
