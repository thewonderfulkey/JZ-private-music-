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
                            return SourcePicker.pick(r.sources, want: quality).map { $0.matched(c) }
                        }
                    }
                    var out: [StreamSource?] = []
                    for await s in group { out.append(s) }
                    return out
                }
                picked = got.first { $0 != nil } ?? nil
            }
            // 2026-11-27：这里原来有一条"变速条目拿原曲顶替"的兜底，已被老板否掉——
            // 他的口径是「上传者的变速/剪辑条目一律不返回」，所以这类歌根本不会进到播放链
            // （`JunkAudioRules` 在搜索/榜单/歌单/歌手页的解析处就已经滤掉）。
            // 没有再留这条兜底：否则 0.8x 会播成正常速度，听起来是"放错歌"。
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
        /// 「歌手」是频道号/上传者时被收紧掉的候选（诊断用：`歌名|时长` 最多 3 条）
        var uploaderDropped: [String] = []
        /// 这一轮是不是把「歌手」认成了频道号/上传者（收紧只在这个条件下生效）
        var uploaderSinger: Bool = false
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
                                return (s.matched(c), "")
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
        // 2026-11-26：搜索词要能降级。平台把歌手写成上传者时（「小酒」），
        // 用原名搜得到的只有无关结果或零条；这时才换「去括号歌名 + 括号里的歌手」再搜一次。
        let queries = SearchQueryVariants.queries(name: song.name, singer: song.singer)
        guard let kw = queries.first else { return CandidateSet() }
        var cands: [Song] = []
        for q in queries.prefix(2) {
            let results = await SearchService.shared.searchAll(keyword: q, limit: 30)
            let flat = results.flatMap { $0.songs }
            cands = flat
            // 这一轮已经有"像这首歌"的候选，就不用再降级
            if flat.contains(where: { sameSong(src: song, cand: $0) }) { break }
        }
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

        // 身份闸（+ 2026-11-22 的「频道号」收紧，见 `sameSong(src:cand:uploaderLike:)`）：
        // 先把"这个歌手是不是频道号/上传者"在**整池子**上判一次，再逐条过闸。
        // 判据要整池（≥3 首互不相同、且一首都没对上源歌名），单条候选看不出来。
        let uploaderLike = NameMatch.looksLikeUploader(song, among: cands)
        out.uploaderSinger = uploaderLike
        var droppedByUploader: [String] = []
        cands = cands.filter { cand in
            let kept = sameSong(src: song, cand: cand, uploaderLike: uploaderLike)
            // 老口径放行、新口径挡掉 = 同一位上传者名下的"别的歌"，留痕给诊断
            if !kept, uploaderLike, sameSong(src: song, cand: cand),
               droppedByUploader.count < 3 {
                droppedByUploader.append("\(cand.name.prefix(14))|\(cand.durationSec)s")
            }
            return kept
        }
        out.uploaderDropped = droppedByUploader
        // 按 key 去重（同曲可能在多个源里都出现），保留先出现的
        var seenKeys = Set<String>()
        cands = cands.filter { seenKeys.insert(candKey($0)).inserted }
        cands = cands.filter { !triedKeys.contains(candKey($0)) }

        // 排序（第三十四轮 + r120，2026-11-25 加身份位）：
        // **先身份（就是这首歌 > 歌名相等 > 歌名相近 > 专辑兜底），再"能出目标档"的平台**，
        // 然后"干净原唱永远优先"，最后才看同平台/时长。
        //
        // r120（《연애의 조건》）：以前「同平台优先」排在最前，QQ 那三条 128k 候选先被逐个解析，
        // 网易那条真无损排在后面；真机上预算一紧就"还没轮到网易就收工"，弹层于是写着"只有 128k"。
        // 现在按平台能力排序——无损先网易（gdstudio 稳定出 fLaC），320k/128k 也先网易（唯一按 br 给档的）。
        //
        // 2026-11-25：身份位必须最前。以前"错歌的 320k"能排到"对歌的 98kbps"前面，
        // 直接导致《众》放成《侧脸》。
        if forDownload {
            cands.sort { a, b in
                let ia = NameMatch.identityRank(src: song, cand: a)
                let ib = NameMatch.identityRank(src: song, cand: b)
                if ia != ib { return ia < ib }
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
                let ia = NameMatch.identityRank(src: song, cand: a)
                let ib = NameMatch.identityRank(src: song, cand: b)
                if ia != ib { return ia < ib }
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
            // 本地文件不是网络源：排最后，避免挤掉真实取流次序
            case .local: return 99
            }
        case .high, .standard:
            switch platform {
            case .netease: return 0
            case .kugou: return 1
            case .kuwo: return 2
            case .qq: return 3
            // 本地文件不是网络源：排最后，避免挤掉真实取流次序
            case .local: return 99
            }
        }
    }

    /// 同曲判定：统一走 `NameMatch.sameRecording`（2026-11-25 起：**歌名证据是硬条件** + 歌手 + 时长 ≤4s）。
    ///
    /// 2026-11-19 老板口径要求「歌手优先、歌名只做辅助」，是为了《恋爱的条件》/《연애의 조건》。
    /// 但 2026-11-25《众》播成《侧脸》证明那条太松：同歌手、时长差 2.4 秒、歌名毫不相干也能过。
    /// 现在译名案走 `NameMatch.titleEvidence` 的"专辑 + 时长 ≤1 秒"通道，其余情况歌名必须对得上。
    static func sameSong(src: Song, cand: Song) -> Bool {
        NameMatch.sameRecording(src: src, cand: cand)
    }

    /// 同曲判定（池子级）：在统一口径之上再挡一类**串成别的歌**。
    ///
    /// 2026-11-22（老板录屏《下一个天亮》播着播着变成《怎么会狠心伤害我》）：
    /// 这首歌的「歌手」是频道名 `我的音乐调频`，名下几十首互不相干的歌、时长都在 4 分钟上下；
    /// 老口径只认「歌手 + 时长 ±4s」，于是同一位上传者的**别的歌**被当成"同一条录音"的合法音源，
    /// 后台升档时被换上，还把进度 seek 回去——听感就是"同一首唱到一半变成另一首"。
    ///
    /// `uploaderLike`（由整池子判出来，见 `NameMatch.looksLikeUploader`）为真时，
    /// 只认**歌名归一化一致**的候选（比"歌名证据"更窄一档：相似度/包含都不放行）。
    ///
    /// 2026-11-25 之后这一层已经变成"双重保险"：`sameRecording` 本身也要求歌名证据，
    /// 这里只是对"上传者名下的别的歌"再收紧一次（相似度那档也不给）。
    static func sameSong(src: Song, cand: Song, uploaderLike: Bool) -> Bool {
        guard sameSong(src: src, cand: cand) else { return false }
        guard uploaderLike else { return true }
        // 2026-11-27：《蓄势 ~GEAR UP~》被跳过。这条"严格相等"原来比的是 `normTitle`，
        // 不认繁简/全角——池子里采风乐坊挂着 6 首不同的歌（被误判成频道号），
        // 唯一能播的 QQ/酷狗两条《蓄勢 ～GEAR UP～》就在这句被丢掉，整首无源。
        // 收紧的**意图**是"只认同一个歌名"，所以比的是身份键（繁简/全角/标点已折平），
        // 而不是"字节相同"。
        return NameMatch.identityKey(src.name) == NameMatch.identityKey(cand.name)
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
        /// ① 身份等级（2026-11-25 新增，**排第一**）
        ///
        /// 1 = 就是这首歌（同 id 或歌名相等）/ 2 = 歌名相近 / 3 = 专辑+时长兜底 / 9 = 没证据。
        /// 为什么必须排在音质前面：老板口径是"宁可 128k 的对歌，也不要 320k 的错歌"。
        /// 事故：《众》只有 98kbps 的源，而《侧脸》有 320k，旧口径下错歌赢。
        /// 同一档里才比音质（老板 2026-11-25：优先 320k，取不到再往下音质找）。
        var identity: Int = 0
        /// ② 音质档位：无损(FLAC/≥800k) > 320k > 256k > 128k
        let tier: Int
        /// ③ 版本匹配度：原唱 > 官方 Live > 其它
        let version: Int
        /// ④ 时长贴近度（越大越贴近）
        let duration: Int
        /// ⑤ 来源可靠性：实测有体积/码率、Range 正常、官方 CDN 直链优先
        let reliable: Int
        /// ⑥ 响应速度：**只在同分时**用（越小越前）
        let ms: Int

        static func < (a: Score, b: Score) -> Bool {
            if a.identity != b.identity { return a.identity > b.identity }   // 数字小 = 更可信
            if a.tier != b.tier { return a.tier < b.tier }
            if a.version != b.version { return a.version < b.version }
            if a.duration != b.duration { return a.duration < b.duration }
            if a.reliable != b.reliable { return a.reliable < b.reliable }
            return a.ms > b.ms
        }

        /// 诊断里那串 "身份/档/版/时/可靠"
        var short: String {
            "\(identity == 9 ? "错歌" : "id\(identity)")/\(tier)/\(version)/\(duration)/\(reliable)"
        }
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
            let kbps = fallback?.kbps ?? 0
            return kbps > 0 ? "没有\(want.displayName)，只能给\(best)（实测 \(kbps)k）"
                            : "没有\(want.displayName)，只能给\(best)"
        }
    }

    /// 目标档不可得时的兜底顺序（纯函数，CI 钉口径）。
    ///
    /// **先往下、再往上**，绝不默认越级：
    ///   · 点无损没货 → 高品 320k → 标准 128k
    ///   · 点高品没货 → 标准 128k → （实在没有才）无损
    ///   · 点标准没货 → 高品 320k → 无损（标准已经是底下那一档，只能往上）
    ///
    /// 老板 2026-11-26：上一版点 320k 却给了「无损 FLAC」，而那份无损正是刚被判死的那一条，
    /// 用户点下去就是再等两分钟白等。
    static func fallbackPreference(_ want: QualityLevel) -> [QualityLevel] {
        switch want {
        case .lossless: return [.high, .standard]
        case .high: return [.standard, .lossless]
        case .standard: return [.high, .lossless]
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
        // 2026-11-22：这一轮有没有"歌手被认成频道号"、因此挡掉了同上传者的别的歌
        if found.uploaderSinger {
            debug.append("歌手认作频道号/上传者 → 只认歌名一致"
                + (found.uploaderDropped.isEmpty
                   ? "（本轮没有因此被挡的候选）"
                   : "，挡掉 \(found.uploaderDropped.count)+：\(found.uploaderDropped.joined(separator: "；"))"))
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
        var passing: [(rank: Int, candidate: Candidate)] = []
        for (i, c) in ranked.enumerated() {
            // 2026-11-26（老板 ①）：这条源以前下过、并被判定"不是这首歌" → 不再推荐，
            // 否则就会像 11-25 录屏那样：02:35 判死、03:47 又把它排在"最高可得"第一位。
            if DownloadRejections.isRejected(c.source, song: song) {
                debug.append("第\(i + 1)名 已判死（\(c.source.backendName) "
                             + "\(c.source.kbps)kbps）：下过、不是这首歌")
                continue
            }
            let v = DownloadPreflight.check(c.source, want: want, durationSec: song.durationSec)
            if !v.ok {
                debug.append("第\(i + 1)名 校验不过：\(v.reason)")
                continue
            }
            passing.append((i + 1, c))
            if picked == nil, c.source.quality == want { picked = c; pickedRank = i + 1 }
        }

        // 目标档不可得时的兜底顺序：**先往下走，走到底才允许往上升**
        // （老板 2026-11-26：点无损→没货就 320k→再没货 128k；点 320k 没货就该给 128k，
        //   而不是"越级"塞一份无损——体积大，而且上一轮被闸门判死的往往正是那份无损）
        if picked == nil {
            for level in fallbackPreference(want) {
                if let hit = passing.first(where: { $0.candidate.source.quality == level }) {
                    fallback = hit.candidate.source
                    fallbackRank = hit.rank
                    break
                }
            }
            // 三档都不在兜底顺序里（理论上不会发生）：退化成"排名最靠前的那条"
            if fallback == nil, let first = passing.first {
                fallback = first.candidate.source
                fallbackRank = first.rank
            }
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

    // MARK: 播放链：先到先用（2026-11-20 老板定稿：不要再等齐三个后端）

    /// 播放入口（老路径）：**哪个后端先回来、且过了「档位 + 内容闸门 + 身份闸」，就立刻用它起播**。
    ///
    /// 旧 `quickPick` 是"等齐"——`collect` 里的 `for await` 要等每个 job 各自返回或各自超时
    /// 才收工。实测（老板真实歌单取样）三个 primary 后端**从来没有一次**在 1.8s 内等齐：
    /// gdstudio 0.4~0.9s、oiapi 1.4~2.1s、妖狐酷我 2.0~4.9s。于是每次切歌都吃满窗口，
    /// 那一段"没声音"的空档正好把进程送到系统的挂起线以下（见 IOS-BACKGROUND-ADVANCE.md）。
    ///
    /// 2026-11-22 起它在播放链里退居**第二档**：先由 `startPick` 在 1.6s 窗口内挑最高档；
    /// 窗口空手而归才回到这里"谁先回来用谁"（慢后端 2–5s 也能起播，不会掉进 plan 的 15s）。
    /// 起播之后**不再换 item**（旧的 `schedulePlaybackUpgrade` 已停用，就是它造成开头卡顿）。
    ///
    /// `allowLossless`：**只给"最后一条可用源"用**（周杰伦这类酷我只有 FLAC 的歌）。
    /// 常规路径（第一遍）传 false —— 无损不进关键路径，否则又会回到"播完卡住"
    /// （2026-11-19 心动模式那次的结论：无损必须现拉远端流，那就是卡顿来源）。
    static func firstPlayable(song: Song, want: QualityLevel,
                              deadline: TimeInterval = 6,
                              allowLossless: Bool = false) async -> Candidate? {
        // 冷却中的后端直接不叫（妖狐 403 / 落月风控 / ikun 限流）
        let jobs = primaryJobs(for: song).filter {
            !BackendHealth.shared.isCoolingDown($0.adapter.name)
        }
        guard !jobs.isEmpty else { return nil }
        return await withTaskGroup(of: Candidate?.self) { group in
            for job in jobs {
                group.addTask {
                    let t0 = Date()
                    guard let src = await withTimeoutOrNil(deadline, {
                        try await job.adapter.resolve(song: job.song, quality: want)
                    }) else { return nil }
                    // 身份闸：primary 后端拿的就是这首歌自己；跨源条目才需要再验一次
                    if job.song.id != song.id, !NameMatch.sameRecording(src: song, cand: job.song) {
                        return nil
                    }
                    // 内容闸门（占位提示音 / 加密包）+ 档位（常规 ≤320k，兜底才放开无损）
                    guard PlaybackQualityRules.isUsable(src, songDurationSec: song.durationSec,
                                                         allowLossless: allowLossless) else {
                        return nil
                    }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    return Candidate(song: job.song, source: src.matched(job.song), elapsedMs: ms,
                                     score: score(of: src, song: job.song, ref: song, ms: ms))
                }
            }
            for await c in group {
                if let c {
                    group.cancelAll()
                    return c
                }
            }
            return nil
        }
    }

    // MARK: 一次解析、先过闸先播（2026-11-26 老板口径）
    //
    // 老板原话：「任务可以是同一个，谁先回来**并且通过校验**的谁先播放」。
    // 所以这里不设"档位窗口"——第一个过完所有闸的候选立刻起播；档位只在**预取**里比
    // （预取有的是时间，见 `bestValidated`）。
    //
    // 与旧的三段接力（startPick → firstPlayable → plan）的区别：旧路径每段都从零重发，
    // 一段拿不到就把已经在飞的请求全扔掉——真机诊断里手动选歌 4.6–20s 就是这么来的。

    /// 解析阶段的闸门结果（纯数据，便于断言）
    struct GateResult: Sendable {
        /// nil = 通过；非 nil = 拒掉的原因（会写进诊断）
        let reason: String?
        /// 首段指纹（缓存层认"同一份文件"用）
        let headHash: String?
        let totalBytes: Int64
        /// 时长是文件自己写的（可信总长）
        let verified: Bool
        /// 文件自证时长（秒）。**起播前就交给播放器**，进度条不用再靠"播过头再改"。
        let durationSec: Double?

        static func pass(headHash: String?, totalBytes: Int64, verified: Bool,
                         durationSec: Double? = nil) -> GateResult {
            GateResult(reason: nil, headHash: headHash, totalBytes: totalBytes,
                       verified: verified, durationSec: durationSec)
        }

        static func reject(_ reason: String) -> GateResult {
            GateResult(reason: reason, headHash: nil, totalBytes: 0,
                       verified: false, durationSec: nil)
        }
    }

    /// 通过闸门的源 + 这次闸门拿到的证据
    struct Resolved: Sendable {
        let source: StreamSource
        let gate: GateResult
    }

    /// 一条回来的源要过哪些闸（由调用方注入，因为深度校验要用缓存层的 Range 探测）
    typealias Validator = (StreamSource) async -> GateResult

    /// **一次解析，先过闸的先出**。
    ///
    /// - 所有主腿同时开跑；
    /// - 每条回来的先过身份 + 可用性 + 调用方注入的深度闸；
    /// - 第一个全过的立刻返回，其余取消；
    /// - 被拒的只记一行，**不重启解析**。
    static func firstValidated(song: Song, want: QualityLevel,
                               allowLossless: Bool = false,
                               budget: TimeInterval = 8,
                               validate: @escaping Validator,
                               log: ((String) -> Void)? = nil) async -> Resolved? {
        let jobs = primaryJobs(for: song).filter {
            !BackendHealth.shared.isCoolingDown($0.adapter.name)
        }
        guard !jobs.isEmpty else { return nil }

        enum Step: Sendable {
            case hit(Resolved)
            case miss(String)
            case wake
        }

        return await withTaskGroup(of: Step.self) { group in
            for job in jobs {
                group.addTask {
                    let t0 = Date()
                    guard let src = await withTimeoutOrNil(budget, {
                        try await job.adapter.resolve(song: job.song, quality: want)
                    }) else {
                        return .miss("\(job.adapter.name) 超时/失败 "
                                     + "\(Int(Date().timeIntervalSince(t0) * 1000))ms")
                    }
                    if job.song.id != song.id, !NameMatch.sameRecording(src: song, cand: job.song) {
                        return .miss("\(job.adapter.name) 身份不符")
                    }
                    guard PlaybackQualityRules.isUsable(src, songDurationSec: song.durationSec,
                                                        allowLossless: allowLossless) else {
                        return .miss("\(job.adapter.name) 不可用（档位/加密/占位）")
                    }
                    let matched = src.matched(job.song)
                    let gate = await validate(matched)
                    if let reason = gate.reason {
                        return .miss("\(job.adapter.name) \(reason)")
                    }
                    return .hit(Resolved(source: matched, gate: gate))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, budget) * 1_000_000_000))
                return .wake
            }

            var misses: [String] = []
            var outstanding = jobs.count
            for await step in group {
                switch step {
                case .hit(let hit):
                    group.cancelAll()
                    return hit
                case .miss(let why):
                    outstanding -= 1
                    misses.append(why)
                    log?(why)
                    // 所有腿都明确失败：立刻收工，别等满预算（否则会白等 8 秒）
                    if outstanding == 0 {
                        group.cancelAll()
                        return nil
                    }
                case .wake:
                    group.cancelAll()
                    if !misses.isEmpty { log?("预算到点，已被拒：" + misses.prefix(3).joined(separator: "｜")) }
                    return nil
                }
            }
            return nil
        }
    }

    /// **预取用**：给足预算，在通过闸门的候选里挑档位最高的（音质优先只应该花在这里）。
    static func bestValidated(song: Song, want: QualityLevel,
                              allowLossless: Bool = false,
                              budget: TimeInterval = 8,
                              validate: @escaping Validator,
                              log: ((String) -> Void)? = nil) async -> Resolved? {
        let jobs = primaryJobs(for: song).filter {
            !BackendHealth.shared.isCoolingDown($0.adapter.name)
        }
        guard !jobs.isEmpty else { return nil }

        enum Step: Sendable {
            case hit(Resolved)
            case miss(String)
            case wake
        }

        return await withTaskGroup(of: Step.self) { group in
            for job in jobs {
                group.addTask {
                    guard let src = await withTimeoutOrNil(budget, {
                        try await job.adapter.resolve(song: job.song, quality: want)
                    }) else { return .miss("\(job.adapter.name) 超时/失败") }
                    if job.song.id != song.id, !NameMatch.sameRecording(src: song, cand: job.song) {
                        return .miss("\(job.adapter.name) 身份不符")
                    }
                    guard PlaybackQualityRules.isUsable(src, songDurationSec: song.durationSec,
                                                        allowLossless: allowLossless) else {
                        return .miss("\(job.adapter.name) 不可用")
                    }
                    let matched = src.matched(job.song)
                    let gate = await validate(matched)
                    if let reason = gate.reason {
                        return .miss("\(job.adapter.name) \(reason)")
                    }
                    return .hit(Resolved(source: matched, gate: gate))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, budget) * 1_000_000_000))
                return .wake
            }

            var best: Resolved?
            var outstanding = jobs.count
            for await step in group {
                switch step {
                case .hit(let hit):
                    outstanding -= 1
                    if best == nil || isBetter(hit.source, than: best?.source) {
                        best = hit
                    }
                case .miss(let why):
                    outstanding -= 1
                    log?(why)
                case .wake:
                    group.cancelAll()
                    return best
                }
                if outstanding == 0 {
                    group.cancelAll()
                    return best
                }
            }
            return best
        }
    }



    /// 起播窗口。320k 的后端实测多在 0.9–1.1s，但**慢后端（妖狐酷我/官方无损）2–3s 才回**——
    /// 2026-11-26 老板报"说好 320k 优先，实际一直在放 96–98k"，根因就是这个窗口太短：
    /// 1.6s 一到，手上只有 cyapi 的 97kbps，就把它当结果起播了，而且起播后不再升档。
    /// 现在给到 2.6s，并且在"只拿到低档"时再多等 `startLowTierGrace`。
    static let startWindow: TimeInterval = 2.6

    /// 只拿到低档时的"第二窗口"：再等这么久，看 320k / 无损能不能赶上来。
    /// 代价是这一类歌起播最多慢 1.2s；换来的是"不静默降级"。
    static let startLowTierGrace: TimeInterval = 1.2

    /// 「够档」的门槛：320k 档（`tierOf` 700）。到手就不用再等。
    static let startGoodEnoughTier = 700

    /// 一批候选里挑"起播用哪条"：档位 > 实测码率 > 响应快（纯函数，CI 钉口径）。
    ///
    /// 为什么不直接用 `Score`：`Score` 里还掺了版本/时长/来源可靠性，起播这一步只关心
    /// "同样是一首对的歌，哪条更不亏"——那三个维度对它已经没有区分度。
    static func bestForStart(_ candidates: [Candidate]) -> Candidate? {
        candidates.max { a, b in
            if a.score.tier != b.score.tier { return a.score.tier < b.score.tier }
            if a.source.kbps != b.source.kbps { return a.source.kbps < b.source.kbps }
            return a.elapsedMs > b.elapsedMs
        }
    }

    /// 起播挑选（老板 2026-11-22：开头 10 秒左右会卡一下）。
    ///
    /// **旧路径**：`firstPlayable` 谁先回来用谁。酷狗官方 128k 与星海酷狗 320k 都落在 0.9–1.1s，
    /// 128k 常常先到 → 先以 128k 起播，再由 `AudioPlayer.schedulePlaybackUpgrade` 后台换成 320k。
    /// 那一步是 `player.replaceCurrentItem` + seek：**缓冲从 0 重来**，听着就是"放着放着卡一下"，
    /// 而且换的时候进度已经走了 1–5 秒，正好落在"开头 10 秒"里。
    ///
    /// **现在**：一次挑好，起播之后不再换 item。
    ///   · 320k 一到（`startGoodEnoughTier`）立刻起播 —— 和以前一样快（~1.0s）；
    ///   · 拿不到 320k 就等满 `window`，**再多等 `lowTierGrace`**（只拿到低档时），
    ///     看慢后端能不能把 320k/无损补上来（2026-11-26 老板：不许静默降级）；
    ///   · 窗口内一条都没有 → nil，由调用方继续走后面的兜底（完整排名 / 跨平台 / 无损兜底）。
    static func startPick(song: Song, want: QualityLevel,
                          window: TimeInterval = startWindow,
                          lowTierGrace: TimeInterval = startLowTierGrace) async -> Candidate? {
        let jobs = primaryJobs(for: song).filter {
            !BackendHealth.shared.isCoolingDown($0.adapter.name)
        }
        guard !jobs.isEmpty else { return nil }
        let start = Date()
        let hardDeadline = window + max(0, lowTierGrace)

        /// 组里的一个结果：真候选 / 某个 job 空手而归 / 窗口到点的闹钟
        enum Step: Sendable { case candidate(Candidate), jobFailed, wake }

        return await withTaskGroup(of: Step.self) { group in
            for job in jobs {
                group.addTask {
                    // 每个后端最多用掉"硬截止"剩下的时间（后端内部还有自己的超时）
                    let left = max(0.5, hardDeadline - Date().timeIntervalSince(start))
                    let t0 = Date()
                    guard let src = await withTimeoutOrNil(left, {
                        try await job.adapter.resolve(song: job.song, quality: want)
                    }) else { return .jobFailed }
                    // 身份闸：primary 后端拿的就是这首歌自己；跨源条目才需要再验一次
                    if job.song.id != song.id, !NameMatch.sameRecording(src: song, cand: job.song) {
                        return .jobFailed
                    }
                    guard PlaybackQualityRules.isUsable(src, songDurationSec: song.durationSec) else {
                        return .jobFailed
                    }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    return .candidate(Candidate(song: job.song, source: src.matched(job.song),
                                                elapsedMs: ms,
                                                score: score(of: src, song: job.song, ref: song, ms: ms)))
                }
            }
            // 闹钟：到 `window` 叫醒一次，好让我们在"只有低档"时决定要不要再等 grace
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, window) * 1_000_000_000))
                return .wake
            }

            var best: Candidate?
            var outstanding = jobs.count
            var graceGranted = false
            for await step in group {
                switch step {
                case .candidate(let c):
                    outstanding -= 1
                    if let b = best {
                        if c.score.tier > b.score.tier
                            || (c.score.tier == b.score.tier && c.source.kbps > b.source.kbps) {
                            best = c
                        }
                    } else {
                        best = c
                    }
                    // 够档就立刻起播，剩下的候选直接取消（不再等）
                    if let b = best, b.score.tier >= startGoodEnoughTier {
                        group.cancelAll()
                        return b
                    }
                    // 所有 job 都回来了：不用等闹钟
                    if outstanding == 0 {
                        group.cancelAll()
                        return best
                    }
                case .jobFailed:
                    outstanding -= 1
                    if outstanding == 0 {
                        group.cancelAll()
                        return best
                    }
                case .wake:
                    let elapsed = Date().timeIntervalSince(start)
                    // 一条都没回来：不额外等，交给调用方的后续兜底（plan / 跨平台）
                    if best == nil {
                        group.cancelAll()
                        return nil
                    }
                    if !graceGranted, elapsed < window + 0.05 {
                        // 只拿到低档 → 再等一段，看 320k/无损能不能补上来
                        graceGranted = true
                        continue
                    }
                    group.cancelAll()
                    return best
                }
            }
            return best
        }
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

    /// 目标档判定：容器 + 码率都由取流阶段实测得到；时长未知时退回"档位桶"这一层近似。
    /// （排名引擎不再用它选源，但它是"这条源到底是不是用户要的档"的唯一口径，SelfTest 也钉着。）
    static func isExact(_ src: StreamSource, want: QualityLevel, durationSec: Int) -> Bool {
        if durationSec <= 0 || src.kbps <= 0 { return src.quality == want }
        return QualityFacts.matches(want, container: src.format, kbps: src.kbps)
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

        return Score(identity: NameMatch.identityRank(src: ref, cand: song),
                     tier: tierOf(src), version: version, duration: duration,
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
        // 冷却中的后端不占预算（妖狐 403 之后 15 分钟不再叫它）
        let live = jobs.filter { !BackendHealth.shared.isCoolingDown($0.adapter.name) }
        guard !live.isEmpty else { return [] }
        let start = Date()
        return await withTaskGroup(of: RawCandidate?.self) { group in
            for job in live {
                group.addTask {
                    let left = max(1, deadline - Date().timeIntervalSince(start))
                    let t0 = Date()
                    let src = await withTimeoutOrNil(left) {
                        try await job.adapter.resolve(song: job.song, quality: want)
                    }
                    guard let src else { return nil }
                    return RawCandidate(song: job.song, source: src.matched(job.song),
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
