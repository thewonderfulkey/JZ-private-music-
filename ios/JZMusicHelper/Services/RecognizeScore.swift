import Foundation

// MARK: - 识曲候选（两条通道归一化后的同一种形状）
//
// 与 Android `RecognizeAdapter.Hit` 同字段：除了搜索要用的歌名/歌手/专辑，还带上
// 打分需要的证据（通道来源、通道内位次、时长、酷狗的 is_original）。
struct RecognizeCandidate: Hashable {
    let title: String
    let artist: String
    let album: String
    /// 0 = 通道没给
    let durationSec: Int
    /// kugou / netease
    let source: String
    /// 通道内位次（0 = 该通道第一条）
    let rank: Int
    /// 仅酷狗：1 原唱 / 2 翻唱·他人版本 / 4 原唱但非录音室 / 0 未知 / -1 通道不提供
    let isOriginal: Int
    /// 融合后的评分（由 RecognizeScore 写回）
    var score: Int = 0

    var identityKeyValue: String { RecognizeScore.identityKey(self) }
}

// MARK: - 通道判词：这条命中是不是"现场 / 综艺 / 翻唱"
enum RecognizeJudge {

    /// 歌名里带这些词 = 编曲/现场/翻唱类版本，本身就不是录音室原版
    private static let variantTitle = try! NSRegularExpression(
        pattern: "伴奏|伴唱|纯音乐|instrumental|钢琴|翻唱|cover|remix|live|现场|演唱会|片段|剪辑|ktv|dj|消音|合唱",
        options: [.caseInsensitive])

    /// 专辑名带这些词 = 综艺/节目/现场专辑（如《异口同声 第十二期》）
    private static let varietyAlbum = try! NSRegularExpression(
        pattern: "综艺|异口同声|节目|第[0-9一二三四五六七八九十]+期|演唱会|音乐节|晚会|春晚|live|现场",
        options: [.caseInsensitive])

    static func isVariantHit(title: String, album: String) -> Bool {
        isVariantTitle(title) || isVarietyAlbum(album)
    }

    static func isVariantTitle(_ name: String) -> Bool {
        matches(variantTitle, name)
    }

    static func isVarietyAlbum(_ album: String) -> Bool {
        matches(varietyAlbum, album)
    }

    /// 专辑名"就是歌名"（含「我们都一样 EP」「我们都一样 (回忆版)」这类）——几乎都是同名合集
    static func isSameAlbumAsTitle(_ album: String, _ title: String) -> Bool {
        let a = normName(album)
        let t = normName(title)
        if a.isEmpty || t.isEmpty { return false }
        return a == t || a.hasPrefix(t)
    }

