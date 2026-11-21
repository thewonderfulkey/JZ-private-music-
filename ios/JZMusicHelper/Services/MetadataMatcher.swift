import Foundation

// MARK: - 歌曲元数据：出处 / 字段锁 / 联网匹配（第 44 轮，2026-11-21 老板拍板）
//
// 老板原话（两轮）：
//   · "导入歌曲后本应自动寻找歌词和封面、下载到后台文件、并形成前端快照"
//   · "给下载 tab 中加一个可以自己修改歌曲信息的功能（可修改封面、歌手、歌曲名称），
//      人工修改后用修改后的信息去获取封面然后内置形成快照"
//
// 这条链要解决的是**同一个根**：导入歌的 name/singer/album 只来自标签（缺了就用文件名猜），
// 之后**再也没有任何一步去联网核对**，歌名/歌手一旦是空的或拆反的，取词和取封面就全歪。
//
// 设计（与 B1/B2/B4 对齐，不另造一套）：
//   ① 每个 Song 带一份 `MetaProvenance`：来源（tag/filenameGuess/matched/manual/unmatched）、
//      **字段级锁**、命中平台/id、置信分、封面是否过期、封面代次；
//   ② 匹配打分是**纯函数**（`MetadataMatcher`），阈值 0.85 自动写、0.6–0.85 待确认、<0.6 留空；
//   ③ 写回只有一条通道（`MetadataWriter` → 四处快照 + 三处缓存），手动编辑与自动匹配共用；
//   ④ 文件名兜底可能把「歌名 - 歌手」拆反（老板库里两种命名混着），所以匹配时允许
//      **A/B 两种解释**，取分高的那组 —— 但标签来源（tag）不猜，只按标签来。
//
// 硬约束（老板点名）：`platformID` 不动、音频文件名/基名不动、`Song` 的字段仍然 let。

// MARK: - 出处

enum MetaSource: String, Codable, Hashable, Sendable {
    /// 文件标签（AVFoundation commonMetadata）
    case tag
    /// 标签缺 → 用文件名推的（可能拆反）
    case filenameGuess
    /// 联网匹配写回的
    case matched
    /// 用户手动编辑的
    case manual
    /// 都没有（留空，可重试）
    case unmatched

    var label: String {
        switch self {
        case .tag: return "标签"
        case .filenameGuess: return "文件名推测"
        case .matched: return "联网匹配"
        case .manual: return "手动编辑"
        case .unmatched: return "未匹配"
        }
    }
}

enum MetaField: String, Codable, Hashable, CaseIterable, Sendable {
    case name, singer, album, cover

    var label: String {
        switch self {
        case .name: return "歌名"
        case .singer: return "歌手"
        case .album: return "专辑"
        case .cover: return "封面"
        }
    }
}

/// 一个 Song 的元数据出处。**整体随 Song 走**（四处快照各自持有一份 Song，就不用额外同步这张表）。
struct MetaProvenance: Codable, Hashable, Sendable {

    var source: MetaSource = .unmatched
    /// 用户手填过的字段：自动匹配/再匹配**永不覆盖**，直到用户点「恢复自动」
    var locked: [MetaField] = []
    /// 命中平台（"qq" / "netease" / "kuwo"），没有就是 nil
    var matchedPlatform: String?
    /// 命中曲目在该平台的 id（QQ 就是 songmid，可直接拿去取官方词）
    var matchedID: String?
    /// 置信分 0…1（阈值见 `MetadataMatcher.autoThreshold`）
    var score: Double = 0
    /// 改过歌名/歌手之后，旧封面可能已经不是这首歌的图
    var coverStale: Bool = false
    /// 封面代次：每换一次封面 +1。列表行/锁屏判重都带它，否则"图换了但界面还是旧的"
    var coverRevision: Int = 0

    init(source: MetaSource = .unmatched,
         locked: [MetaField] = [],
         matchedPlatform: String? = nil,
         matchedID: String? = nil,
         score: Double = 0,
         coverStale: Bool = false,
         coverRevision: Int = 0) {
        self.source = source
        self.locked = locked
        self.matchedPlatform = matchedPlatform
        self.matchedID = matchedID
        self.score = score
        self.coverStale = coverStale
        self.coverRevision = coverRevision
    }

    func isLocked(_ field: MetaField) -> Bool { locked.contains(field) }

    mutating func lock(_ field: MetaField) {
        if !locked.contains(field) { locked.append(field) }
    }

    mutating func unlock(_ field: MetaField) {
        locked.removeAll { $0 == field }
    }

    /// 日志口径：`tag` / `filenameGuess` / `matched:qq` / `manual` / `unmatched`
    var logTag: String {
        if let p = matchedPlatform, !p.isEmpty, source == .matched { return "matched:\(p)" }
        return source.rawValue
    }

