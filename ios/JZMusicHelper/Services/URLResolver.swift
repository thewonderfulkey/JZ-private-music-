import Foundation

// MARK: - 解析事件（供 UI 边解析边显示）
enum ResolveEvent {
    case started(String)                 // 后端名
    case success(StreamSource)
    case failed(String, String)          // 后端名, 错误
    case finished
}

/// 跨轮次复用的"已试过的候选"集合（Android 侧是 MutableSet，这里用引用类型避免 inout 跨 await）
final class TriedKeys: @unchecked Sendable {
    // 注意：属性不能叫 `set`——和属性 setter 的关键字冲突（`var count: Int { set.count }` 会被当成 setter 定义）
    private(set) var keys: Set<String> = []
    var count: Int { keys.count }
    func contains(_ k: String) -> Bool { keys.contains(k) }
    func insert(_ k: String) { keys.insert(k) }
}

// MARK: - 并发取流
/// 与 Android `UrlResolver` 同口径：一首歌同时问它自己平台的所有后端，收集全部成功结果；
/// 单后端 12s 超时，失败只计入 failed，**绝不外抛**。
final class URLResolver {

    static let shared = URLResolver()

    let perBackendTimeout: TimeInterval = 12

    private init() {}

    struct ResolveResult: Sendable {
        let sources: [StreamSource]
        let failed: [String: String]
    }

    func resolveAll(song: Song, quality: QualityLevel) async -> [StreamSource] {
        await resolveResult(song: song, quality: quality).sources
    }

    func resolveResult(song: Song, quality: QualityLevel,
                       timeout: TimeInterval? = nil) async -> ResolveResult {
        let adapters = SourceRegistry.adapters(for: song)
        let limit = timeout ?? perBackendTimeout
        let outcomes = await withTaskGroup(of: (String, StreamSource?, String).self) { group in
            for adapter in adapters {
                group.addTask {
                    do {
                        let src = try await withTimeoutThrowing(limit) {
                            try await adapter.resolve(song: song, quality: quality)
                        }
                        return (adapter.name, src, "")
                    } catch {
                        return (adapter.name, nil, Self.shortError(error))
                    }
                }
            }
            var out: [(String, StreamSource?, String)] = []
            for await o in group { out.append(o) }
            return out
        }
        var sources: [StreamSource] = []
        var failed: [String: String] = [:]
        for (name, src, reason) in outcomes {
            if let src { sources.append(src) } else { failed[name] = reason.isEmpty ? "失败或超时" : reason }
        }
        return ResolveResult(sources: sources, failed: failed)
    }

