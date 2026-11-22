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

    /// 最近一次取词"断在哪一环"（老板截图里的失败原因会带上它，r70）
    private final class DiagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
    }
    private static let diagBox = DiagBox()

    /// 酷狗取词**通道**层的最后一次结果（r71：lyrics.v1 失败 → krcs 老接口兜底，两跳都失败才写进诊断）
    private static let kgChannelBox = DiagBox()

    static func noteDiag(_ text: String) { diagBox.set(text) }
    static func lastDiagnostics() -> String { diagBox.get() }

    /// 最近一次"为什么没词"的**类别**（r78）。
    ///
    /// 为什么要分类：空态以前一律写"四个源都没取到词"，可《你好，再见》那次四个源是**都查过了**，
    /// 只是酷狗里只有一首同名不同人的《你好再见 / Butter》——按老板 r74 的口径"宁可空着也不贴另一版"，
    /// 这首本来就该空着。分不清"没有原唱词"和"我们没取到"，下一轮就会一直往网络/接口上查。
    enum MissKind: String, Sendable {
        case none = ""
        case noCandidates = "酷狗连候选都没搜到"
        case rejectedIdentity = "候选都过不了身份闸（只有别的版本/别人唱的）"
        /// 第 57 轮：最接近音源时长的那一版是纯音乐（《溺火》）
        case instrumental = "最接近音源时长的版本是纯音乐"
        case fetchFailed = "候选对得上，但取词接口没返回词"
    }
    private static let missBox = DiagBox()
    static func noteMiss(_ kind: MissKind) { missBox.set(kind.rawValue) }
    static func lastMiss() -> MissKind { MissKind(rawValue: missBox.get()) ?? .none }
    static func noteKgChannel(_ text: String) { kgChannelBox.set(text) }
    static func lastKgChannel() -> String { kgChannelBox.get() }
    private static let netTimeout: TimeInterval = 8
    /// 单条酷狗取词通道的封顶时间（r77：两条通道并行；每条通道内部 https 失败会再试一次 http）
    static let kgChannelDeadline: TimeInterval = 3.5
    /// 投给单个酷狗请求的时间（r77：以前是 8 秒，一次握手挂掉就能吃光整条链）
    static let kgAttemptTimeout: TimeInterval = 2.5
    /// 只有"快速失败"（连接/TLS 层就断，<1.2 秒）才值得换 http 再试——超时说明是慢网，换 http 一样慢
    static let kgFastFailureSeconds: TimeInterval = 1.2
    /// 酷狗搜索请求的时间（搜索正常 0.7~2.5 秒）
    static let kgSearchTimeout: TimeInterval = 3
    /// 酷狗取词在整条链里的预算（r77：不许把 8 秒总死线吃光，否则 ③④ 永远轮不上）
    static let chainBudgetSeconds: TimeInterval = 5.5
    private static let minScore = LddcMatch.minScore

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

    /// 全局截止时间（老板口径：全链 8 秒硬超时，对齐安卓 `withTimeoutOrNull(8000)`）
    static func withDeadline<T: Sendable>(seconds: Double,
                                          operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 入口：搜（酷狗 + QQ 内置并行）→ 身份闸 → 按分数取词（首选 + 重试一次 + 同类第 2 个）
    ///
    /// 老板 r74 定死的顺序（不要自行调换）：
    ///   1) 酷我平台的歌：酷我官方 `getlyric`（musicId 精确，1 个请求）—— 在 `LyricsService` 里先走；
    ///   2) 其余/酷我空词 → 酷狗逐字，但必须过身份闸：
    ///      歌手 ≥90 分 · 版本类一致（原版↔原版、Live↔Live）· 时长差 ≤4s · 词自报身份一致；
    ///   3) 回退**不许跨歌手、不许跨版本类**：首选失败先重试一次，仍失败就空着；
    ///   4) 全程 8 秒硬超时（由 `LyricsService` 兜住）。
    static func fetch(song: Song, audioSec: Int = 0) async -> LyricsResult? {
        let title = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = LyricsCleaning.cleanArtist(song.singer)
        guard !title.isEmpty else { return nil }
        let target = audioSec > 0 ? audioSec : song.durationSec

        noteMiss(.none)
        let candidates = await searchCandidates(title: title, artist: artist)
        guard !candidates.isEmpty else {
            noteDiag("酷狗搜「\(title) \(artist)」0 条候选")
            noteMiss(.noCandidates)
            return nil
        }
        guard let picked = await pickBest(candidates: candidates, title: title,
                                          artist: artist, targetSec: target) else { return nil }
        return result(picked, song: song)
    }

    /// 候选来源：酷狗 + QQ **内置并行**（第四十轮：老板定"QQ 歌词源直接内置，不用实验开关"）。
    ///
    /// QQ 这条给 2.5 秒上限：能带回来逐字（QRC）就赚，超时/被登录态拦住就直接丢，
    /// 绝不拖慢主链（主链仍然是酷狗）。
    private static func searchCandidates(title: String, artist: String) async -> [Candidate] {
        await withTaskGroup(of: [Candidate].self) { group in
            group.addTask { await searchKg(title: title, artist: artist) }
            group.addTask {
                await withDeadline(seconds: 2.5) { await searchQq(title: title, artist: artist) } ?? []
            }
            var out: [Candidate] = []
            for await list in group { out += list }
            return out
        }
    }

    /// 统一出口：来源标签写明"LDDC · 逐字/行级"，并把耗时带出去（详情页与诊断都看得到）
    private static func result(_ picked: Picked, song: Song) -> LyricsResult {
        let aligned = LyricsCleaning.alignedToAudio(picked.lines, declaredMs: picked.declaredMs,
                                                    audioSec: song.durationSec)
        let kind = picked.lines.contains(where: { $0.hasWordTiming }) ? "逐字" : "行级"
        return LyricsResult(lines: aligned.lines, source: "LDDC · " + kind, matchNote: picked.note)
    }

    /// 一次取词的结果
    struct Picked: Sendable {
        let lines: [LyricLine]
        let declaredMs: Int
        /// 人话说明「为什么选了这份词」（详情页「音源详情 → 歌词」会显示）
        var note: String = ""
    }

    /// 一个候选 + 它的分数（纯数据，CI 能直接断言排序与门槛）
    struct Ranked: Sendable {
        let candidate: Candidate
        let score: Double
        let titleScore: Double
        let artistScore: Double
        let durationDelta: Int
    }

    /// 最近一次"身份闸挡掉了谁"（写进空态诊断）
    private final class NoteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ v: String) { lock.lock(); text = v; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
    }
    private static let rejectBox = NoteBox()

    /// 打分 + 身份闸 + 排序（纯函数）
    ///
    /// 打分公式与 LDDC `auto_fetch` 完全一致（标题×0.5 + 歌手×0.5，标题<30 再 −35，及格 55）。
    /// 在它**之前**加一道身份闸（`LddcMatch.identityRejection`）：时长 / 歌手 / 版本类。
    /// 实测为什么必须有这道闸：
    ///   · 酷狗「发如雪 / 常颖杰 / 299s」标题 100 + 歌手 33.3 = **66.7 分**，能过 55 线；
    ///   · 酷狗「七里香 (Live) / 302s」73.1 分，时长只差 3 秒，也过线。
    /// 这两条一旦进池，首选取词一失败就会被当成"兜底"，于是播原唱放粤语版/现场版词。
    static func rank(_ candidates: [Candidate], title: String, artist: String,
                     targetSec: Int) -> [Ranked] {
        var kept: [Ranked] = []
        var rejected: [String] = []
        for cand in candidates {
            if let why = LddcMatch.identityRejection(queryTitle: title, queryArtist: artist,
                                                     candidateTitle: cand.title,
                                                     candidateArtist: cand.artist,
                                                     targetSec: targetSec,
                                                     candidateSec: cand.durationSec) {
                rejected.append("\(cand.title)：\(why)")
                continue
            }
            let ts = LddcMatch.titleScore(title, cand.title)
            let as_ = LddcMatch.artistScore(artist, cand.artist)
            let score = LddcMatch.score(title: title, candidateTitle: cand.title,
                                        artist: artist, candidateArtist: cand.artist)
            guard score > LddcMatch.minScore else { continue }
            kept.append(Ranked(candidate: cand, score: score, titleScore: ts, artistScore: as_,
                               durationDelta: (targetSec > 0 && cand.durationSec > 0)
                                   ? abs(targetSec - cand.durationSec) : Int.max))
        }
        kept.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.durationDelta < b.durationDelta
        }
        rejectBox.set(rejected.prefix(3).joined(separator: "；"))
        return kept
    }

    /// 取词：**同歌手同版本类**的候选里，首选 + 重试一次，再换第 2 个（各重试一次）。
    /// 绝不跨歌手/跨版本类去找"下一份词"——那正是 74 行粤语版与 58 行 Live 词的通路。
    ///
    /// 第 57 轮：严格池全空之后，再试**只差时长**的第二池（`nearMissPick`），
    /// 用词头 `[total:]`/`[ar:]` 自证后才收；两条都不过才写空态。
    static func pickBest(candidates: [Candidate], title: String, artist: String,
                         targetSec: Int) async -> Picked? {
        let ranked = rank(candidates, title: title, artist: artist, targetSec: targetSec)
        var failures = 0
        for item in ranked.prefix(2) {
            for pass in 1...2 {
                failures += 1
                if let one = await fetchOne(item.candidate, songTitle: title, songArtist: artist) {
                    noteDiag("候选 \(candidates.count) 条，第 \(failures) 次取到词")
                    let note = "《\(item.candidate.title)》· \(item.candidate.artist)"
                        + " · 目标 \(targetSec)s / 候选 \(item.candidate.durationSec)s"
                        + " · 标题 \(Int(item.titleScore)) · 歌手 \(Int(item.artistScore))"
                        + " · 合计 \(Int(item.score))"
                        + (pass > 1 ? "（第 \(pass) 次尝试）" : "")
                    return Picked(lines: one.lines, declaredMs: one.meta.durationMs, note: note)
                }
                if pass == 1 {
                    // 首选失败**先重试自己一次**（换 mid 重新签名），不要立刻退到别的候选
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        // 第二池：只差时长的候选，词头自证后才收（第 57 轮）
        if let near = await nearMissPick(candidates: candidates, title: title,
                                         artist: artist, targetSec: targetSec) {
            return near
        }
        if ranked.isEmpty {
            let blocked = rejectBox.get()
            noteDiag("候选 \(candidates.count) 条，没有一条过身份闸（\(blocked.isEmpty ? "分数不够" : blocked)）")
            let instrumental = LddcMatch.closestIsInstrumental(
                queryTitle: title, targetSec: targetSec,
                candidates: candidates.map { (title: $0.title, durationSec: $0.durationSec) })
            noteMiss(instrumental ? .instrumental : .rejectedIdentity)
            return nil
        }
        var diag = "候选 \(candidates.count) 条（最高 \(Int(ranked[0].score)) 分），前 \(failures) 次都没取到词"
        let channel = lastKgChannel()
        if !channel.isEmpty { diag += "，" + channel }
        noteDiag(diag)
        return nil
    }

    /// 第二池：歌名像、版本类一致，只是时长差出 ±4s 的候选。
    ///
    /// 为什么要有：《海屿你》的候选词头是 `[ar:大头针][ti:海屿你][total:288000]`，
    /// 歌名/歌手/总时长全都自证对得上，只是音源少了 10s 尾巴；《우주를 줄게》更冤——
    /// 同一个歌手在平台里写的是中文名「脸红的思春期」，搜索候选的歌手分是 0，可词头里写着
    /// `[ar:볼빨간사춘기 (脸红的思春期)]`。两首都该收，但必须让**词自己**先证明身份：
    /// `selfReportReason`（歌名+歌手） + `headerDurationOK`（词头 total 与音源差 ≤8%）。
    private static func nearMissPick(candidates: [Candidate], title: String,
                                     artist: String, targetSec: Int) async -> Picked? {
        let pool = LddcMatch.nearMissPool(
            queryTitle: title, targetSec: targetSec,
            candidates: candidates.map { (title: $0.title, durationSec: $0.durationSec) })
        guard !pool.isEmpty else { return nil }
        // 时长最接近的优先
        let ordered = pool.sorted {
            abs(targetSec - candidates[$0].durationSec) < abs(targetSec - candidates[$1].durationSec)
        }
        for idx in ordered.prefix(2) {
            let cand = candidates[idx]
            guard let one = await fetchOne(cand, songTitle: title, songArtist: artist) else { continue }
            let declared = one.meta.durationMs / 1000
            guard LddcMatch.headerDurationOK(targetSec: targetSec, declaredSec: declared) else {
                noteKgChannel("《\(cand.title)》词头 total=\(declared)s 与音源 \(targetSec)s 差得太多，不收")
                continue
            }
            let pct = Double(abs(declared - targetSec)) / Double(max(1, targetSec)) * 100
            noteDiag("严格池没词，用词头自证收了《\(cand.title)》（\(String(format: "%.1f", pct))% 时长差）")
            let note = "《\(cand.title)》· \(cand.artist)"
                + " · 词头自证（音源 \(targetSec)s / 词头 \(declared)s）"
            return Picked(lines: one.lines, declaredMs: declared * 1000, note: note)
        }
        return nil
    }

    /// 单个候选取词：解密 → 乱码/行数门槛 → **词自报身份校验**
    private static func fetchOne(_ cand: Candidate, songTitle: String,
                                 songArtist: String) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        let fetched: (lines: [LyricLine], meta: LyricsMeta)?
        switch cand.source {
        case "kg": fetched = await fetchKgLines(cand)
        case "qq": fetched = await fetchQqLines(cand)
        default: fetched = nil
        }
        guard let fetched, !fetched.lines.isEmpty else { return nil }
        if LyricsCleaning.isBroken(fetched.lines.map(\.text).joined(separator: "\n")) { return nil }
        guard fetched.lines.count >= 6 else { return nil }
        // r74：词自己写的 [ti:]/[ar:] 或首行，必须与**正在播放**的这首一致。
        // 酷狗那条「发如雪 / 常颖杰 / 299s」的 KRC 头是 `[ti:发如雪][ar:常颖杰]` —— 歌名对得上、
        // 歌手对不上，正是靠这一层抓住了 74 行粤语版。
        if let reason = LyricsCleaning.selfReportReason(meta: fetched.meta,
                                                        firstLine: fetched.lines.first?.text,
                                                        songTitle: songTitle,
                                                        songArtist: songArtist) {
            noteKgChannel("取到的词不是这首：" + reason)
            return nil
        }
        return fetched
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
            url, headers: kgHeaders(module: "SearchSong", mid: mid), timeout: kgSearchTimeout),
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

    /// 一条通道抢到的结果（带通道号，写进诊断用）
    private struct KgChannelHit: Sendable {
        let channel: Int
        let lines: [LyricLine]?
        let meta: LyricsMeta?
    }

    private static func fetchKgLines(_ cand: Candidate) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        // 通道 1：lyrics.kugou.com/v1（LDDC 原来那条）
        // 通道 2（r71）：krcs.kugou.com 老接口——**不同主机、不同限流池**。
        //
        // r77：两条通道**并行抢答**，谁先解密出合格歌词就用谁。
        // 以前是"通道 1 失败才走通道 2"（串行）：真机上通道 1 一挂就要等满 8 秒超时，
        // 通道 2 根本还没发出去就已经撞上 8 秒总死线——老板截图里"酷狗取词两条通道都没成"
        // 有一半是这么来的。现在每条通道各自 3.5 秒封顶（内部还带 https→http 兜底），
        // 两条同时打，最坏 3.5 秒出结果。
        let hit = await withTaskGroup(of: KgChannelHit.self) { group -> KgChannelHit? in
            group.addTask {
                let one = await withDeadline(seconds: kgChannelDeadline) {
                    await fetchKgViaLyricsV1(cand)
                } ?? nil
                return KgChannelHit(channel: 1, lines: one?.lines, meta: one?.meta)
            }
            group.addTask {
                let one = await withDeadline(seconds: kgChannelDeadline) {
                    await fetchKgViaKrcs(cand)
                } ?? nil
                return KgChannelHit(channel: 2, lines: one?.lines, meta: one?.meta)
            }
            var winner: KgChannelHit?
            for await item in group where item.lines != nil {
                winner = item
                break
            }
            group.cancelAll()
            return winner
        }
        guard let hit, let lines = hit.lines, let meta = hit.meta else {
            noteKgChannel("酷狗取词两条通道都没成（lyrics.v1 + krcs 并行，各自 https→http 两试）")
            noteMiss(.fetchFailed)
            return nil
        }
        noteKgChannel(hit.channel == 1 ? "" : "lyrics.v1 没抢到，krcs 兜住了")
        return (lines: lines, meta: meta)
    }

    /// 酷狗歌词请求（r77）：先走 https，不通再**同一台主机的 http** 试一次。
    ///
    /// 为什么要这条：老板那台 iPhone 上出现过"搜索宿主 complexsearch 通、两个取词宿主
    /// （lyrics.kugou.com / krcs.kugou.com）都不通"的形状，而同一时刻本机两条通道都正常。
    /// 最典型的一类原因是运营商/代理按 SNI 掐 TLS——握手阶段就失败，80 端口却是通的。
    /// 歌词是公开数据、不走鉴权，明文没有额外风险（Info.plist 里本来就有
    /// `NSAllowsArbitraryLoads`），所以这条兜底值得留着；https 通的时候它一次都不会发生。
    private static func kgGetJSON(_ httpsURL: String, module: String,
                                  mid: String) async -> [String: Any]? {
        let headers = kgHeaders(module: module, mid: mid)
        let began = Date()
        if let json = try? await APIClient.shared.getJSON(httpsURL, headers: headers,
                                                          timeout: kgAttemptTimeout) {
            return json
        }
        // 超时（慢网）不换 http：一样的路，一样慢，白花时间
        guard Date().timeIntervalSince(began) < kgFastFailureSeconds,
              httpsURL.hasPrefix("https://") else { return nil }
        let plain = "http://" + httpsURL.dropFirst("https://".count)
        return try? await APIClient.shared.getJSON(plain, headers: headers,
                                                   timeout: kgAttemptTimeout)
    }

    /// 通道 1：`lyrics.kugou.com/v1/search` → `accesskey` → `/download`（带签名）
    private static func fetchKgViaLyricsV1(_ cand: Candidate) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        guard let id = cand.kgId, let hash = cand.kgHash else { return nil }
        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let durMs = cand.durationSec * 1000
        let lrcParams: [(String, String)] = [
            ("album_audio_id", id), ("duration", String(durMs)), ("hash", hash),
            ("keyword", "\(cand.artist) - \(cand.title)"), ("lrctxt", "1"), ("man", "no"),
        ]
        let lrcURL = "https://lyrics.kugou.com/v1/search?"
            + kgQuery(params: lrcParams, module: "Lyric", mid: mid)
        guard let lrcJson = await kgGetJSON(lrcURL, module: "Lyric", mid: mid),
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
        guard let dlJson = await kgGetJSON(dlURL, module: "Lyric", mid: mid) else { return nil }
        return decodeKrcDownload(dlJson)
    }

    /// 通道 2（r71）：`krcs.kugou.com/search`（**不需要签名**，按关键词返回一批候选）
    /// → 自己在候选里按「歌名像 + 歌手像」挑一条 → `/download` 拿 KRC。
    ///
    /// 为什么要它：`lyrics.kugou.com` 对同一出口 IP 的限流比 `krcs.kugou.com` 敏感得多，
    /// 而两条通道返回的是同一批歌词。取词链上多一条独立主机，就少一次"整首没词"。
    private static func fetchKgViaKrcs(_ cand: Candidate) async -> (lines: [LyricLine], meta: LyricsMeta)? {
        guard let hash = cand.kgHash, !hash.isEmpty else { return nil }
        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let searchParams: [(String, String)] = [
            ("ver", "1"), ("man", "yes"), ("client", "mobi"),
            ("keyword", "\(cand.title) - \(cand.artist)"),
            ("duration", String(cand.durationSec * 1000)), ("hash", hash),
        ]
        let searchURL = "https://krcs.kugou.com/search?" + plainQuery(searchParams)
        guard let json = await kgGetJSON(searchURL, module: "Lyric", mid: mid),
              let list = json["candidates"] as? [[String: Any]], !list.isEmpty else {
            return nil
        }
        var best: (id: String, accesskey: String, score: Double)?
        var rejected: [String] = []
        for item in list {
            let songName = item["song"] as? String ?? ""
            let singer = item["singer"] as? String ?? ""
            guard let cid = item["id"] as? String, !cid.isEmpty,
                  let accesskey = item["accesskey"] as? String, !accesskey.isEmpty else { continue }
            let ts = LddcMatch.titleScore(cand.title, songName)
            let as_ = LddcMatch.artistScore(cand.artist, singer)
            // r78：这里以前只要求「标题×0.5 + 歌手×0.5 ≥ 50」，等于**主要看标题**
            // （歌手 0 分也能靠标题撑到线上）。实锤：《你好，再见 / 常力俊 / 244s》在酷狗
            // 只有一条同名不同人的《你好再见 / Butter / 244s》——歌手 0 分、标题 88.9 分，
            // 合计 44.4 分，这一首**刚好**被旧口径挡掉了；但同形状换个标点更接近的歌名就会放过。
            // 现在与主链同一个口径（歌手 ≥ `artistGateScore`、标题 ≥ 50），
            // 并把这批被拒的候选写进诊断——空态才说得清"是只有别的版本，不是没取到"。
            guard as_ >= LddcMatch.artistGateScore, ts >= 50 else {
                rejected.append("\(songName) / \(singer)")
                continue
            }
            let score = ts * 0.5 + as_ * 0.5
            if best == nil || score > (best?.score ?? 0) { best = (cid, accesskey, score) }
        }
        // 挑不到"歌名/歌手都对得上"的就别下——避免把别人的词贴上来
        guard let best else {
            if !rejected.isEmpty {
                noteKgChannel("酷狗只有别的版本（" + rejected.prefix(2).joined(separator: "、") + "）")
                noteMiss(.rejectedIdentity)
            }
            return nil
        }
        let dlParams: [(String, String)] = [
            ("ver", "1"), ("client", "mobi"), ("id", best.id),
            ("accesskey", best.accesskey), ("fmt", "krc"), ("charset", "utf8"),
        ]
        let dlURL = "https://krcs.kugou.com/download?" + plainQuery(dlParams)
        guard let dlJson = await kgGetJSON(dlURL, module: "Lyric", mid: mid) else { return nil }
        return decodeKrcDownload(dlJson)
    }

    /// 两条通道共用的"下载响应 → 歌词行"：contenttype==2 是纯 LRC，否则是 XOR+zlib 的 KRC。
    private static func decodeKrcDownload(_ dlJson: [String: Any]) -> (lines: [LyricLine], meta: LyricsMeta)? {
        guard let content = dlJson["content"] as? String, !content.isEmpty,
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

    /// 不带签名的查询串（krcs.kugou.com 的老接口只要普通参数）
    static func plainQuery(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\(APIClient.encode($0.1))" }.joined(separator: "&")
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

