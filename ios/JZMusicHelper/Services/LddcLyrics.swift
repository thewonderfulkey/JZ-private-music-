import Foundation

// MARK: - LDDC 取词编排（酷狗 KG / QQ QM 双源）
//
// 与 Android `LddcLyrics.kt` 同口径（对齐 chenmozhijin/LDDC 的 auto_fetch）：
//   双源并行搜「歌名 歌手」→ 候选按 LDDC 评分选优（>55 分）→ 分数降序、时长近者优先、同分 QQ 优先
//   → 取前 3 个候选取词 → 解密 → 要求 ≥6 行且不是乱码 → **文件头软验收** → 时间轴按音源时长对齐
//
// 2026-11-17 第六轮（老板真机反馈「歌词压根取不到了」）——上一轮把两道闸都做成了硬门槛：
//   · 候选 ±4s 时长过滤：实测 蓝莲花/后来/倔强/我不配 这些歌一个候选都不剩（各家给同一首歌
//     的时长能差 5~40 秒），于是整首没词；
//   · 版本标签惩罚（live/现场/翻唱 −35）与文件头验收：本来是"防止贴错版本"，
//     但它们把「唯一的候选」也一起丢了。
// 现在两道闸都改成**软**的：时长只参与排序；惩罚只用来排序；文件头验收优先选通过的那份，
// 一份都没通过就退回排名最高的那份（老板口径：宁可给最接近的一份词，也别整首空着），
// 最后再用 `LyricsCleaning.alignedToAudio` 把时间轴按音源实际时长拉一遍。
//
// 上一轮（2026-11-17 凌晨）加的是「歌词文件自己声明的版本信息」：
// 打分公式本身没错，漏掉的是 KRC/QRC/LRC 明文头部的 `[total:...]` / `[length:...]` / `[ti:...]`，
// 这才是这份词对应哪一版音频的直接证据。所以 `fetchKgLines` / `fetchQqLines` 仍把元数据带回来。
//
// 注意「元数据缺失要放行」不是偷懒：SelfTest 里的真实酷狗 KRC 样本（realKrcBase64）
// 头部只有 `[ti:]/[ar:]/[al:]/[by:]/[offset:]`，**没有** `[total:]`（很多原版甚至是 `[total:0]`）；
// 总时长更多出现在 QQ QRC / 纯文本 LRC 里。所以只做「有就验」。
//
// 两个源的脾气（都写在 Android 注释里，实测复核过）：
//   · 酷狗 `lyrics.kugou.com/v1/search` 与 `/download` 的签名**只含 appid+clientver+业务参数**，
//     塞公共参数会签名失配；搜索接口 `complexsearch` 反而要全套公共参数
//   · QQ 走 `musicu.fcg`，先 GetSession 拿 uid/sid/userip，再 DoSearch、GetPlayLyricInfo；
//     该接口对同 IP 高频请求会返回 `request.code=2001`（空候选），遇到就当这条源失败
//
// 2026-11-16（真机反馈「歌词全是空」）：酷狗的三个端点原来写的是 `http://`。
// iOS 的 ATS 默认拒绝明文请求（NSURLErrorAppTransportSecurityRequiresSecureConnection），
// 所以**整条酷狗源在真机上是死的**——本地 Python 探针能通只是因为 urllib 没有 ATS。
// 现在三处全部换成 https（实测 complexsearch / lyrics / download 都返回 200），
// Info.plist 里同时补了 ATS 例外，兜住其它明文音频/CDN 地址。
enum LddcLyrics {

    private static let kgSalt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private static let netTimeout: TimeInterval = 8
    private static let minScore = LddcMatch.minScore

    /// 文件头时长与歌曲时长的容差（毫秒）。
    ///
    /// 为什么比 APK/LDDC 的 4000ms 宽一倍：
    ///   1) APK 的 4000 是拿「搜索结果时长」卡「搜索结果时长」，两边都可能有 ±几秒的误差；
    ///      我们现在拿的是**歌词文件头里写死的总时长**，它是这份词自身的长度，用来卡客户端时长；
    ///   2) 歌词文件头的总时长常按整轨算（含前奏/尾奏/静音），与单曲播放时长能差 5~7 秒；
    ///   3) 阈值再紧会误杀正确版本，再松就拦不住 live —— live 与原版的时长差通常 >15s。
    static let headerDurationToleranceMs = 8_000

    // MARK: 候选

