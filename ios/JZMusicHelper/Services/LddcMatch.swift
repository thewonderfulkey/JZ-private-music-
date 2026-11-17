import Foundation

// MARK: - LDDC 候选匹配评分
//
// 移植自 chenmozhijin/LDDC（GPL-3.0，`core/algorithm.py`），与 Android `LddcMatch.kt` 同一套。
// 用途：酷狗 / QQ 各自搜到一批候选，按「标题像不像 + 歌手像不像」打分，
// 只有 **>55 分** 且**时长差 ≤4s** 的候选才允许取词——否则会把翻唱版/Live 版的词贴到原唱上。
//
// 打分口径（一个数都不改）：
//   标题分 × 0.5 + 歌手分 × 0.5；标题分 <30 时再 −35（对齐 LDDC auto_fetch 的 min_score=55）
//   标题分：先看完全相等（100），否则用 LCS 相似度打底，再把括号/版本 tag 剥出来单独比
//   歌手分：先看单对单完全相等（100），否则取「歌手列表贪心配对」与「整串 LCS」的较大者
enum LddcMatch {

    // MARK: 标题评分

    // 三组捕获：① 括号内 tag ② 词 tag（ver/size/mix/edit/版/solo）③ 纯音乐/inst/off vocal
    // Python 的 \w 是 Unicode，Kotlin 默认 ASCII，这里统一用 [\p{L}\p{N}_]
    private static let titleTagPattern = Pattern.make(
        "[-<(\\[～]([～\\]^)>-]*)|([\\p{L}\\p{N}_]+ ?(?:(?:solo |size )?ver(?:sion)?\\.?|size|style|mix(?:ed)?|edit(?:ed)?|版|solo))|(纯音乐|inst\\.?(?:rumental)|off ?vocal(?: ?[Vv]er.))"
    )

    private static let tagSymbolClass = "[-><)(\\]\\[～]"