    /// 有没有"还是空着、可以再试一次"的字段（给批量补全算缺口）
    static func needsFill(_ song: Song) -> Bool {
        let meta = song.meta
        if song.name.isEmpty || song.singer.isEmpty || song.album.isEmpty { return true }
        return meta == nil || meta?.source == .unmatched || meta?.source == .tag
            || meta?.matchedID == nil
    }
}

// MARK: - 匹配结果

enum MatchVerdict: String, Sendable {
    /// ≥0.85：直接写回
    case auto
    /// 0.6–0.85：不自动写，进「待确认」等老板点
    case confirm
    /// <0.6：留空，可重试
    case reject
}

/// 匹配到的一组值（不含"要不要写"的判断）
struct MatchedMetadata: Sendable {
    var name: String
    var singer: String
    var album: String
    var picURL: String?
    var platform: MusicPlatform
    var platformID: String
    var score: Double
}

/// 一次匹配的完整结论（日志、UI、队列都用它）
struct MatchOutcome: Sendable {
    /// 用哪组解释去搜的（A = 歌名/歌手，B = 把两者对调后的解释）
    var query: String = ""
    var swapped: Bool = false
    var candidateCount: Int = 0
    var best: MatchedMetadata?
    var verdict: MatchVerdict = .reject
    /// 最好候选的分项分（日志用）
    var detail: String = ""
}

// MARK: - 纯逻辑：解释、打分、阈值、写回

enum MetadataMatcher {

    /// ≥ 这个分自动写回（老板拍板）
    static let autoThreshold = 0.85
    /// ≥ 这个分算"可能是"，进人工确认（老板拍板）
    static let confirmThreshold = 0.60
    /// 时长差超过这个数直接判不是同一条录音（秒）
    static let maxDurationDelta = 4
    /// 时长差超过这个数连"待确认"都不进（宁可空着）
    static let hardDurationDelta = 8

    // MARK: 解释（A/B 两解）

    struct Query: Hashable, Sendable {
        var name: String
        var singer: String
        /// 是不是把文件名里的「歌名 / 歌手」对调了
        var swapped: Bool

        var keyword: String {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = singer.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? n : "\(n) \(s)"
        }
    }

    /// 这首歌该用哪几种解释去搜。
    ///
    /// 只有**文件名推测**才允许对调：标签里的 name/singer 是文件自己声明的，
    /// 对调它们等于怀疑标签，会把本来正确的歌搜歪。
    static func queries(for song: Song) -> [Query] {
        let name = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let singer = song.singer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let a = Query(name: name, singer: singer, swapped: false)
        // 只有**本地导入**且**歌手是猜的**才允许对调；网络搜来的歌（meta == nil）歌手是平台给的，不动。
        let maySwap = song.platform == .local
            && (song.meta?.source == .filenameGuess || song.meta?.source == .unmatched)
            && !singer.isEmpty && singer != name
        guard maySwap else { return [a] }
        return [a, Query(name: singer, singer: name, swapped: true)]
    }

    // MARK: 归一化

    /// 归一化歌名：小写、去空白/标点、全角括号统一（只用于比较，不改显示值）
    static func normalize(_ raw: String) -> String {
        let punctuation = CharacterSet(charactersIn:
            " \t\n\r-_·、,，.。()（）[]【】《》'\"!?！？~&/+:：;；|")
        let lowered = raw.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .lowercased()
        return String(lowered.unicodeScalars.filter { !punctuation.contains($0) }
            .map(Character.init))
    }

    /// 去掉版本后缀后的"核心歌名"（Live / 伴奏 / 翻唱…），复用既有口径
    static func coreName(_ raw: String) -> String {
        normalize(StudioPick.coreName(raw))
    }