    struct Candidate: Sendable {
        let source: String          // "kg" / "qq"
        let title: String
        let artist: String
        let durationSec: Int
        var kgId: String? = nil
        var kgHash: String? = nil
        var qqId: String? = nil
        var qqSinger: String? = nil
        var qqAlbum: String? = nil
    }

    // MARK: 入口

    /// 双源并行搜索 → 评分选优 → 逐候选取词。全部失败返回 nil。
    ///
    /// `audioSec`：**真正在放的这条音频**的时长（引擎拿到后传进来）。传 0 就退回曲目元数据时长。
    /// r69 起时长差会进打分，所以这个数越准越好。
    static func fetch(song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let title = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = LyricsCleaning.cleanArtist(song.singer)
        guard !title.isEmpty else { return nil }

        async let kgTask = searchKg(title: title, artist: artist)
        async let qqTask = searchQq(title: title, artist: artist)
        let candidates = await kgTask + qqTask
        guard !candidates.isEmpty else { return nil }

        let target = audioSec > 0 ? audioSec : song.durationSec
        guard let picked = await pickBest(candidates: candidates, song: song,
                                          title: title, artist: artist,
                                          targetSec: target) else { return nil }
        // 时间轴按音源实际时长对齐（r63：宁可给最接近的一份词，也别整首空着）
        let aligned = LyricsCleaning.alignedToAudio(picked.lines, declaredMs: picked.declaredMs,
                                                    audioSec: song.durationSec)
        let source = aligned.ratio > 1.0001
            ? "LDDC·已对齐 ×" + String(format: "%.2f", aligned.ratio)
            : "LDDC"
        return LyricsResult(lines: aligned.lines, source: source, matchNote: picked.note)
    }

    /// 一次取词的结果（连同歌词文件自己声明的总时长，供时间轴对齐用）
    struct Picked: Sendable {
        let lines: [LyricLine]
        let declaredMs: Int
        /// 这个人话说明写的是"为什么选了这份词"（播放页「音源详情 → 歌词」会显示）
        var note: String = ""
    }

    /// 评分 + 版本标签惩罚 + 排序（**不设时长硬门槛**）+ 取前 3 个候选取词 + 文件头软验收
    ///
    /// r63 的关键改动（老板反馈 ③：「歌词压根取不到了」）：
    ///   · **去掉 ±4s 的候选硬过滤**。原来是 `abs(目标时长 - 候选时长) > 4` 直接丢，
    ///     实测 蓝莲花 / 后来 / 倔强 / 我不配 这些歌一个候选都不剩（酷狗给的时长跟各家音源
    ///     差 5~40 秒很常见）→ 整首没词。现在时长只参与**排序**（越接近越优先）。
    ///   · **版本惩罚保留，但只用来排序**：带 live/现场/翻唱/伴奏的候选仍被压到后面，
    ///     实在没有别的候选时才用它——宁可词差一点，也别整首空着。
    ///   · **文件头验收从"一票否决"改成"优选项"**：先在所有候选里找通过验收的（按排名），
    ///     一份都没通过才退回到排名最高的那份。
    static func pickBest(candidates: [Candidate], song: Song,
                         title: String, artist: String, targetSec: Int) async -> Picked? {
        let targetDur = targetSec > 0 ? targetSec : song.durationSec
        var scored: [(rank: LddcMatch.CandidateScore, source: String, candidate: Candidate)] = []
        for cand in candidates {
            let one = scoredCandidate(cand, title: title, artist: artist, targetDur: targetDur)
            if one.total > minScore {
                scored.append((one, cand.source, cand))
            }
        }
        // 一个都没过及格线：先退到"至少歌手对得上"的兜底池；
        // 连兜底池都空（整页只有一份带版本标记的词）→ 最后兜底，宁可词差一点也别整首空着。
        var fallbackTier = 0        // 0 = 正常过线，1 = 兜底，2 = 最后兜底
        if scored.isEmpty {
            for cand in candidates {
                let one = scoredCandidate(cand, title: title, artist: artist, targetDur: targetDur)
                if LddcMatch.passesFallback(one) {
                    scored.append((one, cand.source, cand))
                }
            }
            fallbackTier = 1
        }
        if scored.isEmpty {
            for cand in candidates {
                let one = scoredCandidate(cand, title: title, artist: artist, targetDur: targetDur)
                if LddcMatch.isLastResort(one) {
                    scored.append((one, cand.source, cand))
                }
            }
            fallbackTier = 2
        }
        guard !scored.isEmpty else { return nil }

        // 排序：分数降序 → 时长差升序 → QQ 优先（对齐 sources=(QM, KG)）
        scored.sort {
            precedes((score: $0.rank.total, durationDelta: $0.rank.durationDelta, source: $0.source),
                     (score: $1.rank.total, durationDelta: $1.rank.durationDelta, source: $1.source))
        }

        // 前 3 个候选并行取词：谁先成不重要，最后按"候选排名"取——
        // 排在前面且通过版本验收的先赢，全都没通过就退回排名最高的那份。
        let top = Array(scored.prefix(3))
        let outcomes: [FetchedOutcome] = await withTaskGroup(of: FetchedOutcome.self) { group in
            for (idx, item) in top.enumerated() {
                group.addTask {
                    guard let one = await fetchOne(item.candidate) else {
                        return FetchedOutcome(idx: idx, lines: nil, headerOK: false)
                    }
                    // 两道验收：文件头（[ti:]/[total:]）+ **正文第一行自报的版本**
                    // （老板 r69：《发如雪》拿到的词，第一行就写着「发如雪（醇享版）」）
                    let headReject = headerRejection(meta: one.meta, song: song,
                                                     queryTitle: title, queryArtist: artist)
                    let bodyReject = LyricsCleaning.contentVersionRejection(lines: one.lines,
                                                               queryTitle: title)
                    let rejection = headReject ?? bodyReject
                    if let rejection {
                        print("[LddcLyrics] 候选 \(item.candidate.source)「\(item.candidate.title)」"
                              + "未通过版本验收（仍可兜底）：\(rejection)")
                    }
                    let note = matchNote(candidate: item.candidate, score: item.rank,
                                         targetSec: targetDur, tier: fallbackTier,
                                         rejected: rejection != nil)
                    return FetchedOutcome(idx: idx,
                                          lines: Picked(lines: one.lines,
                                                        declaredMs: one.meta.durationMs,
                                                        note: note),
                                          headerOK: rejection == nil)
                }
            }
            var out: [FetchedOutcome] = []
            for await r in group { out.append(r) }
            return out
        }
        guard let winner = chooseOutcome(outcomes, topCount: top.count) else { return nil }
        return outcomes.first(where: { $0.idx == winner })?.lines
    }