    /// 错误压成一句能塞进弹层诊断的短语（超时 / 解析 / 没拿到 URL / 探测失败…）
    static func shortError(_ error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .timeout: return "超时"
            case .parse(let m): return "解析失败(\(m.prefix(20)))"
            case .httpStatus(let code): return "HTTP \(code)"
            case .invalidURL: return "URL 无效"
            case .invalidResponse: return "响应无效"
            case .notJSON: return "非 JSON"
            }
        }
        let text = "\(error)"
        if text.contains("timed out") || text.contains("超时") { return "超时" }
        return String(text.prefix(24))
    }

    /// 流式解析（UI 用：后端逐个点亮）
    func resolve(song: Song, quality: QualityLevel) -> AsyncStream<ResolveEvent> {
        AsyncStream { continuation in
            let task = Task {
                let adapters = SourceRegistry.adapters(for: song)
                for a in adapters { continuation.yield(.started(a.name)) }
                let result = await self.resolveResult(song: song, quality: quality)
                for s in result.sources { continuation.yield(.success(s)) }
                for (name, err) in result.failed { continuation.yield(.failed(name, err)) }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 按音质挑源
/// 与 Android `SourcePicker` 同口径：无损优先真无损容器 → 标注无损 → 高品 → 标准；m4a 降权；
/// 同分优先「按平台 ID 直连」的后端（身份可靠），搜索式取流后置。
enum SourcePicker {

    static func pick(_ sources: [StreamSource], want: QualityLevel) -> StreamSource? {
        guard !sources.isEmpty else { return nil }
        return sources.max { a, b in
            let sa = score(a, want: want)
            let sb = score(b, want: want)
            if sa != sb { return sa < sb }
            return (a.directId ? 1 : 0) < (b.directId ? 1 : 0)
        }
    }

    static func score(_ src: StreamSource, want: QualityLevel) -> Int {
        let fmt = src.format.lowercased()
        let isLosslessFormat = fmt.contains("flac") || fmt.contains("ape") || fmt.contains("wav")
        var base: Int
        switch want {
        case .lossless:
            if src.quality == .lossless && isLosslessFormat { base = 5 }
            else if src.quality == .lossless { base = 4 }
            else if src.quality == .high { base = 2 }
            else if src.quality == .standard { base = 1 }
            else { base = 0 }
        case .high:
            if src.quality == .high && !fmt.contains("m4a") { base = 4 }
            else if src.quality == .high { base = 3 }
            else if src.quality == .lossless { base = 3 }
            else if src.quality == .standard { base = 1 }
            else { base = 0 }
        case .standard:
            base = src.quality == .standard ? 2 : 1
        }
        return base - (src.directId ? 0 : 1)
    }
}

// MARK: - 同曲跨平台补源
/// 与 Android `SameSongCrossResolver` 同口径。
/// 背景：猜你喜欢/热门/自动连播带的是"来源平台"的 ID，本平台后端一挂就判无源并跳过；
/// 而同一首歌在其它平台的条目（搜索里能秒解析的那条）从未被尝试过。
/// 做法：用与搜索完全相同的适配器搜「歌名+歌手」，取同曲候选逐个解析；全部失败才返回 nil。
enum SameSongCrossResolver {

    static let maxCandidates = 8
    static let maxExactKeep = 3
    static let totalTimeout: TimeInterval = 45

    /// 播放用：拿到一条可用源就返回
    static func resolve(song: Song, quality: QualityLevel,
                        triedKeys: TriedKeys) async -> StreamSource? {
        await withTimeoutOrNil(totalTimeout) {
            let candidates = await candidateList(
                song: song, quality: quality, triedKeys: triedKeys, forDownload: false).songs
            var picked: StreamSource?
            for batch in candidates.chunked(3) {
                if picked != nil { break }
                let got = await withTaskGroup(of: StreamSource?.self) { group in
                    for c in batch {
                        group.addTask {
                            let r = await URLResolver.shared.resolveResult(song: c, quality: quality)
                            return SourcePicker.pick(r.sources, want: quality)
                        }
                    }
                    var out: [StreamSource?] = []
                    for await s in group { out.append(s) }
                    return out
                }
                picked = got.first { $0 != nil } ?? nil
            }
            return picked
        } ?? nil
    }

    struct CrossOutcome: Sendable {
        let exact: StreamSource?
        let best: StreamSource?
        let exacts: [StreamSource]
        /// 每个候选失败的一句话原因（最多 4 条，弹层诊断用）
        var failures: [String] = []
        /// 候选按平台的分布（"网易2/酷狗3/QQ1"）：排查"搜索没搜到网易"这类问题用
        var candidateSummary: String = ""
        /// 网易专用检索的实况（"官方0/gdstudio0/meting6"）
        var neteaseDebug: String = ""
        /// 网易官方检索**实际请求的 URL（已解码）**——`s` 被拼坏时一眼可见
        var neteaseURL: String = ""
        /// 网易官方检索**响应的前 3 条** "歌名|歌手|时长s"
        var neteaseTop: [String] = []

        static let empty = CrossOutcome(exact: nil, best: nil, exacts: [], failures: [])
    }

    /// 一轮候选检索的全部产出（候选 + 网易检索的留痕，供弹层诊断）
    struct CandidateSet: Sendable {
        var songs: [Song] = []
        var neteaseDebug: String = ""
        var neteaseURL: String = ""
        var neteaseTop: [String] = []
    }

    /// 下载用：一次遍历同时求「目标档」与「最高可得档」
    static func resolveForDownload(song: Song, want: QualityLevel,
                                   triedKeys: TriedKeys) async -> CrossOutcome {
        await withTimeoutOrNil(totalTimeout) {
            let found = await candidateList(
                song: song, quality: want, triedKeys: triedKeys, forDownload: true)
            let candidates = found.songs
            var exact: StreamSource?
            var best: StreamSource?
            var exacts: [StreamSource] = []
            var failures: [String] = []
            let byPlatform = Dictionary(grouping: candidates, by: { $0.platform.shortName })
            let summary = byPlatform.map { "\($0.key)\($0.value.count)" }.sorted().joined(separator: "/")

            for batch in candidates.chunked(3) {
                if exacts.count >= maxExactKeep { break }
                let got = await withTaskGroup(of: (StreamSource?, String).self) { group in
                    for c in batch {
                        group.addTask {
                            let r = await URLResolver.shared.resolveResult(song: c, quality: want, timeout: 18)
                            if let s = SourcePicker.pick(r.sources, want: want) {
                                return (s, "")
                            }
                            // 失败原因（弹层诊断用）："网易·gdstudio 网易:超时" 这种
                            let reason = r.failed.map { "\($0.key):\($0.value)" }
                                .joined(separator: "/")
                            return (nil, "\(c.platform.shortName)·\(reason.isEmpty ? "无源" : reason)")
                        }
                    }
                    var out: [(StreamSource?, String)] = []
                    for await o in group { out.append(o) }
                    return out
                }
                for (s, reason) in got {
                    if let s {
                        if s.quality == want {
                            if exact == nil { exact = s }
                            if !exacts.contains(where: { $0.url == s.url }) { exacts.append(s) }
                        }
                        if let cur = best {
                            if s.quality.sortOrder > cur.quality.sortOrder { best = s }
                        } else {
                            best = s
                        }
                    } else if !reason.isEmpty, failures.count < 4 {
                        failures.append(reason)
                    }
                }
            }
            return CrossOutcome(exact: exact, best: best, exacts: exacts,
                                failures: failures, candidateSummary: summary,
                                neteaseDebug: found.neteaseDebug,
                                neteaseURL: found.neteaseURL,
                                neteaseTop: found.neteaseTop)
        } ?? .empty
    }

    static func candidateList(song: Song, quality: QualityLevel,
                              triedKeys: TriedKeys, forDownload: Bool) async -> CandidateSet {
        let kw = "\(song.name) \(song.singer)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return CandidateSet() }
        let results = await SearchService.shared.searchAll(keyword: kw, limit: 30)
        var cands = results.flatMap { $0.songs }
        var out = CandidateSet()

        // r124：下载换源额外跑一遍「网易 id 专用检索」。
        // r126（2026-11-19 老板口径）：检索**不再以"返回条数 > 0"判成功**——真机上官方回了 10 条
        // 与我歌无关的热门歌（爱情转移/富士山下），旧实现直接 return，gdstudio/meting 两条兜底
        // 一次都没跑。现在由 `NeteaseLookup.lookup` 自己用 `NameMatch.sameRecording` 验收，
        // 只有"至少 1 条真是这首歌"才算成功，并把实际请求 URL 与响应前 3 条带出来做留痕。
        if forDownload {
            let lookup = await NeteaseLookup.lookup(keyword: kw, src: song)
            cands.append(contentsOf: lookup.songs)
            out.neteaseDebug = lookup.debug
            out.neteaseURL = lookup.url
            out.neteaseTop = lookup.top
        }

        cands = cands.filter { sameSong(src: song, cand: $0) }
        // 按 key 去重（同曲可能在多个源里都出现），保留先出现的
        var seenKeys = Set<String>()
        cands = cands.filter { seenKeys.insert(candKey($0)).inserted }
        cands = cands.filter { !triedKeys.contains(candKey($0)) }

        // 排序（第三十四轮 + r120）：**先挑"能出目标档"的平台**，再"干净原唱永远优先"，最后才看同平台/时长。
        //
        // r120（《연애의 조건》）：以前「同平台优先」排在最前，QQ 那三条 128k 候选先被逐个解析，
        // 网易那条真无损排在后面；真机上预算一紧就"还没轮到网易就收工"，弹层于是写着"只有 128k"。
        // 现在按平台能力排序——无损先网易（gdstudio 稳定出 fLaC），320k/128k 也先网易（唯一按 br 给档的）。
        if forDownload {
            cands.sort { a, b in
                let ra = downloadPlatformRank(a.platform, want: quality)
                let rb = downloadPlatformRank(b.platform, want: quality)
                if ra != rb { return ra < rb }
                let ca = StudioPick.isCleanTitle(a.name) && !StudioPick.isLiveAlbum(a.album)
                let cb = StudioPick.isCleanTitle(b.name) && !StudioPick.isLiveAlbum(b.album)
                if ca != cb { return ca && !cb }
                let pa = a.platform == song.platform ? 0 : 1
                let pb = b.platform == song.platform ? 0 : 1
                if pa != pb { return pa < pb }
                let da = abs(a.durationSec - song.durationSec)
                let db = abs(b.durationSec - song.durationSec)
                if da != db { return da < db }
                return StudioPick.studioScore(a) > StudioPick.studioScore(b)
            }
        } else {
            cands.sort { a, b in
                let ca = StudioPick.isCleanTitle(a.name) && !StudioPick.isLiveAlbum(a.album)
                let cb = StudioPick.isCleanTitle(b.name) && !StudioPick.isLiveAlbum(b.album)
                if ca != cb { return ca && !cb }
                let pa = a.platform == song.platform ? 0 : 1
                let pb = b.platform == song.platform ? 0 : 1
                if pa != pb { return pa < pb }
                let da = abs(a.durationSec - song.durationSec)
                let db = abs(b.durationSec - song.durationSec)
                if da != db { return da < db }
                return StudioPick.studioScore(a) > StudioPick.studioScore(b)
            }
        }

        // 去重 + 取前 N（去重按 key，保持排序）
        var seen = Set<String>()
        var unique: [Song] = []
        for c in cands where seen.insert(candKey(c)).inserted {
            if unique.count >= maxCandidates { break }
            unique.append(c)
        }
        for c in unique { triedKeys.insert(candKey(c)) }
        out.songs = unique
        return out
    }

    static func candKey(_ s: Song) -> String { "\(s.platform.rawValue)_\(s.platformID)" }

    /// 这个平台的取流后端还能不能真的产出该档位（实测：320k/128k 只有网易有戏）
    static func tierCapable(_ platform: MusicPlatform, want: QualityLevel) -> Bool {
        want == .lossless ? true : platform == .netease
    }

    /// 下载换源时的平台优先次序（越小越先解析）：**能出目标档的平台排前面**
    ///
    /// 真实能力（2026-11-19 实测）：
    ///   · 网易 gdstudio：br=740 → 真 fLaC（25MB / 1087kbps），br=320/128 也是真档位；
    ///   · 酷我 妖狐：经常回 fLaC，但走"搜索式"取流，慢一些；
    ///   · 酷狗 playInfo：主要是 mp3；
    ///   · QQ cyapi：固定 ~97kbps 的 m4a，永远出不了 320k/无损。
    /// 所以以前"同平台 QQ 先解析"等于先烧预算再轮到大鱼，真机上经常没轮到就超时。
    static func downloadPlatformRank(_ platform: MusicPlatform, want: QualityLevel) -> Int {
        switch want {
        case .lossless:
            switch platform {
            case .netease: return 0
            case .kuwo: return 1
            case .kugou: return 2
            case .qq: return 3
            }
        case .high, .standard:
            switch platform {
            case .netease: return 0
            case .kugou: return 1
            case .kuwo: return 2
            case .qq: return 3
            }
        }
    }

    /// 同曲判定：统一走 `NameMatch.sameRecording`（歌手优先 + 时长 ≤4s + 歌名只做辅助）。
    ///
    /// 2026-11-19 老板口径重写：旧口径要求「歌名归一化相等」，把《恋爱的条件》与
    /// 《연애의 조건 (Love Options)》判成两首歌，于是译名不同的真无损候选全被挡在门外。
    /// 现在歌名只在「时长未知」时兜底，不再是否决项；版本类标记仍然拦（见 `NameMatch.versionClass`）。
    static func sameSong(src: Song, cand: Song) -> Bool {
        NameMatch.sameRecording(src: src, cand: cand)
    }
}

// MARK: - 下载取源编排（老板 2026-11-19 口径：全收集 → 身份淘汰 → 打分排序 → 取第一 → 校验 → 退第二）
//
// 旧实现是"谁先回来用谁"：本平台先解析 → 跨源分三批 → 攒够 3 条目标档就 break。
// 对《연애의 조건》这类歌，QQ·cyapi 的 97kbps m4a 往往第一个回来，就被当成了结果。
//
// 现在的固定顺序（**只用于下载链**；播放链是另一套"先粗后精"窗口策略，见 `quickPick`）：
//   ① 收集：本平台后端 + 妖狐 + 跨源候选（网易/酷狗/QQ）全部发出去，总预算 15s，到期用已收到的；
//   ② 身份闸（淘汰制）：歌手交集 / 时长 ≤4s / 版本类一致——不过的直接淘汰，不参与排名；
//   ③ 打分：档位 > 版本 > 时长贴近 > 来源可靠性 > 响应速度（只在同分时用）；
//   ④ 取第一，下载前校验（体积 / 容器 / 码率量级）；
//   ⑤ 校验不过退第二名——仍然只能是被身份闸放行的同曲同版本，绝不降到别人的歌。
enum DownloadResolver {

    // MARK: 打分（顺序不可反，改权重可以，改顺序不行）
    struct Score: Sendable, Comparable {
        /// ① 音质档位：无损(FLAC/≥800k) > 320k > 256k > 128k
        let tier: Int
        /// ② 版本匹配度：原唱 > 官方 Live > 其它
        let version: Int
        /// ③ 时长贴近度（越大越贴近）
        let duration: Int
        /// ④ 来源可靠性：实测有体积/码率、Range 正常、官方 CDN 直链优先
        let reliable: Int
        /// ⑤ 响应速度：**只在同分时**用（越小越前）
        let ms: Int

        static func < (a: Score, b: Score) -> Bool {
            if a.tier != b.tier { return a.tier < b.tier }
            if a.version != b.version { return a.version < b.version }
            if a.duration != b.duration { return a.duration < b.duration }
            if a.reliable != b.reliable { return a.reliable < b.reliable }
            return a.ms > b.ms
        }

        /// 诊断里那串 "1000/300/100/110"（档/版/时/可靠）
        var short: String { "\(tier)/\(version)/\(duration)/\(reliable)" }
    }

    struct Candidate: Sendable {
        let song: Song
        let source: StreamSource
        let elapsedMs: Int
        let score: Score
    }

    struct Plan: Sendable {
        let want: QualityLevel
        /// 排名第一且**通过下载前校验**的目标档候选
        let picked: Candidate?
        /// 全部通过身份闸的候选（已按分数降序），诊断/验收用的完整排名表
        let ranked: [Candidate]
        /// 目标档一个都不可用时的最高可得档（仍需用户点头才下）
        let fallback: StreamSource?
        let switched: Bool
        let notes: [String]
        let debug: [String]

        var exact: [StreamSource] { picked.map { [$0.source] } ?? [] }
        var empty: Bool { picked == nil && fallback == nil }
        var fallbackReason: String {
            let best = fallback?.quality.displayName ?? "—"
            return "没有\(want.displayName)，最高可得\(best)"
        }
    }

    /// 收集总预算（到期就用已收到的候选；不再"谁先回用谁"）
    static let collectDeadline: TimeInterval = 15
    /// 单个后端上限
    static let perBackend: TimeInterval = 12
    /// 播放链质量窗口（先粗后精；窗口内挑最高分，超时先起播）
    static let playWindow: TimeInterval = 1.8

    // MARK: 主流程

    static func plan(song: Song, want: QualityLevel,
                     deadline: TimeInterval = collectDeadline) async -> Plan {
        let start = Date()
        var notes: [String] = []
        var debug: [String] = []
        debug.append("源曲 \(song.name) | \(song.singer) | \(song.durationSec)s | \(song.platform.shortName)")

        // ① 收集：两条线并发
        //    A. 本平台后端 + 妖狐（不需要搜索，最快出结果）
        //    B. 搜索同曲候选（含网易专用检索），拿到后逐个解析
        //    A 从 t=0 开始；B 的解析受剩余预算约束。总耗时 ≈ max(A, 搜索 + B)。
        async let primaryTask = collect(jobs: primaryJobs(for: song), want: want, deadline: deadline)
        let found = await SameSongCrossResolver.candidateList(
            song: song, quality: want, triedKeys: TriedKeys(), forDownload: true)
        let left = max(4, deadline - Date().timeIntervalSince(start))
        async let crossTask = collect(jobs: crossJobs(for: found.songs), want: want, deadline: left)
        let primary = await primaryTask
        let cross = await crossTask

        // ② 身份闸（淘汰制，不是打分）
        var gated: [RawCandidate] = []
        var gateDropped: [String] = []
        for r in primary + cross {
            if r.song.id == song.id { gated.append(r); continue }          // 本歌自己的源＝参照，直接过
            if NameMatch.sameRecording(src: song, cand: r.song) {
                gated.append(r)
            } else if gateDropped.count < 3 {
                gateDropped.append("\(r.song.name.prefix(14))|\(r.song.singer.prefix(8))|\(r.song.durationSec)s")
            }
        }

        // ③ 打分 + 同 URL 去重（保留分高的那条）
        var byURL: [String: Candidate] = [:]
        for r in gated {
            let c = Candidate(song: r.song, source: r.source, elapsedMs: r.elapsedMs,
                              score: score(of: r.source, song: r.song, ref: song, ms: r.elapsedMs))
            if let old = byURL[r.source.url], old.score >= c.score { continue }
            byURL[r.source.url] = c
        }
        let ranked = byURL.values.sorted { $0.score > $1.score }

        // ④ 排名表（验收要看的就是这几行）
        debug.append("候选 \(ranked.count) 条" + (gateDropped.isEmpty ? "" : "（身份闸淘汰 \(gateDropped.count)+：\(gateDropped.joined(separator: "；"))）"))
        for (i, c) in ranked.prefix(6).enumerated() {
            debug.append("第\(i + 1)名 \(c.source.backendName) \(c.source.format.uppercased()) \(c.source.kbps)kbps \(c.source.totalBytes)B 分[\(c.score.short)] \(c.source.quality.displayName)")
        }
        if !found.neteaseURL.isEmpty {
            debug.append("网易URL \(found.neteaseURL)")
            debug.append("网易响应 \(found.neteaseTop.isEmpty ? "（0 条）" : found.neteaseTop.joined(separator: " / "))")
        }

        // ⑤ 取第一 + 下载前校验，不过就退下一条（仍然是被身份闸放行的同曲同版本）
        var picked: Candidate?
        var pickedRank = 0
        var fallback: StreamSource?
        var fallbackRank = 0
        for (i, c) in ranked.enumerated() {
            let v = DownloadPreflight.check(c.source, want: want, durationSec: song.durationSec)
            if !v.ok {
                debug.append("第\(i + 1)名 校验不过：\(v.reason)")
                continue
            }
            if fallback == nil { fallback = c.source; fallbackRank = i + 1 }
            if picked == nil, c.source.quality == want { picked = c; pickedRank = i + 1 }
        }

        if let p = picked {
            debug.append("选中 第\(pickedRank)名（校验通过）")
            notes.append("第\(pickedRank)/\(ranked.count)名 \(p.source.backendName)")
        } else if !ranked.isEmpty {
            debug.append("没有\(want.displayName) → 兜底 第\(fallbackRank)名 \(fallback?.quality.displayName ?? "—")")
            notes.append("无目标档，兜底第\(fallbackRank)/\(ranked.count)名")
        } else {
            debug.append("没有可用候选")
        }

        let switched = picked.map { $0.source.platform != song.platform } ?? false
        return Plan(want: want, picked: picked, ranked: ranked, fallback: fallback,
                    switched: switched, notes: notes, debug: debug)
    }

    // MARK: 播放链：质量窗口（先粗后精）

    /// 本平台 + 妖狐 并发，`window` 秒内收到的候选里取分最高的先起播。
    /// 窗口内一条都没有 → 返回 nil，由调用方去等完整排名。
    static func quickPick(song: Song, want: QualityLevel,
                          window: TimeInterval = playWindow) async -> Candidate? {
        let raw = await collect(jobs: primaryJobs(for: song), want: want, deadline: window)
        guard !raw.isEmpty else { return nil }
        return raw
            .map { r in
                Candidate(song: r.song, source: r.source, elapsedMs: r.elapsedMs,
                          score: score(of: r.source, song: r.song, ref: song, ms: r.elapsedMs))
            }
            .max { $0.score < $1.score }
    }

    /// 后台换源判据：新源档位更高（或同档但码率明显更高）才换，避免来回横跳。
    static func isBetter(_ a: StreamSource, than b: StreamSource?) -> Bool {
        guard let b else { return true }
        if tierOf(a) != tierOf(b) { return tierOf(a) > tierOf(b) }
        return a.kbps > b.kbps + 50
    }

    /// 档位分值（打分与"播放链是否值得换"共用同一个口径）
    static func tierOf(_ s: StreamSource) -> Int {
        if s.format == "flac" || s.format == "wav" || s.kbps >= 800 { return 1000 }
        if s.kbps >= 300 { return 700 }
        if s.kbps >= 240 { return 500 }
        return 200
    }

    /// 后端可靠性分级：官方 CDN 直链 > 聚合接口。
    /// 依据：r123–r125 三轮故障全出在聚合接口（gdstudio / oiapi / cyapi）被风控、降档、回错歌；
    /// 酷我妖狐与酷狗官方 playInfo 给的是平台自己的 CDN 直链，一直是稳的。
    static func backendTrust(_ name: String) -> Int {
        if name.contains("妖狐") { return 20 }
        if name.contains("酷狗官方") { return 20 }
        return 0
    }

    static func score(of src: StreamSource, song: Song, ref: Song, ms: Int) -> Score {
        let version: Int
        let refVer = NameMatch.versionClass(ref.name)
        let candVer = NameMatch.versionClass(song.name)
        if candVer.isEmpty { version = 300 }
        else if candVer == refVer { version = 200 }
        else { version = 100 }

        let diff = abs(song.durationSec - ref.durationSec)
        let duration = max(0, 100 - diff * 10)

        var reliable = 0
        if src.totalBytes > 0 { reliable += 40 }
        if src.kbps > 0 { reliable += 30 }
        if src.rangeOK == true { reliable += 20 }
        reliable += backendTrust(src.backendName)

        return Score(tier: tierOf(src), version: version, duration: duration,
                     reliable: reliable, ms: ms)
    }

    // MARK: 收集

    private struct Job: Sendable {
        let song: Song
        let adapter: StreamSourceAdapter
    }

    private struct RawCandidate: Sendable {
        let song: Song
        let source: StreamSource
        let elapsedMs: Int
    }

    /// 本平台后端 + 妖狐（都按"这首歌自己的 ID/歌名"取流，不依赖搜索）
    private static func primaryJobs(for song: Song) -> [Job] {
        var jobs = SourceRegistry.adapters(for: song).map { Job(song: song, adapter: $0) }
        if song.platform != .kuwo { jobs.append(Job(song: song, adapter: YaohuKuwoAdapter())) }
        return jobs
    }

    /// 跨源候选：按候选自己平台的取流后端解析（网易 → gdstudio/oiapi；酷狗 → playInfo；QQ → cyapi）
    private static func crossJobs(for cands: [Song]) -> [Job] {
        var jobs: [Job] = []
        var seen = Set<String>()
        for c in cands {
            let key = "\(c.platform.rawValue)_\(c.platformID)"
            guard seen.insert(key).inserted else { continue }
            for a in SourceRegistry.adapters(for: c) { jobs.append(Job(song: c, adapter: a)) }
        }
        return jobs
    }

    /// 并发跑一批后端，每个任务按**剩余预算**单独超时；到点返回已收到的（不丢部分结果）。
    private static func collect(jobs: [Job], want: QualityLevel,
                                deadline: TimeInterval) async -> [RawCandidate] {
        guard !jobs.isEmpty else { return [] }
        let start = Date()
        return await withTaskGroup(of: RawCandidate?.self) { group in
            for job in jobs {
                group.addTask {
                    let left = max(1, deadline - Date().timeIntervalSince(start))
                    let t0 = Date()
                    let src = await withTimeoutOrNil(left) {
                        try await job.adapter.resolve(song: job.song, quality: want)
                    }
                    guard let src else { return nil }
                    return RawCandidate(song: job.song, source: src,
                                        elapsedMs: Int(Date().timeIntervalSince(t0) * 1000))
                }
            }
            var out: [RawCandidate] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }
}

// MARK: - 下载前校验（排名第一也要过这一关）
//
// 校验的是"这条 URL 下下来是不是一个正常文件"，不是音质判定（音质在探测层已经做完）。
// 老板口径：Content-Length > 0、容器与后缀一致、体积量级对得上；不过就退第二名。
enum DownloadPreflight {

    struct Verdict: Sendable {
        let ok: Bool
        let reason: String
    }

    static func check(_ src: StreamSource, want: QualityLevel, durationSec: Int) -> Verdict {
        if src.url.isEmpty { return Verdict(ok: false, reason: "没有 URL") }
        if src.totalBytes <= 0 {
            return Verdict(ok: false, reason: "拿不到体积（Content-Length / Content-Range 都缺）")
        }

        // 后缀与实测容器必须一致（"后缀 .flac 里装 mp3"是历史事故）
        let ext = (src.url as NSString).pathExtension.lowercased()
        if ext == "flac" && src.format != "flac" {
            return Verdict(ok: false, reason: "后缀 .flac 但实测容器是 \(src.format)")
        }

        if want == .lossless {
            if src.totalBytes < 3_000_000 {
                return Verdict(ok: false, reason: "体积只有 \(src.totalBytes / 1_048_576)MB，不可能是无损")
            }
            if durationSec >= 120 && src.totalBytes < 15_000_000 {
                return Verdict(ok: false,
                               reason: "无损只有 \(src.totalBytes / 1_048_576)MB（\(durationSec)s 的歌应 ≥15MB）")
            }
            let isLosslessContainer = src.format == "flac" || src.format == "wav"
            if !isLosslessContainer && src.kbps < 800 {
                return Verdict(ok: false, reason: "档位不成立：容器 \(src.format) / \(src.kbps)kbps")
            }
        }

        if src.kbps <= 0 && src.format != "flac" && src.format != "wav" {
            return Verdict(ok: false, reason: "算不出码率，无法确认档位")
        }

        return Verdict(ok: true, reason: "")
    }
}

// MARK: - 小工具

extension Array {
    /// 按固定大小分批（Android `chunked(3)`）
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        var out: [[Element]] = []
        var i = 0
        while i < count {
            out.append(Array(self[i..<Swift.min(i + size, count)]))
            i += size
        }
        return out
    }
}

extension QualityLevel {
    /// 档位由低到高（下载兜底时比较"最高可得档"）
    var sortOrder: Int {
        switch self {
        case .standard: return 0
        case .high: return 1
        case .lossless: return 2
        }
    }
}
