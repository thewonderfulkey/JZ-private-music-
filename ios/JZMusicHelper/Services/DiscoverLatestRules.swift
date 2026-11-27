import Foundation

// MARK: - 发现页「双源并列」的取数口径（2026-11-27，发现页 2.0 Task 7）
//
// 老板口径（改版目标）：发现页不再"单点依赖酷我"——热门音乐、最新单曲两家内容**都要出现**，
// 一家挂了只少它那部分。这里只放**纯逻辑与常量**（方便 CI 断言），网络在 `NeteaseDiscover`，
// UI 在 `DiscoverView`。

enum DiscoverSourceIDs {

    /// 网易官方榜 id（2026-11-27 实测 `api/toplist` 拿到，65 个榜里挑这两个）
    ///   · 热歌榜 3778678（200 首，每日更新）
    ///   · 新歌榜 3779629（100 首，刚刚更新）
    /// 只认名字匹配会随运营改名漂；钉 id 才稳。
    static let neteaseHotChartID = "3778678"
    static let neteaseNewChartID = "3779629"

    /// 模块里各露几首
    static let hotRowLimit = 21
    static let latestRowLimit = 12
}

enum DiscoverLatestRules {

    /// 最新单曲那一排：酷我「每日最新单曲推荐」+ 网易「新歌榜」交替合并。
    ///
    /// · 交替（A1,B1,A2,B2）——不做"先排完一家再排另一家"，否则第二家永远沉底；
    /// · 跨源同一首只留一条（`DiscoverMergeRules` 的版本类去重）；
    /// · 酷我那边保留原始 `Release`（有发行日可显示），网易那边没有发行日，就留空串。
    static func latestRow(kuwo: [KuwoPlaylist.Release], netease: [Song],
                          limit: Int = DiscoverSourceIDs.latestRowLimit) -> [KuwoPlaylist.Release] {
        guard !kuwo.isEmpty || !netease.isEmpty else { return [] }
        let merged = DiscoverMergeRules.merge([(.kuwo, kuwo.map(\.song)), (.netease, netease)])
        var kuwoByID: [String: KuwoPlaylist.Release] = [:]
        for release in kuwo { kuwoByID[release.id] = release }
        return merged.prefix(max(0, limit)).map { song in
            kuwoByID[song.id] ?? KuwoPlaylist.Release(song: song, releaseDate: "")
        }
    }

    /// 热门音乐的第二行（网易热歌榜）：只取前 N 首，并保证不是空的
    static func hotRow(_ songs: [Song],
                       limit: Int = DiscoverSourceIDs.hotRowLimit) -> [Song] {
        Array(songs.prefix(max(0, limit)))
    }
}