    /// 一句人话说明"为什么选了这份词"（详情页 + 日志）
    static func matchNote(candidate: Candidate, score: LddcMatch.CandidateScore,
                          targetSec: Int, tier: Int, rejected: Bool) -> String {
        var text = "《\(candidate.title)》· 目标 \(targetSec)s / 候选 \(candidate.durationSec)s · "
            + score.explanation
        if tier == 1 { text += " · 未过 55，按兜底线采纳" }
        if tier == 2 { text += " · 只有这一份，按最后兜底采纳" }
        if rejected { text += " · 版本验收未过" }
        return text
    }

    /// 单个候选的评分（含版本标签惩罚）与时长差 —— 纯函数，CI 能直接断言。
    ///
    /// r63 的关键：**时长差不参与过滤，只参与排序**。原来 `abs(目标 - 候选) > 4` 直接丢，
    /// 实测 蓝莲花/后来/倔强/我不配 整首一个候选都不剩 → 没词。
    static func scoredCandidate(_ cand: Candidate, title: String, artist: String, targetDur: Int)
        -> LddcMatch.CandidateScore {
        var one = LddcMatch.scoreCandidate(queryTitle: title, candidateTitle: cand.title,
                                           queryArtist: artist, candidateArtist: cand.artist,
                                           targetSec: targetDur, candidateSec: cand.durationSec)
        // 时长未知时 `durationDelta` 用 Int.max 表示"排在有明确时长的后面"（不影响扣分）
        if !(targetDur > 0 && cand.durationSec > 0) {
            one = LddcMatch.CandidateScore(titleScore: one.titleScore,
                                           artistScore: one.artistScore, base: one.base,
                                           versionPenalty: one.versionPenalty,
                                           durationDelta: Int.max,
                                           durationPenalty: one.durationPenalty,
                                           total: one.total)
        }
        return one
    }

    /// 一个候选的取词结果（供 `chooseOutcome` 做纯逻辑断言）
    struct FetchedOutcome: Sendable {
        let idx: Int
        let lines: Picked?
        /// 文件头验收是否通过
        let headerOK: Bool