    /// 歌名相似度：完全相等 1.0；核心名相等 0.85（版本不同，不自动写）；前缀包含 0.6；否则 0
    static func titleScore(_ target: String, _ candidate: String) -> Double {
        let a = normalize(target)
        let b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1.0 }
        if coreName(target) == coreName(candidate) { return 0.85 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return 0.6 }
        return 0
    }

    /// 歌手相似度：任一片段相等 1.0；互相包含 0.7；一边为空 0.5（中性）；否则 0
    static func artistScore(_ target: String, _ candidate: String) -> Double {
        let a = singerParts(target)
        let b = singerParts(candidate)
        guard !a.isEmpty, !b.isEmpty else { return 0.5 }
        if !a.filter({ b.contains($0) }).isEmpty { return 1.0 }
        for x in a {
            for y in b where x.contains(y) || y.contains(x) {
                return 0.7
            }
        }
        return 0
    }

    static func singerParts(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "、", with: "/")
            .replacingOccurrences(of: "&", with: "/")
            .split(separator: "/")
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func albumScore(_ target: String, _ candidate: String) -> Double {
        let a = normalize(target)
        let b = normalize(candidate)
        guard !a.isEmpty, !b.isEmpty else { return 0.5 }
        return a == b ? 1.0 : 0
    }

    /// 时长分：差值 ≤4s 满分；≤8s 半分；一边没时长 0.5（中性）；否则 0
    static func durationScore(_ target: Int, _ candidate: Int) -> Double {
        guard target > 0, candidate > 0 else { return 0.5 }
        let delta = abs(target - candidate)
        if delta <= maxDurationDelta { return 1.0 }
        if delta <= hardDurationDelta { return 0.5 }
        return 0
    }

    /// 总分 = 歌名 0.50 + 歌手 0.25 + 专辑 0.10 + 时长 0.15
    static func score(query: Query, song: Song, candidate: Song) -> Double {
        let t = titleScore(query.name, candidate.name)
        let a = artistScore(query.singer, candidate.singer)
        let al = albumScore(song.album, candidate.album)
        let d = durationScore(song.durationSec, candidate.durationSec)
        return 0.50 * t + 0.25 * a + 0.10 * al + 0.15 * d
    }

    /// 硬闸门：先过这几条，再看得分。
    ///
    /// "错配比缺失更糟"是老板三令五申的口径，所以：
    ///   · 歌名必须真的对得上（≥0.85，即同核心名）；
    ///   · 歌手不能明摆着冲突（两边都有歌手、而且一个片段都不重合 → 直接拒）；
    ///   · 时长差 >8s → 直接拒（不同录音）。
    static func passesGate(query: Query, song: Song, candidate: Song) -> Bool {
        guard titleScore(query.name, candidate.name) >= 0.85 else { return false }
        let a = artistScore(query.singer, candidate.singer)
        if !singerParts(query.singer).isEmpty, !singerParts(candidate.singer).isEmpty, a == 0 {
            return false
        }
        if song.durationSec > 0, candidate.durationSec > 0,
           abs(song.durationSec - candidate.durationSec) > hardDurationDelta {
            return false
        }
        return true
    }

    static func verdict(for score: Double) -> MatchVerdict {
        if score >= autoThreshold { return .auto }
        if score >= confirmThreshold { return .confirm }
        return .reject
    }

    // MARK: 从候选里挑最好的

    /// 在 A/B 两种解释下给所有候选打分，挑最高的一条（过不了硬闸门的候选直接丢）
    static func pick(song: Song, candidates: [Song]) -> MatchOutcome {
        var outcome = MatchOutcome()
        outcome.candidateCount = candidates.count
        var bestScore = -1.0
        var best: Song?
        var bestQuery: Query?
        var bestDetail = ""

        for q in queries(for: song) {
            for cand in candidates {
                guard passesGate(query: q, song: song, candidate: cand) else { continue }
                let s = score(query: q, song: song, candidate: cand)
                if s > bestScore {
                    bestScore = s
                    best = cand
                    bestQuery = q
                    bestDetail = String(format: "歌名%.2f 歌手%.2f 专辑%.2f 时长%.2f",
                                        titleScore(q.name, cand.name),
                                        artistScore(q.singer, cand.singer),
                                        albumScore(song.album, cand.album),
                                        durationScore(song.durationSec, cand.durationSec))
                }
            }
        }

        guard let best, let q = bestQuery, bestScore >= confirmThreshold else {
            outcome.verdict = .reject
            outcome.detail = best == nil ? "无候选过硬闸" : String(format: "最高 %.2f 分，低于确认线", max(0, bestScore))
            return outcome
        }

        outcome.query = q.keyword
        outcome.swapped = q.swapped
        outcome.verdict = verdict(for: bestScore)
        outcome.detail = bestDetail
        outcome.best = MatchedMetadata(name: best.name, singer: best.singer,
                                       album: best.album, picURL: best.picURL,
                                       platform: best.platform, platformID: best.platformID,
                                       score: bestScore)
        return outcome
    }

    // MARK: 写回（字段级锁）

    /// 把匹配结果并进 Song：**locked 的字段一个都不动**，其余只在"候选有值"时覆盖。
    ///
    /// 用户只改了歌手 → locked = [.singer]，那么歌名/专辑/封面仍然可以随匹配更新；
    /// 用户改了歌名 → locked = [.name]，封面会被标 `coverStale`（旧图可能不是这首歌了）。
    static func merge(into current: Song, matched: MatchedMetadata,
                      source: MetaSource = .matched) -> Song {
        var meta = current.meta ?? MetaProvenance()
        let name = meta.isLocked(.name) ? current.name
            : (matched.name.isEmpty ? current.name : matched.name)
        let singer = meta.isLocked(.singer) ? current.singer
            : (matched.singer.isEmpty ? current.singer : matched.singer)
        let album = meta.isLocked(.album) ? current.album
            : (matched.album.isEmpty ? current.album : matched.album)
        let pic = meta.isLocked(.cover) ? current.picURL : (matched.picURL ?? current.picURL)

        let nameChanged = name != current.name
        let singerChanged = singer != current.singer
        if nameChanged || singerChanged { meta.coverStale = true }

        meta.source = meta.locked.isEmpty ? source : .manual
        meta.matchedPlatform = matched.platform.rawValue
        meta.matchedID = matched.platformID
        meta.score = matched.score

        return current.with(name: name, singer: singer, album: album, picURL: pic, meta: meta)
    }

    /// 手动编辑：把用户改过的字段锁住，其余字段原样保留；
    /// 歌名/歌手有实质变化时把封面标成"可能已不匹配"（不清空 —— 清空会让那行直接变音符占位）。
    static func applyingManualEdit(to current: Song, name: String, singer: String,
                                   album: String, cover: MetaField?) -> Song {
        var meta = current.meta ?? MetaProvenance()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSinger = singer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName != current.name { meta.lock(.name) }
        if trimmedSinger != current.singer { meta.lock(.singer) }
        if trimmedAlbum != current.album { meta.lock(.album) }
        if let cover { meta.lock(cover) }

        let nameChanged = !trimmedName.isEmpty && trimmedName != current.name
        let singerChanged = trimmedSinger != current.singer
        if nameChanged || singerChanged { meta.coverStale = true }
        if cover != nil { meta.coverRevision += 1; meta.coverStale = false }

        meta.source = .manual
        return current.with(name: trimmedName.isEmpty ? current.name : trimmedName,
                            singer: trimmedSinger,
                            album: trimmedAlbum,
                            picURL: current.picURL,
                            meta: meta)
    }

    /// 「恢复自动」：解锁全部字段、清掉命中 id 与分数，让下一次匹配重新决定
    static func resettingToAuto(_ current: Song) -> Song {
        var meta = current.meta ?? MetaProvenance()
        meta.locked = []
        meta.matchedID = nil
        meta.matchedPlatform = nil
        meta.score = 0
        meta.coverStale = false
        meta.source = .unmatched
        // `.some(nil)` = 明确把封面地址清空（普通 `nil` 在 `String??` 里表示"不改"，会留在旧图）
        return current.with(name: current.name, singer: current.singer,
                            album: current.album, picURL: .some(nil), meta: meta)
    }

    /// 换封面（用户自选图 / 下载到新图）：代次 +1，让三处缓存全部失效
    static func markingCoverChanged(_ current: Song) -> Song {
        var meta = current.meta ?? MetaProvenance()
        meta.coverRevision += 1
        meta.coverStale = false
        if meta.locked.isEmpty, meta.source == .unmatched { meta.source = .manual }
        return current.with(name: current.name, singer: current.singer,
                            album: current.album, picURL: current.picURL, meta: meta)
    }
}

