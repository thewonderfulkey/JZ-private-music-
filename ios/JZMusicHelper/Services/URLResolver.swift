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
    private(set) var set: Set<String> = []
    var count: Int { set.count }
    func contains(_ k: String) -> Bool { set.contains(k) }
    func insert(_ k: String) { set.insert(k) }
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

    func resolveResult(song: Song, quality: QualityLevel) async -> ResolveResult {
        let adapters = SourceRegistry.adapters(for: song)
        let timeout = perBackendTimeout
        let outcomes = await withTaskGroup(of: (String, StreamSource?).self) { group in
            for adapter in adapters {
                group.addTask {
                    let src = await withTimeoutOrNil(timeout) {
                        try await adapter.resolve(song: song, quality: quality)
                    }
                    return (adapter.name, src)
                }
            }
            var out: [(String, StreamSource?)] = []
            for await o in group { out.append(o) }
            return out
        }
        var sources: [StreamSource] = []
        var failed: [String: String] = [:]
        for (name, src) in outcomes {
            if let src { sources.append(src) } else { failed[name] = "失败或超时" }
        }
        return ResolveResult(sources: sources, failed: failed)
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
    static let totalTimeout: TimeInterval = 40
    static let maxDurationDiffSec = 12
    static let strictDurationDiffSec = 3

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

        static let empty = CrossOutcome(exact: nil, best: nil, exacts: [])
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

            for batch in candidates.chunked(3) {
                if exacts.count >= maxExactKeep { break }
                let got = await withTaskGroup(of: StreamSource?.self) { group in
                    for c in batch {
                        group.addTask {
                            let r = await URLResolver.shared.resolveResult(song: c, quality: want)
                            return SourcePicker.pick(r.sources, want: want)
                        }
                    }
                    var out: [StreamSource?] = []
                    for await s in group { out.append(s) }
                    return out
                }
                for s in got {
                    guard let s else { continue }
                    if s.quality == want {
                        if exact == nil { exact = s }
                        if !exacts.contains(where: { $0.url == s.url }) { exacts.append(s) }
                    }
                    if let cur = best {
                        if s.quality.sortOrder > cur.quality.sortOrder { best = s }
                    } else {
                        best = s
                    }
                }
            }
            return CrossOutcome(exact: exact, best: best, exacts: exacts)
        } ?? .empty
    }

    private static func candidateList(song: Song, quality: QualityLevel,
                                      triedKeys: TriedKeys, forDownload: Bool) async -> [Song] {
        let kw = "\(song.name) \(song.singer)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let results = await SearchService.shared.searchAll(keyword: kw, limit: 30)
        var cands = results.flatMap { $0.songs }.filter { sameSong(src: song, cand: $0) }
        cands = cands.filter { !triedKeys.contains(candKey($0)) }

        // 排序：无损档「同平台优先 → 原唱得分」；320k/128k 只信网易候选能出目标档，否则白耗 12s/条
        if forDownload && quality != .lossless {
            cands.sort { a, b in
                let ca = tierCapable(a.platform, want: quality) ? 0 : 1
                let cb = tierCapable(b.platform, want: quality) ? 0 : 1
                if ca != cb { return ca < cb }
                let pa = a.platform == song.platform ? 0 : 1
                let pb = b.platform == song.platform ? 0 : 1
                if pa != pb { return pa < pb }
                return StudioPick.studioScore(a) > StudioPick.studioScore(b)
            }
        } else {
            cands.sort { a, b in
                let pa = a.platform == song.platform ? 0 : 1
                let pb = b.platform == song.platform ? 0 : 1
                if pa != pb { return pa < pb }
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

    /// 同曲判定：歌名匹配 + 歌手匹配 + 时长不差一个版本
    static func sameSong(src: Song, cand: Song) -> Bool {
        if src.platform == cand.platform && src.platformID == cand.platformID { return false }
        if !NameMatch.titleMatches(src.name, cand.name) { return false }
        if !NameMatch.singerMatches(src.singer, cand.singer) { return false }

        let sd = src.durationSec
        let cd = cand.durationSec
        guard sd > 0 && cd > 0 else { return true }
        let diff = abs(sd - cd)

        // 版本防线：源是干净原唱、候选却是 live/综艺/节目变体时，只有时长几乎一致才认
        let candIsVariant = !StudioPick.isCleanTitle(cand.name)
            || (!cand.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && StudioPick.isLiveAlbum(cand.album))
        if StudioPick.isCleanTitle(src.name) && candIsVariant && diff > strictDurationDiffSec {
            return false
        }

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

        var empty: Bool { exact.isEmpty && fallback == nil }
    }

    static let genericTimeout: TimeInterval = 12
    static let maxExact = 3

    static func plan(song: Song, want: QualityLevel) async -> Plan {
        let duration = song.durationSec
        var pool: [StreamSource] = []

        // 第一轮：本平台自己的后端
        let local = await URLResolver.shared.resolveResult(song: song, quality: want)
        pool.append(contentsOf: local.sources)

        // 第二轮：跨源换源（同歌名 + 同歌手，StudioPick 排掉 live/节目版）
        let tried = TriedKeys()
        let cross = await SameSongCrossResolver.resolveForDownload(
            song: song, want: want, triedKeys: tried)
        pool.append(contentsOf: cross.exacts)
        if let best = cross.best { pool.append(best) }

        // 第三轮：通用搜索式后端（妖狐酷我，与歌来自哪个平台无关）
        // 无损档照打（妖狐恒给无损）；320k/128k 只在"一条源都没有"时才打，否则白等 12s
        let hasExact = pool.contains { isExact($0, want: want, durationSec: duration) }
        let hasAny = pool.contains { !$0.url.isEmpty }
        if !hasExact && song.platform != .kuwo && (want == .lossless || !hasAny) {
            let generic = await withTimeoutOrNil(genericTimeout) {
                try await YaohuKuwoAdapter().resolve(song: song, quality: .lossless)
            }
            if let generic { pool.append(generic) }
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
                    switched: switched, crossTried: tried.count)
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