        var hasLines: Bool { lines != nil }
    }

    /// 从取词结果里挑赢家（纯函数）：
    ///   1. 先按**候选排名**取"有词且通过版本验收"的；
    ///   2. 一份都没通过 → 退回排名最高的"有词"的那份（老板 r63 口径：宁可词差一点，也别空着）。
    static func chooseOutcome(_ outcomes: [FetchedOutcome], topCount: Int) -> Int? {
        guard topCount > 0 else { return nil }
        for idx in 0..<topCount {
            if let hit = outcomes.first(where: { $0.idx == idx && $0.hasLines && $0.headerOK }) {
                return hit.idx
            }
        }
        for idx in 0..<topCount {
            if let hit = outcomes.first(where: { $0.idx == idx && $0.hasLines }) {
                return hit.idx
            }
        }
        return nil
    }

    private static func sourcePriority(_ source: String) -> Int {
        source == "qq" ? 0 : 1
    }

    /// 候选排序的比较器（纯函数）。`ranked` 与 `pickBest` 共用这一套，避免"测过的和跑的不是一份"。
    private static func precedes(_ a: (score: Double, durationDelta: Int, source: String),
                                 _ b: (score: Double, durationDelta: Int, source: String)) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.durationDelta != b.durationDelta { return a.durationDelta < b.durationDelta }
        return sourcePriority(a.source) < sourcePriority(b.source)
    }

    /// 候选排序（纯函数，供 SelfTest 断言）：
    /// 分数降序 → 时长差升序（未知用 Int.max 表示，排最后）→ QQ 优先。
    static func ranked(_ items: [(score: Double, durationDelta: Int, source: String)])
        -> [(score: Double, durationDelta: Int, source: String)] {
        items.sorted(by: precedes)
    }

    /// 单个候选取词 + 乱码校验；要求 ≥6 行。
    /// 「版本对不对」不在这里判：交给调用方在**全部候选之间**比较后再决定（r63 改成软验收）。
    private static func fetchOne(_ cand: Candidate) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        let fetched: (lines: [LyricLine], meta: LyricsMeta)?
        switch cand.source {
        case "kg": fetched = await fetchKgLines(cand)
        case "qq": fetched = await fetchQqLines(cand)
        default: fetched = nil
        }
        guard let fetched, !fetched.lines.isEmpty else { return nil }
        if LyricsCleaning.isBroken(fetched.lines.map(\.text).joined(separator: "\n")) { return nil }
        guard fetched.lines.count >= 6 else { return nil }
        return fetched
    }

    /// 用歌词文件头做「版本验收」：nil = 通过，非 nil = 不通过的原因（人类可读，只打控制台）。
    ///
    /// **r63 起这是"优选项"而不是"一票否决"**：调用方先在所有候选里找通过验收的，
    /// 一份都没通过才退回排名最高的那份。原来一票否决会让"唯一的候选"也被丢掉，整首没词。
    ///
    /// 三项分别覆盖三种错版方式：
    ///   · 时长对不上 → live/不同剪辑版（文件头 `[total:...]` 是这份词自己的音频长度）；
    ///   · 标题对不上 → 搜到了别的歌（同歌手不同曲目）；
    ///   · 歌手对不上 → 翻唱（标题可能改得看不出来）。
    ///
    /// **元数据缺失时一律放行**（`hasHeader == false` 不构成拒绝理由），保持原来"没头部信息也能用"的行为。
    /// 阈值 50 / 30 比评分主公式的及格线宽松，因为这里是"别误杀"的第二道闸，不是主判定。
    static func headerRejection(meta: LyricsMeta, song: Song,
                                queryTitle: String, queryArtist: String) -> String? {
        if meta.durationMs > 0 && song.durationSec > 0 {
            let songMs = song.durationSec * 1_000
            let delta = abs(meta.durationMs - songMs)
            if delta > headerDurationToleranceMs {
                return "歌词文件头时长 \(meta.durationMs)ms 与本曲 \(songMs)ms 相差 \(delta)ms"
                    + "（> \(headerDurationToleranceMs)ms，疑似 live/其它版本）"
            }
        }
        if !meta.title.isEmpty {
            let ts = LddcMatch.titleScore(queryTitle, meta.title)
            if ts < 50 {
                return "文件头标题「\(meta.title)」与查询「\(queryTitle)」标题分 \(Int(ts)) < 50"
            }
        }
        if !meta.artist.isEmpty {
            let queryArtistClean = LyricsCleaning.cleanArtist(queryArtist)
            let asScore = LddcMatch.artistScore(queryArtistClean, meta.artist)
            if asScore < 30 {
                return "文件头歌手「\(meta.artist)」与查询「\(queryArtistClean)」歌手分"
                    + " \(Int(asScore)) < 30"
            }
        }
        return nil
    }

    // ==================== 酷狗 ====================

    /// 进程级可变状态（酷狗 dfid、QQ 会话）：用带锁的小类，而不是 `static var`
    private final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var dfid: String?
        private var dfidAt = Date.distantPast
        private var qqSession: [String: String]?

        func cachedDfid() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let dfid, Date().timeIntervalSince(dfidAt) < 30 * 60 else { return nil }
            return dfid
        }

        func store(dfid: String) {
            lock.lock(); self.dfid = dfid; dfidAt = Date(); lock.unlock()
        }

        func session() -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return qqSession
        }

        func store(session: [String: String]) {
            lock.lock(); qqSession = session; lock.unlock()
        }
    }

    private static let state = SharedState()

    private static func searchKg(title: String, artist: String) async -> [Candidate] {
        let dfid = await kgRegisterDfid() ?? "-"
        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let keyword = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let params: [(String, String)] = [
            ("sorttype", "0"), ("keyword", keyword), ("pagesize", "20"), ("page", "1"),
        ]
        let query = kgQuery(params: params, module: "SearchSong", mid: mid, dfid: dfid)
        let url = "https://complexsearch.kugou.com/v2/search/song?" + query
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: kgHeaders(module: "SearchSong", mid: mid), timeout: netTimeout),
              let lists = (json["data"] as? [String: Any])?["lists"] as? [[String: Any]] else {
            return []
        }
        var out: [Candidate] = []
        for item in lists {
            let name = (item["SongName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = item["ID"] as? String ?? ""
            let hash = item["FileHash"] as? String ?? ""
            if name.isEmpty || id.isEmpty || hash.isEmpty { continue }
            let singers = (item["Singers"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
            out.append(Candidate(source: "kg", title: name, artist: singers,
                                 durationSec: item["Duration"] as? Int ?? 0,
                                 kgId: id, kgHash: hash))
        }
        return out
    }

    private static func fetchKgLines(_ cand: Candidate) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        guard let id = cand.kgId, let hash = cand.kgHash else { return nil }
        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let durMs = cand.durationSec * 1000
        let lrcParams: [(String, String)] = [
            ("album_audio_id", id), ("duration", String(durMs)), ("hash", hash),
            ("keyword", "\(cand.artist) - \(cand.title)"), ("lrctxt", "1"), ("man", "no"),
        ]
        let lrcURL = "https://lyrics.kugou.com/v1/search?"
            + kgQuery(params: lrcParams, module: "Lyric", mid: mid)
        guard let lrcJson = try? await APIClient.shared.getJSON(
            lrcURL, headers: kgHeaders(module: "Lyric", mid: mid), timeout: netTimeout),
              let cands = lrcJson["candidates"] as? [[String: Any]],
              let first = cands.first,
              let cid = first["id"] as? String, !cid.isEmpty,
              let accesskey = first["accesskey"] as? String, !accesskey.isEmpty else {
            return nil
        }
        let dlParams: [(String, String)] = [
            ("accesskey", accesskey), ("charset", "utf8"), ("client", "mobi"),
            ("fmt", "krc"), ("id", cid), ("ver", "1"),
        ]
        let dlURL = "https://lyrics.kugou.com/download?"
            + kgQuery(params: dlParams, module: "Lyric", mid: mid)
        guard let dlJson = try? await APIClient.shared.getJSON(
            dlURL, headers: kgHeaders(module: "Lyric", mid: mid), timeout: netTimeout),
              let content = dlJson["content"] as? String, !content.isEmpty,
              let decoded = Data(base64Encoded: content) else {
            return nil
        }
        let contentType = dlJson["contenttype"] as? Int ?? -1
        if contentType == 2 {
            // contenttype==2：content 是 base64 纯文本 LRC（没有逐字时间），头部同样带 [ti:]/[length:]
            let plain = String(data: decoded, encoding: .utf8) ?? ""
            let lrc = LyricsCleaning.parseLrc(plain)
            return lrc.isEmpty ? nil : (lines: lrc, meta: LyricsCleaning.meta(plain))
        }
        guard let plain = LddcCrypto.krcDecrypt([UInt8](decoded)) else { return nil }
        // KRC 解密后的明文是 `[id:$...] [ar:...] [ti:...] [total:...]` 开头 + 逐字行，
        // 元数据从这份明文取（`[total:261000]` 就是判 live 的关键）
        let meta = LyricsCleaning.meta(plain)
        let words = LddcCrypto.krcToLines(plain)
        if !words.isEmpty { return (lines: words, meta: meta) }
        // 兜底：逐字解析失败但明文能压成整行 LRC
        let fallback = LyricsCleaning.parseLrc(LddcCrypto.krcToLrc(plain))
        return fallback.isEmpty ? nil : (lines: fallback, meta: meta)
    }

    /// 设备 dfid 注册（酷狗搜索要求带 dfid；缓存 30 分钟）
    private static func kgRegisterDfid() async -> String? {
        if let hit = state.cachedDfid() { return hit }

        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let values = ["1014", "4", mid].sorted().joined()
        let signature = Digest.md5Hex("1014" + values + "1014")
        let url = "https://userservice.kugou.com/risk/v1/r_register_dev"
            + "?appid=1014&platid=4&mid=\(mid)&signature=\(signature)"
        let body = Data("{\"uuid\":\"\"}".utf8).base64EncodedString()
        guard let resp = try? await APIClient.shared.postString(
            url, body: body, contentType: "text/plain", timeout: netTimeout),
              let data = resp.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dfid = (json["data"] as? [String: Any])?["dfid"] as? String,
              !dfid.isEmpty else { return nil }

        state.store(dfid: dfid)
        return dfid
    }

    private static func kgHeaders(module: String, mid: String) -> [String: String] {
        [
            "User-Agent": "Android14-1070-11070-201-0-\(module)-wifi",
            "Connection": "Keep-Alive",
            "KG-Rec": "1",
            "KG-RC": "1",
            "KG-CLIENTTIMEMS": String(Int(Date().timeIntervalSince1970 * 1000)),
            "mid": mid,
        ]
    }

    /// 酷狗签名参数。`module == "Lyric"` 时只含 appid+clientver+业务参数（多塞会签名失配）
    static func kgQuery(params: [(String, String)], module: String, mid: String,
                        dfid: String = "-",
                        clientTime: Int = Int(Date().timeIntervalSince1970)) -> String {
        var all = params
        if module == "Lyric" {
            all.append(("appid", "3116"))
            all.append(("clientver", "11070"))
        } else {
            all.append(("userid", "0"))
            all.append(("appid", "3116"))
            all.append(("token", ""))
            all.append(("clienttime", String(clientTime)))
            all.append(("iscorrection", "1"))
            all.append(("uuid", "-"))
            all.append(("mid", mid))
            all.append(("dfid", dfid))
            all.append(("clientver", "11070"))
            all.append(("platform", "AndroidFilter"))
        }
        let sorted = all.sorted { $0.0 < $1.0 }
        let signature = Digest.md5Hex(
            kgSalt + sorted.map { "\($0.0)=\($0.1)" }.joined() + kgSalt)
        return sorted.map { "\($0.0)=\(APIClient.encode($0.1))" }.joined(separator: "&")
            + "&signature=\(signature)"
    }

    // ==================== QQ ====================



    private static func qqComm() -> [String: Any] {
        [
            "ct": 11, "cv": "1003006", "v": "1003006", "os_ver": "15",
            "phonetype": "24122RKC7C",
            "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
            "tmeAppID": "qqmusiclight", "nettype": "NETWORK_WIFI", "udid": "0",
        ]
    }

    private static func searchQq(title: String, artist: String) async -> [Candidate] {
        var comm = qqComm()
        await qqEnsureSession(&comm)
        let searchID = String(Int(Date().timeIntervalSince1970 * 1000))
        let param: [String: Any] = [
            "search_id": searchID,
            "remoteplace": "search.android.keyboard",
            "query": "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines),
            "search_type": 0, "num_per_page": 20, "page_num": 1,
            "highlight": 0, "nqc_flag": 0, "page_id": 1, "grp": 1,
        ]
        guard let data = await qqRequest(comm: comm, method: "DoSearchForQQMusicLite",
                                         module: "music.search.SearchCgiService", param: param),
              let items = (data["body"] as? [String: Any])?["item_song"] as? [[String: Any]] else {
            return []
        }
        var out: [Candidate] = []
        for item in items {
            let t = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let qid = item["id"] as? String ?? ""
            if t.isEmpty || qid.isEmpty { continue }
            let singer = ((item["singer"] as? [[String: Any]])?.first)?["name"] as? String ?? ""
            let album = ((item["album"] as? [String: Any])?["name"] as? String) ?? ""
            out.append(Candidate(source: "qq", title: t, artist: singer,
                                 durationSec: item["interval"] as? Int ?? 0,
                                 qqId: qid, qqSinger: singer, qqAlbum: album))
        }
        return out
    }

    private static func fetchQqLines(_ cand: Candidate) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        guard let qid = cand.qqId else { return nil }
        var comm = qqComm()
        await qqEnsureSession(&comm)
        let param: [String: Any] = [
            "albumName": b64(cand.qqAlbum ?? ""),
            "crypt": 1, "ct": 19, "cv": 2111,
            "interval": cand.durationSec,
            "lrc_t": 0, "qrc": 1, "qrc_t": 0, "roma": 1, "roma_t": 0,
            "singerName": b64(cand.qqSinger ?? cand.artist),
            "songID": Int(qid) ?? 0,
            "songName": b64(cand.title),
            "trans": 1, "trans_t": 0, "type": 0,
        ]
        guard let data = await qqRequest(comm: comm, method: "GetPlayLyricInfo",
                                         module: "music.musichallSong.PlayLyricInfo", param: param) else {
            return nil
        }
        let encrypted = data["lyric"] as? String ?? ""
        // 对齐 LDDC：qrc_t ≠ 0 用 qrc_t，否则用 lrc_t；该值 != "0" 才解密
        let qrcT = data["qrc_t"] as? Int ?? 0
        let lrcT = String(describing: data["lrc_t"] ?? "0")
        let effectiveT = qrcT != 0 ? String(qrcT) : lrcT
        if encrypted.isEmpty || effectiveT == "0" { return nil }
        guard let plain = LddcCrypto.qrcDecrypt(hex: encrypted) else { return nil }
        // QRC 明文 = `<Lyric_1 LyricType="1" LyricContent="[ti:...]..."/>`，头部元数据就在里面
        let meta = LyricsCleaning.meta(plain)
        let words = LddcCrypto.qrcToLines(plain)
        if !words.isEmpty { return (lines: words, meta: meta) }
        let fallback = LyricsCleaning.parseLrc(LddcCrypto.qrcToLrc(plain))
        return fallback.isEmpty ? nil : (lines: fallback, meta: meta)
    }

    /// 会话获取/复用（uid/sid/userip）：搜索与取词共用，少一次往返
    private static func qqEnsureSession(_ comm: inout [String: Any]) async {
        if let cached = state.session() {
            comm["uid"] = cached["uid"] ?? ""
            comm["sid"] = cached["sid"] ?? ""
            comm["userip"] = cached["userip"] ?? ""
            return
        }
        let param: [String: Any] = ["caller": 0, "uid": "0", "vkey": 0]
        guard let data = await qqRequest(comm: comm, method: "GetSession",
                                         module: "music.getSession.session", param: param),
              let session = data["session"] as? [String: Any] else { return }
        let snapshot: [String: String] = [
            "uid": session["uid"] as? String ?? "",
            "sid": session["sid"] as? String ?? "",
            "userip": session["userip"] as? String ?? "",
        ]
        state.store(session: snapshot)
        comm["uid"] = snapshot["uid"] ?? ""
        comm["sid"] = snapshot["sid"] ?? ""
        comm["userip"] = snapshot["userip"] ?? ""
    }

    private static func qqRequest(comm: [String: Any], method: String,
                                  module: String, param: [String: Any]) async -> [String: Any]? {
        let payload: [String: Any] = [
            "comm": comm,
            "request": ["method": method, "module": module, "param": param],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: bodyData, encoding: .utf8) else { return nil }
        guard let json = try? await APIClient.shared.postJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg", body: body,
            headers: ["Cookie": "tmeLoginType=-1;"], timeout: netTimeout),
              (json["code"] as? Int ?? -1) == 0,
              let request = json["request"] as? [String: Any],
              (request["code"] as? Int ?? -1) == 0 else { return nil }
        return request["data"] as? [String: Any]
    }

    private static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }
}

