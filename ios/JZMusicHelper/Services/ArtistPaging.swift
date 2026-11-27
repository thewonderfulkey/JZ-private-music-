import Foundation

// MARK: - 歌手页分页规则（2026-11-27）
//
// 老板："周杰伦 1706 首，但只显示几十首……想在底部给一个「显示更多」，加载与上面不重复的歌。"
//
// 接口侧：`artistMusic?artistid=&pn=&rn=` 实测支持翻页，`data.total` 就是总曲目数。
// 这里只放**纯逻辑**（要不要显示按钮 / 进度文案 / 追加去重），方便 CI 断言；
// 网络与 UI 分别在 `KuwoArtist` 和 `ArtistDetailView`。

enum ArtistPaging {

    /// 还有没有更多：已显示的少于总数
    ///
    /// `total <= 0`（接口没给总数）时**也给按钮**——宁可点一次发现没有，也不要因为缺字段
    /// 把 1706 首的歌锁在第一页（这正是本轮要修的现象）。
    static func hasMore(shown: Int, total: Int) -> Bool {
        guard shown > 0 else { return false }
        guard total > 0 else { return true }
        return shown < total
    }

    /// 按钮上的进度文案："已显示 50 / 1706"；没有总数时退回"已显示 50 首"
    static func progressText(shown: Int, total: Int) -> String {
        if total > 0 {
            return "已显示 \(CountFormat.short(shown)) / \(CountFormat.short(total))"
        }
        return "已显示 \(CountFormat.short(shown)) 首"
    }

    /// 追加下一页，**丢掉已经有的**（按平台 id 去重，保留先出现的顺序）
    ///
    /// 为什么不用"整页去重后再拼"：接口翻页时偶尔会把上一页的尾巴又带回来
    /// （尤其按热度排、排名在翻页间会轻微变动），不去重就会出现同一行重复两次。
    static func appendUnique(_ existing: [KuwoPlaylist.Release],
                             adding new: [KuwoPlaylist.Release]) -> [KuwoPlaylist.Release] {
        var seen = Set(existing.map { $0.song.platformID })
        var out = existing
        for item in new where seen.insert(item.song.platformID).inserted {
            out.append(item)
        }
        return out
    }

    /// 这一页是不是"什么都没新增"（用来判断到底了：接口还在给数据但全是旧的）
    static func addedNothing(_ existing: [KuwoPlaylist.Release],
                            adding new: [KuwoPlaylist.Release]) -> Bool {
        Set(new.map { $0.song.platformID })
            .subtracting(Set(existing.map { $0.song.platformID }))
            .isEmpty
    }
}
