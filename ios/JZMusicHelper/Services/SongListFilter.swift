import Foundation

// MARK: - 歌曲集合页的本地筛选（2026-11-27 老板：歌单/收藏/下载头部统一三件套）
//
// 「播放全部」「随机」「搜索」三件套里的搜索，作用范围是**本页这一批歌**，不打网络。
// 这里只放纯逻辑（CI 断言），UI 在 `ListSearchField`。

enum SongListFilter {

    /// 一条歌命中查询吗
    ///
    /// 命中面刻意比"歌名开始于"宽：歌名 / 歌手 / 专辑 任意一处包含就算。
    /// 归一化走 `NameMatch.identityKey`（繁简、全角、标点都折平），
    /// 所以"晴天"/"晴天 (Live)"/"晴 天"都能被"晴"搜到，繁体也能。
    static func matches(_ song: Song, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let key = NameMatch.identityKey(q)
        guard !key.isEmpty else { return false }
        let fields = [song.name, song.singer, song.album]
        for field in fields where !field.isEmpty {
            if NameMatch.identityKey(field).contains(key) { return true }
        }
        // 英文大小写/空格不敏感的第二道（identityKey 已经 lowercased，这里只兜"多词分开写"）
        let raw = q.lowercased()
        for field in fields where !field.isEmpty {
            if field.lowercased().contains(raw) { return true }
        }
        return false
    }

    /// 过滤一批歌（保持原顺序）
    static func filter(_ songs: [Song], query: String) -> [Song] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return songs }
        return songs.filter { matches($0, query: q) }
    }

    /// 给"歌单条目"这类包装类型做过滤（保持原顺序）
    static func filterItems<T>(_ items: [T], query: String, song: (T) -> Song) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { matches(song($0), query: q) }
    }

    /// 搜索框旁边的计数文案："共 328 首" / "搜到 12 首"
    static func metaText(shown: Int, total: Int, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return "共 \(total) 首" }
        return "搜到 \(shown) / \(total) 首"
    }

    /// 吸顶头部下面那行计数：**只有真的在筛选时才返回文案**（老板 2026-11-27：
    /// 没搜索词时别显示，否则和页面头部的「162 首」重复）
    static func filteredMetaText(shown: Int, total: Int, query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return "共 \(shown) 首（筛选后 · 全部 \(total) 首）"
    }
}
