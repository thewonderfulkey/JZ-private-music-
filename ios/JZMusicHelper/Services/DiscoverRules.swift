import Foundation

// MARK: - 发现页的判定口径（纯函数）
//
// 与 Android `HotMusic` 同口径，全部是纯函数，CI 的 logic-tests 直接断言：
//   · 每日轮换：`rotate`（编辑精选池按天滑窗取 20 首）
//   · 原版判定：`coreName` / `plainScore`（去括号、去 Live/DJ/翻唱等版本修饰）
//   · 榜单挑选：`pick`（同曲只留 1 首、同歌手 ≤2 首、同歌手不相邻）
//   · 猜你喜欢的关键词：`guessKeywords`（从最近播放里抽歌手）
enum DiscoverRules {

    /// 同一歌手在榜单里最多出现几次（Android 口径：2）
    static let maxPerSinger = 2

    /// "今天"的序号——**按设备本地日历的 0 点**切天，不再用 UTC。
    ///
    /// 为什么必须本地日（老板 11-18 的反馈）：以前用 `timeIntervalSince1970 / 86400`（UTC 日），
    /// 在澳大利亚（UTC+10:30）要到本地上午 ~10:30 才翻页，于是"11-18 白天还显示 11-17 的缓存"。
    /// 换成 `startOfDay` 之后，本地 0 点就是新的一天，热门/猜你喜欢/榜单/歌单都会按新的一天重取。
    static var today: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return Int(start.timeIntervalSince1970 / 86_400)
    }

    /// 热门音乐模块只放 21 首（3 行 × 7 页，与这一轮之前的口径一致——老板要求"保持那个页数"）
    static let hotModuleLimit = 21

    /// 猜你喜欢放 12 首（3 行 × **4 页**）。
    ///
    /// 老板 r85："猜你喜欢页数也增加几页，可以不用像热门音乐那么多"。热门是 7 页（21 首），
    /// 这里给 4 页（12 首）：比原来 2 页多一倍，但明显少于热门，符合"可以不用那么多"。
    static let guessLimit = 12

    /// 猜你喜欢的歌手取样数：4 个歌手 × 每位 15 条，够 `pick` 在"同歌手 ≤2 首"的约束下凑满 12
    static let guessSingerCount = 4

    // MARK: 热门音乐（榜单优先，纯函数便于断言）

    /// 「最近播放」的指纹：前 3 首的 id。同一批输入 → 同一天不必重算猜你喜欢。
    ///
    /// 为什么用 id 而不是整个列表：用户每听一首都会改最近播放，指纹一变就会重算，
    /// 而猜你喜欢只取 3 个歌手——只用前 3 首做指纹，重算频率刚好对上它的输入。
    static func guessSignature(_ recent: [Song]) -> String {
        recent.prefix(3).map(\.id).joined(separator: ",")
    }

    /// 官方榜 100 首里取模块用的 21 首：**保持官方名次顺序**，不重排、不再做原版筛选。
    /// 返回 nil 表示这一批为空（调用方要回落到种子词搜索，而不是显示空页）。
    ///
    /// 为什么单独抽出来：这是"榜单优先 / 搜索兜底"两个数据源的接缝，
    /// 一旦有人在这里顺手调 `pick`（那会重排、会把第 1 名挤下去），断言会立刻红。
    static func hotModuleSongs(_ songs: [Song], limit: Int = hotModuleLimit) -> [Song]? {
        let head = Array(songs.prefix(limit))
        return head.isEmpty ? nil : head
    }

    // MARK: 每日轮换

    /// 从池子里按「天」滑窗取 `take` 首：同一天多次调用结果稳定，跨天自动换一批
    static func rotate<T>(_ pool: [T], day: Int, take: Int) -> [T] {
        guard !pool.isEmpty, take > 0 else { return [] }
        let start = ((day % pool.count) + pool.count) % pool.count
        let n = min(take, pool.count)
        return (0..<n).map { pool[(start + $0) % pool.count] }
    }

    // MARK: 原版判定

    /// 核心歌名：剥掉括号里的版本说明、「歌手-歌名」结构、Live/DJ/翻唱/伴奏等后缀。
    /// 目的是让「夜曲」「夜曲 (Live)」「夜曲 - DJ版」归成同一首，榜单里不重复上榜。
    static func coreName(_ raw: String) -> String {
        var n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "" }

        // ① 去括号内容（中英文括号、方括号、书名号式的【】）
        n = replace(#"[(（\[【][^)）\]】]*[)）\]】]"#, in: n)
        // ② 归一空白
        n = replace(#"\s+"#, in: n, with: " ")
        // ③ 引号里是歌名时取引号内的（「周杰伦"夜曲"hip-pop beat」→ 夜曲）
        if let quoted = firstGroup(#"["'“”‘’「」『』]([^"'“”‘’「」『』]*)[\"'“”‘’「」『』]"#, in: n),
           !quoted.trimmingCharacters(in: .whitespaces).isEmpty {
            n = quoted
        }
        // ④ 去版本修饰后缀（Live / DJ版 / 伴奏 / 翻唱 / remix …）
        let suffixes = "(伴奏|钢琴版|吉他版|翻唱|Cover|Live|现场|Remix|DJ版|DJ|电音|串烧|合唱版|纯音乐|钢琴|混音|重制|beat|hip-hop|hip-pop|instrumental|Rap|说唱|KTV|对唱|合唱|remix)"
        n = replace("(?i)\(suffixes).*$", in: n)
        // ⑤ 清尾部残留连接符（「七里香 - 」→「七里香」）
        n = replace(#"\s*[-—–·]\s*$"#, in: n)
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 歌名的「原版程度」：无修饰、短名优先（同曲多版本择优时用）
    static func plainScore(_ name: String) -> Int {
        let n = name.trimmingCharacters(in: .whitespaces)
        var score = 0
        if n == coreName(n) { score += 100 }
        if !n.contains("(") && !n.contains("（") { score += 30 }
        if !n.contains("-") { score += 10 }
        score -= n.count / 6
        return score
    }

    // MARK: 榜单挑选

    /// 主歌手：多人合唱取第一个（「陈奕迅/华语群星」→「陈奕迅」），用于"同歌手 ≤2 首"
    static func singerKey(_ singer: String) -> String {
        let s = singer.trimmingCharacters(in: .whitespaces)
        let separators: Set<Character> = ["/", "、", "&", "，", ";", "；"]
        let head = String(s.prefix { !separators.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? s : head
    }

    /// 从候选里挑榜单：同曲只留最优原版、同歌手 ≤2 首、同歌手不相邻（第二遍才放宽相邻）
    static func pick(_ candidates: [Song], limit: Int, excluding: Set<String> = []) -> [Song] {
        guard limit > 0 else { return [] }

        var best: [String: Song] = [:]
        var order: [String] = []
        for s in candidates {
            let core = coreName(s.name)
            guard !core.isEmpty else { continue }
            guard !s.singer.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard !excluding.contains(core) else { continue }
            // 只要原版：名字带版本修饰的直接剔（Android 2.0.2 同口径）
            guard s.name.trimmingCharacters(in: .whitespaces) == core else { continue }
            if let prev = best[core] {
                if plainScore(s.name) > plainScore(prev.name) { best[core] = s }
            } else {
                best[core] = s
                order.append(core)
            }
        }

        var picked: [Song] = []
        var used = Set<String>()
        var singerCount: [String: Int] = [:]
        for allowAdjacent in [false, true] {
            for core in order {
                if picked.count >= limit { break }
                guard !used.contains(core), let s = best[core] else { continue }
                let key = singerKey(s.singer)
                if singerCount[key, default: 0] >= maxPerSinger { continue }
                if !allowAdjacent, let last = picked.last, singerKey(last.singer) == key { continue }
                picked.append(s)
                singerCount[key, default: 0] += 1
                used.insert(core)
            }
            if picked.count >= limit { break }
        }
        return picked
    }

    /// 猜你喜欢的关键词：最近播放里出现过的歌手，去重后取前 `limit` 个
    static func guessKeywords(from recent: [Song], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in recent {
            let key = singerKey(s.singer)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(key)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: 正则小工具

    private static func replace(_ pattern: String, in text: String, with template: String = "") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