    /// 提取 tag 并归一化，返回 (tags, 剩余文本)。对齐 LDDC `get_tags`
    static func titleTags(_ notSame: String) -> (tags: [String], other: String) {
        var tags: [String] = []
        for groups in titleTagPattern.allMatches(notSame) {
            for g in groups where !g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tags.append(g.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // tags 为空：LDDC 的 `re.sub("|[...]", "", s)` 空分支不删任何字符 → 剩余文本原样
        var other = notSame
        if !tags.isEmpty {
            let pattern = tags.joined(separator: "|") + "|" + tagSymbolClass
            if let re = try? NSRegularExpression(pattern: pattern) {
                other = re.stringByReplacingMatches(
                    in: notSame, range: NSRange(notSame.startIndex..<notSame.endIndex, in: notSame),
                    withTemplate: "")
            }
        }
        // 逐项归一化（对齐 LDDC）
        let verPattern = Pattern.make("ver(?:sion)?\\.?|伴奏|纯音乐|inst\\.?(?:rumental)|off ?vocal(?: ?[Vv]er.)?")
        let verOnly = Pattern.make("ver(?:sion)?\\.?")
        let suffixVer = Pattern.make("(solo|mix|edit|style|size) ver")
        let tvPattern = Pattern.make("(?:tv|anime) ?(?:サイズ|size)?(?: ?edit)?(?: ?ver)?")
        for i in tags.indices {
            var t = tags[i]
            if t.contains("ver") || t == "伴奏" || t == "纯音乐" {
                t = verPattern.stringByReplacingMatches(
                    in: t, range: NSRange(t.startIndex..<t.endIndex, in: t), withTemplate: "inst")
            }
            if t.contains("ver") {
                t = verOnly.stringByReplacingMatches(
                    in: t, range: NSRange(t.startIndex..<t.endIndex, in: t), withTemplate: "ver")
            }
            t = t.replacingOccurrences(of: "mixed", with: "mix")
                .replacingOccurrences(of: "edited", with: "edit")
            if t.contains("solo") || t.contains("mix") || t.contains("edit")
                || t.contains("style") || t.contains("size") {
                t = suffixVer.stringByReplacingMatches(
                    in: t, range: NSRange(t.startIndex..<t.endIndex, in: t), withTemplate: "$1")
            }
            if t.contains("tv") || t.contains("anime") {
                t = tvPattern.stringByReplacingMatches(
                    in: t, range: NSRange(t.startIndex..<t.endIndex, in: t), withTemplate: "tv size")
            }
            tags[i] = t
        }
        return (tags, other)
    }

    private static let tagSuffix = Pattern.make("(?:solo|mix|edit|style|size|edit|inst)$")

    /// 标题评分（0…100）
    static func titleScore(_ title1: String, _ title2: String) -> Double {
        let t1 = unifiedSymbol(title1).lowercased()
        let t2 = unifiedSymbol(title2).lowercased()
        if t1 == t2 { return 100 }
        let score0 = max(textDifference(t1, t2), 0) * 100

        // 公共前缀
        var sameBegin = ""
        for (c1, c2) in zip(t1, t2) {
            if c1 == c2 { sameBegin.append(c1) } else { break }
        }
        if sameBegin == t1 || sameBegin == t2 || sameBegin.isEmpty { return score0 }

        let (tags1, other1) = titleTags(String(t1.dropFirst(sameBegin.count)))
        let (tags2, other2) = titleTags(String(t2.dropFirst(sameBegin.count)))

        var tag1NoMatch: [String] = []
        var tag2NoMatch = tags2
        var other1Adj = other1
        var other2Adj = other2

        for tag1 in tags1 {
            if let idx = tag2NoMatch.firstIndex(of: tag1) {
                tag2NoMatch.remove(at: idx)
            } else if tagSuffix.match(tag1) != nil {
                tag1NoMatch.append(tag1)
            } else if other2Adj.contains(tag1) {
                other1Adj += tag1
            }
        }
        var remove2: [String] = []
        for tag2 in tag2NoMatch where tagSuffix.match(tag2) == nil && other1Adj.contains(tag2) {
            other2Adj += tag2
            remove2.append(tag2)
        }
        tag2NoMatch.removeAll { remove2.contains($0) }

        let kp = Double(sameBegin.count)
            / (((Double(other1Adj.count) + Double(other2Adj.count)) / 2) + Double(sameBegin.count))
        let score1 = 100 * kp + max(textDifference(other1Adj, other2Adj), 0) * (1 - kp)

        if tag1NoMatch.isEmpty && tag2NoMatch.isEmpty {
            return max(score1 * 0.7 + 30, score0)
        }
        var score2 = 0.0
        var score3 = 0.0
        if !tag1NoMatch.isEmpty && !tag2NoMatch.isEmpty {
            for tag1 in tag1NoMatch {
                var best = 0.0
                for tag2 in tag2NoMatch { best = max(best, textDifference(tag1, tag2)) }
                score2 += best * (30 / Double(tag1NoMatch.count))
            }
            for tag2 in tag2NoMatch {
                var best = 0.0
                for tag1 in tag1NoMatch { best = max(best, textDifference(tag1, tag2)) }
                score3 += best * (30 / Double(tag2NoMatch.count))
            }
        }
        return max(score1 * 0.7 + max(score2, score3), score0)
    }

    // MARK: 歌手评分

    /// 全角符号 → 半角 + 去首尾空白 + 空白归一（LDDC `unified_symbol`）
    static func unifiedSymbol(_ text: String) -> String {
        let map: [Character: Character] = [
            "（": "(", "）": ")", "：": ":", "！": "!", "？": "?", "／": "/", "＆": "&",
            "＊": "*", "＠": "@", "＃": "#", "＄": "$", "％": "%", "＼": "\\", "｜": "|",
            "＝": "=", "＋": "+", "－": "-", "＜": "<", "＞": ">", "［": "[", "］": "]",
            "｛": "{", "｝": "}",
        ]
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            out.append(map[ch] ?? ch)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// 文本相似度（0…1）：完全相等 1.0；否则 2·LCS/(n+m)
    static func textDifference(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let n = a.count
        let m = b.count
        let aa = Array(a)
        let bb = Array(b)
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                dp[i][j] = aa[i - 1] == bb[j - 1]
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }
        return 2 * Double(dp[n][m]) / Double(n + m)
    }

    private static let bracketAlias = Pattern.make("^(.*?)\\s?\\(([^()]*)\\)$")

    /// 歌手串 → 歌手列表；每项可能是 [原名, 括号别名]
    static func artistStr2List(_ artist: String) -> [[String]] {
        let unified = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "·", with: "・")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "：", with: ":")
        let parts = unified
            .split(whereSeparator: { ",、/\\&".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return [] }
        var result: [[String]] = []
        for p in parts {
            if let m = bracketAlias.match(p), m.count >= 2 {
                let name1 = m[0].trimmingCharacters(in: .whitespacesAndNewlines)
                var name2 = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["CV:", "CV：", "VO:"] where name2.hasPrefix(prefix) {
                    name2 = String(name2.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !name1.isEmpty {
                    var names = [name1]
                    if !name2.isEmpty && name2 != name1 { names.append(name2) }
                    result.append(names)
                } else if !name2.isEmpty {
                    result.append([name2])
                }
            } else {
                result.append([p])
            }
        }
        return result
    }

    /// 两组歌手列表的最大匹配相似度（贪心取最高分对，除以 max(len)）
    static func listMaxDifference(_ list1: [[String]], _ list2: [[String]]) -> Double {
        let l1 = list1.map { $0.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
        let l2 = list2.map { $0.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
        if l1.isEmpty || l2.isEmpty { return 0 }
        var scores: [(Int, Int, Double)] = []
        for i1 in l1.indices {
            for i2 in l2.indices {
                var best = 0.0
                for s1 in l1[i1] { for s2 in l2[i2] { best = max(best, textDifference(s1, s2)) } }
                scores.append((i1, i2, best))
            }
        }
        scores.sort { $0.2 > $1.2 }
        var used1 = Set<Int>()
        var used2 = Set<Int>()
        var total = 0.0
        for (i1, i2, s) in scores {
            if used1.contains(i1) || used2.contains(i2) { continue }
            used1.insert(i1)
            used2.insert(i2)
            total += s
            if used1.count == l1.count || used2.count == l2.count { break }
        }
        return total / Double(max(l1.count, l2.count))
    }

    /// 歌手评分（0…100）
    static func artistScore(_ artist1: String, _ artist2: String) -> Double {
        if artist1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || artist2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 0 }
        let flat1 = artistStr2List(artist1).compactMap { $0.first }.filter { !$0.isEmpty }
        let flat2 = artistStr2List(artist2).compactMap { $0.first }.filter { !$0.isEmpty }
        if flat1.count == 1, flat2.count == 1,
           flat1[0].compare(flat2[0], options: .caseInsensitive) == .orderedSame {
            return 100
        }
        let listScore = listMaxDifference(artistStr2List(artist1), artistStr2List(artist2))
        let joined = textDifference(flat1.joined(), flat2.joined())
        return max(listScore, joined) * 100
    }

    // MARK: 版本标签惩罚

    /// 版本标签表（每行第一项是规范名，其余是同义写法；中英文、全角/半角括号都覆盖）。
    ///
    /// 为什么需要这一层：主评分公式不能动（必须与 APK 一致），但它对
    /// 「七里香」→「七里香 (Live)」这种同歌手、同主标题的候选天然友好：
    /// 标题 LCS 约 46 分、歌手 100 分，总分 73 > 55 直接过线。公式之外再扣一道分：
    /// 候选带着「原查询没有」的版本标签 → 扣 35，直接打回及格线下（73 − 35 = 38）。
    static let versionTags: [[String]] = [
        ["live", "现场", "演唱会"],
        ["cover", "翻唱"],
        ["remix", "dj", "混音"],
        ["inst", "伴奏", "纯音乐", "instrumental", "off vocal", "offvocal"],
        ["karaoke", "卡拉ok"],
        ["片段", "clip"],
        ["demo"],
        ["acoustic", "unplugged"],
        // r73：非歌曲版本。老板《发如雪》那次 51 行「酷我」的词，正文第一句是
        // 「本字幕由QQ音乐独家AI字幕技术生成」——它来自酷我里一条「发如雪 拍摄花絮」的
        // 专访视频，标题分 54.5 + 歌手分 100 正好过线。这类候选必须在标题层就认成"另一个版本"。
        ["花絮", "拍摄花絮", "访谈", "幕后", "彩排", "清唱", "口播", "纪录片"],
        // r69：音质/母带/重制类"版本标记"。
        // 老板反馈《发如雪》拿到的词是「醇享版」——这一类标记以前不在表里，
        // 于是它只按"标题像"打分（85 分）就当选了，时间轴却是另一个剪辑的。
        ["醇享版", "醇享", "纯享", "臻品", "母带", "master", "mastered"],
        ["remaster", "remastered", "重制", "重制版"],
        ["hi-res", "hires", "高解析", "无损", "sq", "hq"],
        ["杜比", "dolby", "全景声", "atmos", "空间音频", "spatial"],
        ["24bit", "32bit", "dsd"],
        ["tv版", "tv size", "tvsize", "片头版", "片尾版"],
    ]

    /// 预编译的标签正则：ASCII 词加词边界（避免 `Olive`/`Demons` 这类误判），中文直接子串匹配。
    /// 放在 static let 里只编译一次，`versionPenalty` 每次只跑匹配。
    private static let versionTagRegexes: [(canonical: String, regex: NSRegularExpression)] =
        versionTags.map { (group) -> (canonical: String, regex: NSRegularExpression) in
            let canonical = group.first ?? ""
            let alternatives = group.map { (alias) -> String in
                let body = alias.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s*")
                // 只含 ASCII 的标签（live/cover/...）要整词匹配；中文标签子串出现即算
                let ascii = alias.unicodeScalars.allSatisfy { $0.isASCII }
                return ascii ? "(?<![a-z0-9])\(body)(?![a-z0-9])" : body
            }
            return (canonical: canonical, regex: Pattern.make(alternatives.joined(separator: "|")))
        }

    /// 标题里出现了哪些版本标签（按规范名归并：`现场` / `live` / `演唱会` 都算 live）
    static func variantTags(_ title: String) -> Set<String> {
        let normalized = unifiedSymbol(title).lowercased()
        guard !normalized.isEmpty else { return [] }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var found = Set<String>()
        for entry in versionTagRegexes
        where entry.regex.firstMatch(in: normalized, range: range) != nil {
            found.insert(entry.canonical)
        }
        return found
    }

    /// 候选带了「查询里没有」的版本标签（live/现场/花絮/伴奏…）→ 这份词属于另一个版本。
    ///
    /// 这是 r73 的核心口径，也是老板两次点名的两句话：
    ///   · 「歌名带 live，就优先选 live 的词」→ 查询自己带 live 时，Live 候选的标签**不额外**，不扣；
    ///   · 「歌词要优先和歌名、歌手匹配」→ 查询不带 live 时，Live/花絮/伴奏候选就是另一个版本。
    /// 注意它**不参与打分**（打分公式必须与 LDDC 一致），只用来决定"同分时的先后"和"能不能兜底"。
    static func extraVariantTags(queryTitle: String, candidateTitle: String) -> Set<String> {
        variantTags(candidateTitle).subtracting(variantTags(queryTitle))
    }

    /// 候选标题自带版本标签（live/伴奏/花絮…）——不管查询是什么
    static func isVariant(_ title: String) -> Bool { !variantTags(title).isEmpty }

    /// 候选标题里出现了「原查询没有」的版本标签 → 返回应扣的分（0 或 35）。
    ///
    /// 查询自己就带版本标签时不扣（用户搜的就是 live）：`晴天 (Live)` 配 `晴天 (Live)` /
    /// `晴天 现场版` 都算同一组，避免同义写法互相打架。大小写不敏感，全角括号先归一。
    static func versionPenalty(queryTitle: String, candidateTitle: String) -> Double {
        extraVariantTags(queryTitle: queryTitle, candidateTitle: candidateTitle).isEmpty ? 0 : 35
    }

    // MARK: 综合

    /// 候选总分（**与 LDDC `auto_fetch` 逐字一致**）：标题×0.5 + 歌手×0.5，标题 <30 再 −35，下限 0
    ///
    /// r72：把 r69 加进来的「版本标记 −35」「时长差 −40」两档删了。
    /// 那两档是本项目自造的，LDDC 里没有；它们的副作用是"本来能用的歌被扣到线下 → 整首没词"
    /// （老板反复报的就是这个）。LDDC 的口径是：
    ///   · 版本对不对**靠标题分自己算**（`titleScore` 里 tag 相同有 +30 的加成，
    ///     所以歌名带 live 的歌，带 live 的候选天然得高分——这正是老板要的"歌名带 live 就优先 live 词"）；
    ///   · 时长只管**硬门槛**（差 >4 秒直接不进候选池，见 `durationOK`），不参与打分。
    static func score(title: String, candidateTitle: String,
                      artist: String, candidateArtist: String) -> Double {
        let ts = titleScore(title, candidateTitle)
        let artistTrimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var total = ts
        if !artistTrimmed.isEmpty {
            total = ts * 0.5 + artistScore(artistTrimmed, candidateArtist) * 0.5
        }
        if ts < 30 { total = max(0, total - 35) }
        return total
    }

    /// 及格线（LDDC `auto_fetch` 的 `min_score`）
    static let minScore: Double = 55

    /// 时长容差（LDDC `auto_fetch` 的 4000ms 硬门槛）
    static let durationToleranceSec: Int = 4

    /// 时长硬门槛：两边都已知、且差 >4 秒 → 不是同一份音频（LDDC 会直接丢掉候选）。
    /// 任一边未知时放行——宁可多试一个，也别因为元数据缺失整首没词。
    static func durationOK(targetSec: Int, candidateSec: Int) -> Bool {
        guard targetSec > 0, candidateSec > 0 else { return true }
        return abs(targetSec - candidateSec) <= durationToleranceSec
    }
}
