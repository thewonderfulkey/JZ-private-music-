import Foundation

// MARK: - 发现页的判定口径（纯函数）
//
// 与 Android `HotMusic` / `EditorPlaylist` 同口径，全部是纯函数，CI 的 logic-tests 直接断言：
//   · 每日轮换：`rotate`（编辑精选池按天滑窗取 20 首）
//   · 原版判定：`coreName` / `plainScore`（去括号、去 Live/DJ/翻唱等版本修饰）
//   · 榜单挑选：`pick`（同曲只留 1 首、同歌手 ≤2 首、同歌手不相邻）
//   · 猜你喜欢的关键词：`guessKeywords`（从最近播放里抽歌手）
enum DiscoverRules {

    /// 同一歌手在榜单里最多出现几次（Android 口径：2）
    static let maxPerSinger = 2

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

    // MARK: 不过重复的每日轮换（简易 DynamicPool）

    /// 按「最久没展示的优先」挑 `take` 个：`lastShown[key]` 是上次展示的天数（没展示过为 -1）。
    /// `offset` 用来做「换一批」——先把池子整体转一格，再按新旧排，换出来的才是不同的一组。
    ///
    /// 为什么不用纯日期滑窗（rotate）：30 首池子按天滑窗，第 8 天开始就会反复推同样那几首；
    /// 按"最久没展示"排能保证一圈之内不重复，把"每日换一批"真的做到了。
    static func pickByRecency<T>(_ pool: [T],
                                 key: (T) -> String,
                                 lastShown: [String: Int],
                                 day: Int,
                                 take: Int,
                                 offset: Int = 0) -> [T] {
        guard !pool.isEmpty, take > 0 else { return [] }
        let shifted = rotate(pool, day: offset, take: pool.count)
        let ordered = shifted.enumerated().sorted { a, b in
            let da = lastShown[key(a.element)] ?? -1
            let db = lastShown[key(b.element)] ?? -1
            if da != db { return da < db }
            return a.offset < b.offset
        }.map { $0.element }
        return Array(ordered.prefix(min(take, ordered.count)))
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
