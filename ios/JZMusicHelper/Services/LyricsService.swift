import Foundation

// MARK: - 歌词服务（唯一入口）
//
// r74 取词顺序（老板拍板，按此实现、不要自行调换）：
//
//   ① 酷我平台的歌 → **酷我官方 `getlyric`（musicId 精确，1 个请求）**：拿到就返回。
//      这是对齐安卓、也是"准 + 快"的核心（实测七里香 38 行 / 1268ms，一个请求）。
//   ② 其余平台，或酷我官方空词 → **酷狗 KG 逐字**，但必须过身份闸：
//      歌手 ≥90 分 · 版本类一致（原版↔原版、Live↔Live）· 时长 ≤4s · 词自报 [ti:]/[ar:] 一致。
//   ③ LRCLIB（公开源，独立兜底）
//   ④ 网易云
//
// 回退**不许跨歌手、不许跨版本类**；首选失败先重试一次，仍失败就空着并写明原因。
// 全程 **8 秒硬超时**（对齐安卓 `withTimeoutOrNull(8000)`），到点就空态，绝不拖到几十秒。
//
// 为什么这么改（r74 两份录屏/截图的根因）：
//   · 《发如雪》播原唱却显示 74 行「发如雪 (粤语版) - 常颖杰」——酷狗里那条
//     `发如雪 / 常颖杰 / 299s` 标题 100 + 歌手 33.3 = 66.7 分，过了 55 线，成了"兜底候选"；
//   · 《七里香》播原唱却显示 58 行 Live 词——`七里香 (Live) 302s` 73.1 分、时长只差 3 秒，同样进池。
//   两者都是"首选取词失败 → 退到下一个候选"造成的，而下一个候选根本不是同一版录音。
//
// 缓存：命中后内存缓存 4 小时；同一首歌的并发请求共享同一个 Task。

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
            // r74：**只跑一遍**。整条链有 8 秒硬超时（`resolve` 里），失败就空态并写明原因，
            // 不再"等 1 秒整条重跑"——那是 r73 之前 iOS 取词要转几十秒的原因之一。
            await LyricsService.resolve(song, audioSec: audioSec)
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

    /// 取词主链（见文件头的四步说明）。整条链 8 秒硬超时。
    static func resolve(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let target = audioSec > 0 ? audioSec : song.durationSec
        let began = Date()
        let raw = await LddcLyrics.withDeadline(seconds: 8) { await chain(song, target: target) }
        let hit: LyricsResult? = raw ?? nil
        let ms = Int(Date().timeIntervalSince(began) * 1000)

        guard var result = hit, !result.isEmpty else {
            let diag = LddcLyrics.lastDiagnostics()
            let base = ms >= 7900 ? "取词超时（8 秒内没结果）" : "四个源都没取到词"
            await LyricsService.shared.noteFailure(diag.isEmpty ? base : base + "：" + diag)
            return nil
        }
        result.elapsedMs = ms
        // 来源标签带上耗时：播放页顶部那行小字就能看到（老板要的毫秒数）
        result.source += " · " + String(format: "%.1fs", Double(ms) / 1000)
        return result
    }

    /// 实际顺序（①②③④），每条都是"整首同一版"的来源
    private static func chain(_ song: Song, target: Int) async -> LyricsResult? {
        // ① 酷我平台的歌：musicId 精确取词，1 个请求
        if song.platform == .kuwo, let official = await kuwoOfficial(song) {
            return official
        }
        // ② 酷狗逐字（身份闸在 LddcLyrics 里）
        if let lddc = await LddcLyrics.fetch(song: song, audioSec: target) {
            return lddc
        }
        // ③ LRCLIB
        if let result = await LrclibLyrics.fetch(song, audioSec: target) { return result }
        // ④ 网易云
        if let result = await NeteaseLyrics.fallback(song, audioSec: target) { return result }
        return nil
    }

    /// 酷我歌曲：平台 ID 就是精确的 musicId，直接拿官方行级歌词（1 个请求）。
    ///
    /// 只此一条用酷我——**不按名字去酷我里猜**。实测酷我曲库里周杰伦《发如雪》没有正片
    /// （20 条候选全是伴奏/DJ/花絮/霍元甲/现场版/升2），按名字兜底只会拿到「拍摄花絮」的
    /// 51 行字幕文案；所以只认 musicId。
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
