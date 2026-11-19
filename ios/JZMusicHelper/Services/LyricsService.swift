import Foundation

// MARK: - 歌词服务（唯一入口）
//
// r74 取词顺序（老板拍板，按此实现、不要自行调换）：
//
//   ① 酷我平台的歌 → **酷我官方 `getlyric`（musicId 精确，1 个请求）**：拿到就返回。
//      这是对齐安卓、也是"准 + 快"的核心（实测七里香 38 行 / 1268ms，一个请求）。
//   ①b 网易 / QQ 平台的歌 → **按平台 id 直接问官方词**（网易 `/api/song/lyric?id=`、
//      QQ `fcg_query_lyric_new?songmid=`，各 1 个请求）。与 ① 同一原则：id 是精确的，不按名字猜。
//      2026-11-19 加（老板《青花瓷》没词）：④ 网易云兜底是按名字重搜，而周杰伦的歌已从网易云
//      搜索索引下架，搜出来全是翻唱；可官方歌词接口按 songId 仍有完整词——只靠 ④ 永远取不到。
//   ② 其余平台，或官方词为空 → **酷狗 KG 逐字**，但必须过身份闸：
//      歌手 ≥90 分 · 版本类一致（原版↔原版、Live↔Live）· 时长 ≤4s · 词自报 [ti:]/[ar:] 一致。
//   ③ LRCLIB（公开源，独立兜底）
//   ④ 网易云（按「歌名+歌手」搜候选，只给搜得到的歌兜底）
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

    /// 缓存上限：设置页「可缓存歌曲数量」可配（默认 200 首）。
    /// 直接读 UserDefaults 而不是 `SettingsStore`——这个 actor 会被 CI 单独编译，
    /// 不能依赖带 SwiftUI 的 store；键与夹紧口径都在 `LyricsCacheRules`
    /// （`LyricsCacheRules.clamp(0)` = 默认值，所以"没设置过"天然走进默认）。
    private var cacheLimit: Int {
        LyricsCacheRules.clamp(UserDefaults.standard.integer(forKey: LyricsCacheRules.key))
    }

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

    /// 逐源写一条"断在哪一环"的笔记（空态诊断用；每次取词开头清空，只留本次的几个源）
    private final class NoteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        func add(_ text: String) { lock.lock(); parts.append(text); lock.unlock() }
        func clear() { lock.lock(); parts.removeAll(); lock.unlock() }
        func text() -> String { lock.lock(); defer { lock.unlock() }; return parts.joined(separator: "｜") }
    }
    private static let noteBox = NoteBox()

    /// 取词主链（见文件头的四步说明）。整条链 8 秒硬超时。
    static func resolve(_ song: Song, audioSec: Int = 0) async -> LyricsResult? {
        noteBox.clear()
        let target = audioSec > 0 ? audioSec : song.durationSec
        let began = Date()
        let raw = await LddcLyrics.withDeadline(seconds: 8) { await chain(song, target: target) }
        let hit: LyricsResult? = raw ?? nil
        let ms = Int(Date().timeIntervalSince(began) * 1000)

        guard var result = hit, !result.isEmpty else {
            let notes = noteBox.text()
            let diag = LddcLyrics.lastDiagnostics()
            // r78：先看"为什么没词"，别一律说成"没取到词"——
            // 候选都在、只是全是别人的版本时，那是**这首歌没有原唱词**，不是我们取不到。
            var base: String
            switch LddcLyrics.lastMiss() {
            case .rejectedIdentity:
                base = "这首歌没有原唱歌词（词源里只有别的版本，按口径不贴另一版）"
            case .noCandidates:
                base = "没搜到这首歌的词源"
            case .fetchFailed, .none:
                base = ms >= 7900 ? "取词超时（8 秒内没结果）" : "四个源都没取到词"
            }
            if !notes.isEmpty { base += "（" + notes + "）" }
            if !diag.isEmpty { base += "：" + diag }
            await LyricsService.shared.noteFailure(base)
            return nil
        }
        result.elapsedMs = ms
        // 来源标签带上耗时：播放页顶部那行小字就能看到（老板要的毫秒数）
        result.source += " · " + String(format: "%.1fs", Double(ms) / 1000)
        return result
    }

    /// 实际顺序（① → ①b → ② → ③ → ④），每条都是"整首同一版"的来源。
    /// ①b 是 2026-11-19 在 ① 后面补的**同原则**一步：平台 id 精确时直接问官方词，
    /// 不改老板 r74 定的 ①②③④ 相对顺序，只是不再让"按名字搜"的 ④ 去猜平台已有的 id。
    ///
    /// r77 改的是**并发结构，不是顺序**（老板 r74 拍板的 ①②③④ 一字不动）：
    ///   · ③④ **提前开跑**：主链失败时它们的结果通常已经在手上，省掉串行的 1~3 秒；
    ///   · ② 单独 5.5 秒预算：一次 ② 最多 2 候选 × 2 轮 × 2 通道，真机上串行跑完能吃掉
    ///     整个 8 秒，把 ③④ 一起挤掉——"网易云明明有词却显示没词"就是这么来的；
    ///   · 每个源都往空态诊断里写一行"几分钟几秒、断在哪"，下一轮不用猜。
    private static func chain(_ song: Song, target: Int) async -> LyricsResult? {
        let began = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(began) * 1000) }

        let lrclib = Task { await LrclibLyrics.fetch(song, audioSec: target) }
        let netease = Task { await NeteaseLyrics.fallback(song, audioSec: target) }
        defer {
            lrclib.cancel()
            netease.cancel()
        }

        // ① 酷我平台的歌：musicId 精确取词，1 个请求
        if song.platform == .kuwo {
            if let official = await kuwoOfficial(song) { return official }
            noteBox.add("① 酷我官方 \(elapsed())ms 无词")
        } else {
            noteBox.add("① 酷我官方 跳过（非酷我歌）")
        }

        // ①b 平台官方词（按 id 精确，1 个请求）：网易 / QQ。
        //
        // 为什么加（2026-11-19 老板报《青花瓷》没词）：④ 网易云兜底是按「歌名+歌手」**重新搜**，
        // 而周杰伦的歌 2021 年就从网易云搜索索引下架了——搜出来前 15 条全是翻唱、身份闸全拒；
        // 可官方歌词接口按 songId 仍然留着完整词（实测 id=185811 有 1462 字）。
        // 播放的本来就是那一首（platformID 是精确 id），不该再去按名字猜。
        // QQ 同理：按 songmid 直接问 QQ 官方歌词（`fcg_query_lyric_new`，公开、匿名可用）。
        switch song.platform {
        case .netease:
            if let official = await neteaseOfficial(song) { return official }
            noteBox.add("①b 网易官方 \(elapsed())ms 无词")
        case .qq:
            if let official = await qqOfficial(song) { return official }
            noteBox.add("①b QQ官方 \(elapsed())ms 无词")
        default:
            break
        }

        // ② 酷狗逐字（身份闸在 LddcLyrics 里）；5.5 秒预算，超了就止损交给 ③④
        let kgRaw = await LddcLyrics.withDeadline(seconds: LddcLyrics.chainBudgetSeconds) {
            await LddcLyrics.fetch(song: song, audioSec: target)
        }
        if let kg = kgRaw ?? nil { return kg }
        let kgDiag = LddcLyrics.lastDiagnostics()
        noteBox.add("② 酷狗 \(elapsed())ms " + (kgDiag.isEmpty ? "无词" : kgDiag))

        // ③ LRCLIB（早就在跑了，这里只是取结果）
        if let result = await lrclib.value { return result }
        noteBox.add("③ LRCLIB \(elapsed())ms 无匹配")

        // ④ 网易云
        if let result = await netease.value { return result }
        noteBox.add("④ 网易云 \(elapsed())ms 无匹配")
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

    /// 网易云歌曲：`/api/song/lyric?id=` 按 songId 精确取词（不搜索，1 个请求）
    private static func neteaseOfficial(_ song: Song) async -> LyricsResult? {
        guard let lines = await NeteaseLyrics.officialLines(platformID: song.platformID),
              lines.count >= 6 else { return nil }
        // id 精确 → 不用验"是不是别的版本"；只拦"这不是歌词"（字幕/文案）
        if let reason = LyricsCleaning.commentaryReason(lines: lines) {
            await LyricsService.shared.noteFailure("网易云官方词是文案不是歌词：" + reason)
            return nil
        }
        return alignedResult(lines: lines, declaredMs: 0, song: song, source: "网易云官方")
    }

    /// QQ 歌曲：`fcg_query_lyric_new` 按 songmid 精确取词（公开接口，匿名可用，行级 LRC）
    private static func qqOfficial(_ song: Song) async -> LyricsResult? {
        let mid = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return nil }
        let url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
            + "?songmid=\(APIClient.encode(mid))&format=json&nobase64=1"
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://y.qq.com/"], timeout: 5),
              (json["retcode"] as? Int ?? 0) == 0,
              let text = json["lyric"] as? String, !text.isEmpty else { return nil }
        let lines = LyricsCleaning.parseLrc(text)
        guard lines.count >= 6 else { return nil }
        if let reason = LyricsCleaning.commentaryReason(lines: lines) {
            await LyricsService.shared.noteFailure("QQ官方词是文案不是歌词：" + reason)
            return nil
        }
        return alignedResult(lines: lines, declaredMs: 0, song: song, source: "QQ官方")
    }

    /// 统一出口：按音源实际时长对齐，并把比例写进来源标签（播放页顶部那行小字能看到）
    static func alignedResult(lines: [LyricLine], declaredMs: Int, song: Song,
                              source: String) -> LyricsResult {        let aligned = LyricsCleaning.alignedToAudio(lines, declaredMs: declaredMs,
                                                    audioSec: song.durationSec)
        let label = aligned.ratio > 1.0001
            ? source + "·已对齐 ×" + String(format: "%.2f", aligned.ratio)
            : source
        return LyricsResult(lines: aligned.lines, source: label)
    }
}
