import Foundation

// MARK: - 发现页多源合并规则（2026-11-26）
//
// 老板口径：「酷我和网易的都能直接用」——两家内容都出现（并列/交替），不是主备切换；
// 一家挂了只少它那部分。这里只放**纯逻辑**，UI 与网络都不进来，方便 CI 断言。

/// 发现页的内容来源
enum DiscoverSource: String, CaseIterable, Sendable {
    case kuwo
    case netease
    case kugou

    var title: String {
        switch self {
        case .kuwo: return "酷我"
        case .netease: return "网易"
        case .kugou: return "酷狗"
        }
    }
}

enum DiscoverMergeRules {

    /// 去重键：歌名归一化 + 歌手 token（排序）+ **版本类**。
    ///
    /// 版本类必须进 key：同一首《晴天》的原唱与 `(Live)` 是两条内容，
    /// 合成一条会让用户点了 Live 却放出录音室版（或反过来）。
    static func dedupeKey(_ song: Song) -> String {
        let title = NameMatch.normTitle(song.name)
        let singers = NameMatch.singerTokens(song.singer).sorted().joined(separator: "+")
        let ver = NameMatch.versionClass(song.name).sorted().joined(separator: "+")
        return "\(title)|\(singers)|\(ver)"
    }

    /// 交替合并：A1,B1,A2,B2…；跨源重复只留**先出现**的那条。
    ///
    /// 为什么交替而不是"先排完 A 再排 B"：两个源各自是按热度排的，
    /// 拼接会让第二家永远沉底（用户看到的还是"一家的内容"）。
    static func merge(_ groups: [(DiscoverSource, [Song])]) -> [Song] {
        guard !groups.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Song] = []
        let lists = groups.map { $0.1 }
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                let song = list[index]
                if seen.insert(dedupeKey(song)).inserted {
                    out.append(song)
                }
            }
        }
        return out
    }

    /// 板块有没有内容可显示（0 条就整块不渲染，不留空壳）
    static func isVisible(_ items: [Song]) -> Bool { !items.isEmpty }
}
