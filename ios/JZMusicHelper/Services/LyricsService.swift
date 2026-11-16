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

    func fetch(_ song: Song) async -> LyricsResult? {
        let key = cacheKey(song)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl {
            return hit.result
        }
        if let running = inflight[key] {
            return await running.value
        }

        let task = Task<LyricsResult?, Never> { await LyricsService.resolve(song) }
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
    static func resolve(_ song: Song) async -> LyricsResult? {
        if song.platform == .kuwo {
            if let result = await kuwoOfficial(song) { return result }
        }
        if let result = await LddcLyrics.fetch(song: song) { return result }
        if song.platform != .kuwo, let result = await kuwoFallback(song) { return result }
        await LyricsService.shared.noteFailure(song.platform == .kuwo
                                               ? "酷我官方歌词与本曲都没有词"
                                               : "LDDC 双源 + 酷我兜底都没取到词")
        return nil
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