// MARK: - 联网：一次 QQ 搜索同时拿到封面与官方词 id

enum MetadataIQ {

    /// 只用 QQ 官方搜索：它一次就给出 songmid（取词用）+ albummid（封面用）+ 歌手/专辑/时长，
    /// 是唯一「一次请求补全四个字段」的源。
    ///
    /// 不拿 iTunes 当主兜底（老板 r90 口径 + 本轮再次确认）：华语相关性差，搜「青花瓷 周杰伦」
    /// 第一条是《屋顶》，只适合当"最后一级且必须严格匹配"。
    static func search(_ query: MetadataMatcher.Query, limit: Int = 10) async -> [Song] {
        guard !query.keyword.isEmpty else { return [] }
        let adapter = QQSearchAdapter()
        return (try? await adapter.search(keyword: query.keyword, limit: limit)) ?? []
    }

    /// 跑一次完整匹配（A/B 两解 → 打分 → 闸门 → 结论）
    static func match(_ song: Song) async -> MatchOutcome {
        let queries = MetadataMatcher.queries(for: song)
        guard !queries.isEmpty else { return MatchOutcome() }
        var all: [Song] = []
        var seen = Set<String>()
        var used = ""
        var swapped = false
        for q in queries {
            let list = await search(q)
            if used.isEmpty, !list.isEmpty { used = q.keyword; swapped = q.swapped }
            for s in list where seen.insert(s.id).inserted { all.append(s) }
        }
        var outcome = MetadataMatcher.pick(song: song, candidates: all)
        if outcome.query.isEmpty { outcome.query = used; outcome.swapped = swapped }
        return outcome
    }
}
