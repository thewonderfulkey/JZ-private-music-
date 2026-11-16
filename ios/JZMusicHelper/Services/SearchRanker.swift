import Foundation

// MARK: - 跨平台搜索结果全局排序
//
// 与 Android 版 `SearchRanker.kt`（v2.1.95）同口径，数字一个不改：
//   打分 = 歌名匹配×0.5 + 歌手匹配×0.3 + 专辑匹配×0.2
//   每个维度取所有关键词词元对该字段的最高匹配分
//   词匹配：完全相等 100 / 前缀 60 / 包含 40 / 未命中 0
//   改编标记（翻唱/钢琴/DJ/Live…）命中 → 歌名分 ×0.8
//   专辑维度只在多词查询时参与，且排除「专辑=歌名」的 UGC 伪命中
//   平台位次先验：各平台第 1~4 名 +10 / +6 / +3 / +1
//   同分按平台优先级 QQ → 网易 → 酷我 → 酷狗，再按原始顺序
//
// 唯一与 Android 不同的地方（移植时判定为 Android 侧缺陷，见 docs/ios/IOS-NETWORK.md §3.2）：
//   「标题只是查询串的一部分」这条封顶判断在 Android 里是区分大小写的
//   （`phrase.contains(title)`，而 title 已被 uppercased），用户输小写时永远不生效。
//   这里改成大小写不敏感，行为只在"本来该封顶却没封顶"的情况下变化。
enum SearchRanker {

    private static let platformOrder: [MusicPlatform: Int] = [
        .qq: 0, .netease: 1, .kuwo: 2, .kugou: 3
    ]

    private static let remixMarkers: [String] = [
        "翻唱", "钢琴", "吉他", "伴奏", "纯音乐", "纯乐", "dj", "live", "串烧",
        "深情", "史诗", "女声", "男声", "版本", "改编", "现场", "演唱会",
        "交响", "大提琴", "萨克斯", "片段", "降调", "升调", "remix", "cover",
        "独奏", "变奏", "翻录",
    ]

    /// 全平台合并排序（保持平台内位次先验与原始顺序稳定性）
    static func rank(keyword: String, songs: [Song]) -> [Song] {
        let words = keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return songs }

        // 同平台同 ID 去重（分页/重复返回保护）
        var seen = Set<String>()
        var deduped: [Song] = []
        for s in songs where seen.insert("\(s.platform.rawValue)_\(s.platformID)").inserted {
            deduped.append(s)
        }

        var counters: [MusicPlatform: Int] = [:]
        var scored: [(song: Song, score: Double, index: Int)] = []
        for (i, s) in deduped.enumerated() {
            let platformIdx = counters[s.platform] ?? 0
            counters[s.platform] = platformIdx + 1
            scored.append((s, score(s, words: words) + positionBonus(platformIdx), i))
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let oa = platformOrder[a.song.platform] ?? 9
            let ob = platformOrder[b.song.platform] ?? 9
            if oa != ob { return oa < ob }
            return a.index < b.index
        }
        return scored.map(\.song)
    }

    private static func positionBonus(_ platformIndex: Int) -> Double {
        switch platformIndex {
        case 0: return 10
        case 1: return 6
        case 2: return 3
        case 3: return 1
        default: return 0
        }
    }

    private static func score(_ s: Song, words: [String]) -> Double {
        let title = s.name.uppercased()
        let artist = s.singer.uppercased()
        let album = s.album.uppercased()

        var bestTitle = 0.0
        var bestArtist = 0.0
        var bestAlbum = 0.0
        let albumActive = words.count > 1 && !album.isEmpty && album != title

        for w in words {
            let u = w.uppercased()
            bestTitle = max(bestTitle, match(u, title))
            bestArtist = max(bestArtist, match(u, artist))
            if albumActive {
                bestAlbum = max(bestAlbum, album == u ? 100 : (album.contains(u) ? 40 : 0))
            }
        }

        // 改编/翻唱后缀降权（忽略大小写：Kotlin 侧曾因 "Live"/"live" 漏判）
        if remixMarkers.contains(where: { title.contains($0.uppercased()) }) {
            bestTitle *= 0.8
        }

        // 标题只是查询串的一部分时不许满分（"IVORY" 不该压过 "IVORY TOWER"）
        let phrase = words.joined(separator: " ")
        if !title.isEmpty,
           phrase.count > title.count,
           phrase.uppercased().contains(title) {
            bestTitle = min(bestTitle, 40)
        }

        return bestTitle * 0.5 + bestArtist * 0.3 + bestAlbum * 0.2
    }

    private static func match(_ word: String, _ field: String) -> Double {
        if field == word { return 100 }
        if field.hasPrefix(word) { return 60 }
        if field.contains(word) { return 40 }
        return 0
    }
}
