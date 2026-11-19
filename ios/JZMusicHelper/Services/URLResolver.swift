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

    private static func candidateList(song: Song, quality: QualityLevel,
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

// MARK: - 下载取源编排
/// 与 Android `DownloadResolver` 同口径：三档共用同一条换源链，产出「核实就是目标档」的候选清单，
/// 外加一条「最高可得档」兜底。不这样做，"选了无损却拿到 128k"就是必然。
enum DownloadResolver {

    struct Plan: Sendable {
        let want: QualityLevel
        let exact: [StreamSource]
        let fallback: StreamSource?
        let switched: Bool
        let crossTried: Int
        /// 这一次取源各阶段的实况（本平台几条 / 跨源试了几条 / 妖狐结果），降级时写进弹层说清原因
        let notes: [String]
        /// 逐条留痕（**不截断**，弹层单列一块）：源曲元数据 / 网易实际请求 URL / 网易响应前 3 条 / 妖狐结果。
        /// 为什么单列：r122–r125 三轮都因为"200 字截断 + 只记条数不记内容"而在猜，这一次把证据摆出来。
        let debug: [String]

        var empty: Bool { exact.isEmpty && fallback == nil }

        /// 降级时那句人话：只说"没有 X、最高 Y"。
        /// 细节不塞这里了——旧实现把 notes 拼进来再截 240 字，真机上正好把"妖狐那轮的结果"切掉，
        /// 结果看了三轮都没人知道妖狐到底回没回。细节走 `debug`，一行一条。
        var fallbackReason: String {
            let best = fallback?.quality.displayName ?? "—"
            return "没有\(want.displayName)，最高可得\(best)"
        }
    }

    static let genericTimeout: TimeInterval = 20
    static let maxExact = 3

    static func plan(song: Song, want: QualityLevel) async -> Plan {
        let duration = song.durationSec
        var pool: [StreamSource] = []
        var notes: [String] = []
        var debug: [String] = []
        debug.append("源曲 \(song.name) | \(song.singer) | \(song.durationSec)s | \(song.platform.shortName)")

        // 第一轮：本平台自己的后端
        let local = await URLResolver.shared.resolveResult(song: song, quality: want, timeout: 18)
        pool.append(contentsOf: local.sources)
        notes.append("本平台 \(local.sources.count) 条\(local.sources.isEmpty ? "" : "（\(qualitySummary(local.sources))）")")
        if !local.failed.isEmpty {
            // 真机诊断用：哪个后端、什么原因（超时 / 解析失败 / HTTP 403 …）
            let reasons = local.failed.map { "\($0.key):\($0.value)" }.sorted().joined(separator: "、")
            notes.append("本平台后端失败（\(reasons)）")
        }

        // 第二轮：跨源换源（同曲判定 = 歌手优先 + 时长 ≤4s + 歌名只做辅助）
        // 排序已经在 `candidateList` 里按"能出目标档的平台"优先（网易/酷我先解析）
        let tried = TriedKeys()
        let cross = await SameSongCrossResolver.resolveForDownload(
            song: song, want: want, triedKeys: tried)
        pool.append(contentsOf: cross.exacts)
        if let best = cross.best { pool.append(best) }
        if !cross.neteaseDebug.isEmpty { notes.append("网易检索 \(cross.neteaseDebug)") }
        notes.append("跨源试 \(tried.count) 条\(cross.candidateSummary.isEmpty ? "" : "（\(cross.candidateSummary)）")\(cross.exacts.isEmpty && cross.best == nil ? "全落空" : "")")
        if !cross.failures.isEmpty {
            notes.append("跨源失败（\(cross.failures.prefix(3).joined(separator: "、"))）")
        }
        // 网易检索留痕：实际请求 URL（解码后）+ 响应前 3 条。这两行是下一版真机定案的关键，
        // 所以单列、不截断（弹层里按行渲染）。
        if !cross.neteaseURL.isEmpty {
            debug.append("网易URL \(cross.neteaseURL)")
            debug.append("网易响应 \(cross.neteaseTop.isEmpty ? "（0 条）" : cross.neteaseTop.joined(separator: " / "))")
        }

        // 第三轮：通用搜索式后端（妖狐酷我，与歌来自哪个平台无关）
        // 无损档照打（妖狐恒给无损）；320k/128k 只在"一条源都没有"时才打，否则白等 20s
        let hasExact = pool.contains { isExact($0, want: want, durationSec: duration) }
        let hasAny = pool.contains { !$0.url.isEmpty }
        if !hasExact && song.platform != .kuwo && (want == .lossless || !hasAny) {
            do {
                let generic = try await withTimeoutThrowing(genericTimeout) {
                    try await YaohuKuwoAdapter().resolve(song: song, quality: .lossless)
                }
                pool.append(generic)
                notes.append("妖狐 \(generic.quality.displayName)")
                debug.append("妖狐 命中 \(generic.format.uppercased()) · \(generic.kbps)kbps · \(generic.totalBytes)B")
            } catch {
                notes.append("妖狐失败(\(Int(genericTimeout))s)")
                debug.append("妖狐 失败：\(URLResolver.shortError(error))")
            }
        } else if hasExact {
            debug.append("妖狐 跳过（已有目标档）")
        }

        var seen = Set<String>()
        let uniq = pool.filter { !$0.url.isEmpty && seen.insert($0.url).inserted }

        let exact = uniq
            .filter { isExact($0, want: want, durationSec: duration) }
            .sorted { a, b in
                let pa = a.platform == song.platform ? 0 : 1
                let pb = b.platform == song.platform ? 0 : 1
                if pa != pb { return pa < pb }
                if a.directId != b.directId { return a.directId && !b.directId }
                return a.kbps > b.kbps
            }
            .prefix(maxExact)
            .map { $0 }

        let fallback = uniq
            .filter { s in !exact.contains(where: { $0.url == s.url }) }
            .max { a, b in
                if a.quality.sortOrder != b.quality.sortOrder {
                    return a.quality.sortOrder < b.quality.sortOrder
                }
                if a.kbps != b.kbps { return a.kbps < b.kbps }
                return (a.directId ? 1 : 0) < (b.directId ? 1 : 0)
            }

        let switched = (exact + [fallback].compactMap { $0 }).contains { $0.platform != song.platform }
        return Plan(want: want, exact: exact, fallback: fallback,
                    switched: switched, crossTried: tried.count, notes: notes, debug: debug)
    }

    /// 「3 条：网易·无损 / QQ·标准」这种一句话摘要（只给降级提示用）
    static func qualitySummary(_ sources: [StreamSource]) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for s in sources {
            let key = "\(s.platform.rawValue)|\(s.quality.rawValue)"
            guard seen.insert(key).inserted else { continue }
            parts.append("\(s.platform.shortName)·\(s.quality.displayName)")
        }
        return parts.prefix(3).joined(separator: " / ")
    }

    /// 目标档判定：容器 + 码率都由取流阶段实测得到；时长未知时退回"档位桶"这一层近似
    static func isExact(_ src: StreamSource, want: QualityLevel, durationSec: Int) -> Bool {
        if durationSec <= 0 || src.kbps <= 0 { return src.quality == want }
        return QualityFacts.matches(want, container: src.format, kbps: src.kbps)
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
