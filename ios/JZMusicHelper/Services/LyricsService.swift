import Foundation

// MARK: - 歌词服务（唯一入口）
//
// r73 起整条链只有四步，每步都是"整首同一版"的来源，**任何一个源都不许按名字猜着贴词**：
//
//   ① LDDC（酷狗，逐字 KRC）—— 老板口径「直接走 LDDC」
//   ② 酷我官方词 —— 只在该曲**本来就是酷我那一版**时用（平台 ID 精确对应）
//   ③ LRCLIB —— 独立公开源，不受酷狗限流影响
//   ④ 网易云 —— 最后一条
//
// 为什么删掉了 r72 的「按名字去酷我兜底」这一步：
//   老板 r73 录屏里《发如雪》显示的是「51 行 · 酷我」，正文第一句是
//   「本字幕由QQ音乐独家AI字幕技术生成」，后面全是专辑介绍口播——那不是歌词。
//   查下来酷我里周杰伦的《发如雪》只有 伴奏/DJ版/拍摄花絮/现场版，**没有正片**，
//   那条兜底就挑中了「发如雪 拍摄花絮」的专访视频。宁可空着，也不贴一段解说。
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
        // ① LDDC（酷狗）：老板口径「直接走 LDDC」——逐字 KRC、时间轴最准，一律优先
        if let lddc = await LddcLyrics.fetch(song: song, audioSec: audioSec) {
            return lddc
        }
        // ② 酷我官方词：只有"这首歌本身就是酷我那一版"才用（平台 ID 精确对应，不按名字猜）
        if song.platform == .kuwo, let official = await kuwoOfficial(song) {
            return official
        }
        // ③ LRCLIB：独立公开源，不受酷狗限流影响，《发如雪》实测 113 行同步词
        if let result = await LrclibLyrics.fetch(song, audioSec: audioSec) { return result }
        // ④ 网易云
        if let result = await NeteaseLyrics.fallback(song, audioSec: audioSec) { return result }

        let diag = LddcLyrics.lastDiagnostics()
        await LyricsService.shared.noteFailure(
            diag.isEmpty ? "LDDC / 酷我官方 / LRCLIB / 网易云都没取到词" : "LDDC 没取到：" + diag)
        return nil
    }

    /// 酷我歌曲：平台 ID 就是精确的 musicId，直接拿官方行级歌词。
    ///
    /// 只此一条用酷我——**不再按名字去酷我里猜**。r72 之前那条"名字兜底"是《发如雪》
    /// 51 行错词的来源：酷我里周杰伦的《发如雪》只有伴奏/DJ/花絮/现场版，
    /// 搜"发如雪 周杰伦"根本搜不到正片，兜底就挑中了「发如雪 拍摄花絮」的专访字幕。
    private static func kuwoOfficial(_ song: Song) async -> LyricsResult? {
        guard let lines = await KwLyrics.fetch(platformID: song.platformID),
              lines.count >= 6 else { return nil }
        // ID 精确 → 不用再验"是不是别的版本"；只拦"这不是歌词"（字幕/文案）
        if let reason = LyricsCleaning.commentaryReason(lines: lines) {
            await LyricsService.shared.noteFailure("酷我官方词是文案不是歌词：" + reason)
            return nil
        }
        return alignedResult(lines: lines, declaredMs: 0, song: song, source: "酷我")
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
