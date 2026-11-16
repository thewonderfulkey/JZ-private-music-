import Foundation

// MARK: - 歌词服务（唯一入口）
//
// 与 Android `LyricsService` 同口径：
//   · 优先级：**酷我歌曲先走酷我官方**（平台 ID 精确、行级时间），空词才回退 LDDC 双源评分
//   · 缓存：命中后内存缓存 **4 小时**，重复切歌不再请求
//   · 并发：同一首歌的并发请求共享同一个 Task（歌词预取与播放页兜底不重复打接口）
//
// 为什么用 actor：缓存与 in-flight 表是可变状态，且会被多个任务同时访问。
// 用 actor 而不是加锁，是为了让"同一个 key 只发一次请求"这件事在类型层面成立。
actor LyricsService {

    static let shared = LyricsService()

    private var cache: [String: (result: LyricsResult, at: Date)] = [:]
    private var inflight: [String: Task<LyricsResult?, Never>] = [:]
    private let ttl: TimeInterval = 4 * 60 * 60
    private let cacheLimit = 200

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

    /// 取词主链：酷我官方 → LDDC（酷狗 + QQ 双源评分）
    private static func resolve(_ song: Song) async -> LyricsResult? {
        if song.platform == .kuwo {
            if let lines = await KwLyrics.fetch(platformID: song.platformID), !lines.isEmpty {
                return LyricsResult(lines: lines, source: "酷我")
            }
        }
        return await LddcLyrics.fetch(song: song)
    }
}
