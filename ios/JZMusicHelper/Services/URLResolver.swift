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
    static let maxDurationDiffSec = 12

    /// 播放用：拿到一条可用源就返回
    static func resolve(song: Song, quality: QualityLevel,
                        triedKeys: TriedKeys) async -> StreamSource? {
        await withTimeoutOrNil(totalTimeout) {
            let candidates = await candidateList(
                song: song, quality: quality, triedKeys: triedKeys, forDownload: false)
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

        static let empty = CrossOutcome(exact: nil, best: nil, exacts: [], failures: [])
    }

    /// 下载用：一次遍历同时求「目标档」与「最高可得档」
    static func resolveForDownload(song: Song, want: QualityLevel,
                                   triedKeys: TriedKeys) async -> CrossOutcome {
        await withTimeoutOrNil(totalTimeout) {
            let candidates = await candidateList(
                song: song, quality: want, triedKeys: triedKeys, forDownload: true)
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
                                failures: failures, candidateSummary: summary)
        } ?? .empty
    }

    private static func candidateList(song: Song, quality: QualityLevel,
                                      triedKeys: TriedKeys, forDownload: Bool) async -> [Song] {
        let kw = "\(song.name) \(song.singer)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let results = await SearchService.shared.searchAll(keyword: kw, limit: 30)
        var cands = results.flatMap { $0.songs }.filter { sameSong(src: song, cand: $0) }
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
        return unique
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

    /// 同曲判定：歌名匹配 + 歌手匹配 + 时长不差一个版本
    static func sameSong(src: Song, cand: Song) -> Bool {
        if src.platform == cand.platform && src.platformID == cand.platformID { return false }
        if !NameMatch.titleMatches(src.name, cand.name) { return false }
        if !NameMatch.singerMatches(src.singer, cand.singer) { return false }

        let sd = src.durationSec
        let cd = cand.durationSec
        guard sd > 0 && cd > 0 else { return true }
        let diff = abs(sd - cd)

        // 版本防线（第三十四轮，青花瓷事故）：
        // 源是干净原唱时，跨源候选**必须也是干净原唱**——不能再拿"时长差不多"放行。
        // 酷狗的《青花瓷 (DJ Wave版)》242s 与原唱 239s 只差 3s，旧口径（diff > 3 才拒）正好放它过去，
        // 结果 UI 仍显示"青花瓷 / 周杰伦"，耳朵里放的是 DJ 版。
        let srcIsClean = StudioPick.isCleanTitle(src.name) && !StudioPick.isLiveAlbum(src.album)
        let candIsClean = StudioPick.isCleanTitle(cand.name) && !StudioPick.isLiveAlbum(cand.album)
        if srcIsClean && !candIsClean { return false }

        if diff > maxDurationDiffSec {
            // 源本身是现场/节目变体，候选是干净录音室条目（裸名 + 正式专辑 + 更长）→ 视为同一首
            let srcIsVariant = !StudioPick.isCleanTitle(src.name)
            let candIsStudio = StudioPick.isCleanTitle(cand.name)
                && !cand.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !StudioPick.isLiveAlbum(cand.album)
                && cd > sd
            if !(srcIsVariant && candIsStudio) { return false }
        }
        return true
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

        var empty: Bool { exact.isEmpty && fallback == nil }

        /// 降级时那句人话：最高可得档 + 各阶段实况（截断到 160 字，弹层里一行放得下）
        var fallbackReason: String {
            let best = fallback?.quality.displayName ?? "—"
            guard !notes.isEmpty else { return "没有\(want.displayName)，最高可得\(best)" }
            let detail = String(notes.joined(separator: " · ").prefix(160))
            return "没有\(want.displayName)，最高可得\(best)（\(detail)）"
        }
    }

    static let genericTimeout: TimeInterval = 12
    static let maxExact = 3

    static func plan(song: Song, want: QualityLevel) async -> Plan {
        let duration = song.durationSec
        var pool: [StreamSource] = []
        var notes: [String] = []

        // 第一轮：本平台自己的后端
        let local = await URLResolver.shared.resolveResult(song: song, quality: want, timeout: 18)
        pool.append(contentsOf: local.sources)
        notes.append("本平台 \(local.sources.count) 条\(local.sources.isEmpty ? "" : "（\(qualitySummary(local.sources))）")")
        if !local.failed.isEmpty {
            // 真机诊断用：哪个后端、什么原因（超时 / 解析失败 / HTTP 403 …）
            let reasons = local.failed.map { "\($0.key):\($0.value)" }.sorted().joined(separator: "、")
            notes.append("本平台后端失败（\(reasons)）")
        }

        // 第二轮：跨源换源（同歌名 + 同歌手，StudioPick 排掉 live/节目版）
        // 排序已经在 `candidateList` 里按"能出目标档的平台"优先（网易/酷我先解析）
        let tried = TriedKeys()
        let cross = await SameSongCrossResolver.resolveForDownload(
            song: song, want: want, triedKeys: tried)
        pool.append(contentsOf: cross.exacts)
        if let best = cross.best { pool.append(best) }
        notes.append("跨源试 \(tried.count) 条\(cross.candidateSummary.isEmpty ? "" : "（\(cross.candidateSummary)）")\(cross.exacts.isEmpty && cross.best == nil ? "全落空" : "")")
        if !cross.failures.isEmpty {
            notes.append("跨源失败（\(cross.failures.prefix(3).joined(separator: "、"))）")
        }

        // 第三轮：通用搜索式后端（妖狐酷我，与歌来自哪个平台无关）
        // 无损档照打（妖狐恒给无损）；320k/128k 只在"一条源都没有"时才打，否则白等 12s
        let hasExact = pool.contains { isExact($0, want: want, durationSec: duration) }
        let hasAny = pool.contains { !$0.url.isEmpty }
        if !hasExact && song.platform != .kuwo && (want == .lossless || !hasAny) {
            let generic = await withTimeoutOrNil(genericTimeout) {
                try await YaohuKuwoAdapter().resolve(song: song, quality: .lossless)
            }
            if let generic {
                pool.append(generic)
                notes.append("妖狐 \(generic.quality.displayName)")
            } else {
                notes.append("妖狐失败")
            }
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
                    switched: switched, crossTried: tried.count, notes: notes)
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