    /// 归一化：繁转简 + 小写 + 只留字母数字（去空格标点括号，CJK 属字母会保留）
    static func normName(_ s: String) -> String {
        let simplified = TraditionalMap.toSimplified(s).lowercased()
        var out = ""
        out.unicodeScalars.append(contentsOf: simplified.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        return out
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - 双通道统一打分（口径见 docs/ios/IOS-RECOGNIZE.md）
//
// 为什么不是"哪家先返回用哪家"：酷狗经常把某首歌认成别人的翻唱/综艺版（指纹接口只回它曲库里
// 最像的那一条），而网易那边有原唱。所以两条通道的候选放进同一个池子，按「同一首歌」聚类后
// 用可解释的结构特征打分，取最高分——换通道、加通道都不用重调阈值。
enum RecognizeScore {

    static let sourceKugou = "kugou"
    static let sourceNetease = "netease"

    /// 一个"曲目身份"的打分结果
    struct Item: Hashable {
        let rep: RecognizeCandidate
        let score: Int
        let channels: Set<String>
        let formalAlbums: Int
        let durationConfirmed: Bool
    }

    struct Result: Hashable {
        let ranked: [Item]
        /// 每个通道自己最好的那条分数（界面说明"谁给的更可信"）
        let bestByChannel: [String: Int]
        /// 一句话结论，直接显示在结果卡上
        let note: String
    }

    static func fuse(kugou: [RecognizeCandidate], netease: [RecognizeCandidate]) -> Result? {
        let all = (kugou + netease).filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !all.isEmpty else { return nil }

        // 1) 归并同一曲目身份
        var order: [String] = []
        var groups: [String: [RecognizeCandidate]] = [:]
        for candidate in all {
            let key = identityKey(candidate)
            guard !key.isEmpty else { continue }
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(candidate)
        }

        // 2) 逐身份打分
        let items = order.compactMap { groups[$0].flatMap(scoreIdentity) }
        guard !items.isEmpty else { return nil }

        // 3) 排序：分数 → 原唱标记 → 标题更短（原版多为裸名）→ 通道内位次 → 酷狗优先
        let ordered = items.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let ra = originalRank(a.rep.isOriginal), rb = originalRank(b.rep.isOriginal)
            if ra != rb { return ra < rb }
            if a.rep.title.count != b.rep.title.count { return a.rep.title.count < b.rep.title.count }
            if a.rep.rank != b.rep.rank { return a.rep.rank < b.rep.rank }
            return (a.rep.source == sourceKugou ? 0 : 1) < (b.rep.source == sourceKugou ? 0 : 1)
        }

        // 4) 通道各自最好的分数（按单条候选算，不含互证加成）
        var bestByChannel: [String: Int] = [:]
        for candidate in all {
            let s = memberScore(candidate)
            if let current = bestByChannel[candidate.source] {
                if s > current { bestByChannel[candidate.source] = s }
            } else {
                bestByChannel[candidate.source] = s
            }
        }

        guard let top = ordered.first else { return nil }
        return Result(ranked: ordered, bestByChannel: bestByChannel,
                      note: noteOf(top, best: bestByChannel))
    }

    private static func originalRank(_ isOriginal: Int) -> Int {
        switch isOriginal {
        case 1: return 0
        case 0, -1: return 1
        default: return 2
        }
    }

    /// 曲目身份键：核心歌名 + 第一位歌手（归一化、繁转简）
    static func identityKey(_ c: RecognizeCandidate) -> String {
        let core = RecognizeJudge.normName(StudioPick.coreName(c.title).isEmpty
                                           ? c.title : StudioPick.coreName(c.title))
        let singer = RecognizeJudge.normName(firstArtist(c.artist))
        return core.isEmpty ? "" : "\(core)|\(singer)"
    }

    static func firstArtist(_ raw: String) -> String {
        var cut = raw.endIndex
        for separator in ["/", "、", ",", "，", "&", "·", "|"] {
            if let r = raw.range(of: separator), r.lowerBound < cut {
                cut = r.lowerBound
            }
        }
        return String(raw[raw.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
    }

    /// 单条候选得分（不含身份级加成）
    static func memberScore(_ c: RecognizeCandidate) -> Int {
        var s = 0
        switch c.isOriginal {
        case 1: s += 45
        case 2: s -= 30
        case 4: s -= 8
        default: break
        }

        s += StudioPick.isCleanTitle(c.title) ? 12 : -35

        let album = c.album.trimmingCharacters(in: .whitespaces)
        if album.isEmpty {
            s -= 8
        } else if RecognizeJudge.isSameAlbumAsTitle(album, c.title) {
            s -= 20
        } else if RecognizeJudge.isVarietyAlbum(album) || StudioPick.isLiveAlbum(album) {
            s -= 28
        } else {
            s += 15
        }

        if (30...1800).contains(c.durationSec) { s += 4 }
        s += max(0, 7 - c.rank * 2)
        if c.source == sourceNetease { s += 2 }
        return s
    }

    private static func scoreIdentity(_ members: [RecognizeCandidate]) -> Item? {
        guard !members.isEmpty else { return nil }
        guard let rep = members.max(by: { memberScore($0) < memberScore($1) }) else { return nil }
        var score = memberScore(rep)

        let channels = Set(members.map { $0.source })
        if channels.count >= 2 { score += 50 }

        var formalAlbums = Set<String>()
        for c in members {
            let album = c.album.trimmingCharacters(in: .whitespaces)
            if album.isEmpty { continue }
            if RecognizeJudge.isSameAlbumAsTitle(album, c.title) { continue }
            if RecognizeJudge.isVarietyAlbum(album) || StudioPick.isLiveAlbum(album) { continue }
            formalAlbums.insert(RecognizeJudge.normName(album))
        }
        let durations = members.map { $0.durationSec }.filter { $0 > 0 }.sorted()
        let durationConfirmed = durations.count >= 2
            && (durations[durations.count - 1] - durations[0]) <= 3
        if formalAlbums.count >= 2 && durationConfirmed { score += 22 }

        return Item(rep: rep, score: score, channels: channels,
                    formalAlbums: formalAlbums.count, durationConfirmed: durationConfirmed)
    }

    private static func noteOf(_ top: Item, best: [String: Int]) -> String {
        let kg = best[sourceKugou].map(String.init) ?? "—"
        let ne = best[sourceNetease].map(String.init) ?? "—"
        let how: String
        if top.channels.count >= 2 {
            how = "双通道互证"
        } else if top.rep.source == sourceKugou {
            how = "采用酷狗"
        } else if top.rep.source == sourceNetease {
            how = "采用网易"
        } else {
            how = "采用最高分"
        }
        return "识别依据：酷狗 \(kg) ／ 网易 \(ne) → \(how)"
    }
}
