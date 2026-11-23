import Foundation

// MARK: - 「正在播放这一首在这张列表里排第几」的判定口径
//
// 老板 2026-11-20（第四十四轮）：歌单越存越多以后，"当前播的这首在列表哪个位置"要靠自己滑很久。
// 列表页因此各加一个「定位」按钮：点一下滚到那一行并闪一下。
//
// 为什么不直接比 `Song.id`：`id` = 平台 + 平台内 id，只会出现在"当初按这份数据起播"的那张列表里。
// 比如在收藏里点播了网易版《晴天》，回榜单页（酷我 rid）就比不上——但那确实是他正在听的那首歌。
// 所以两步：
//   ① 先按 `id` 精确命中（同一条数据，零歧义，必中第一处）；
//   ② 再按"同一条录音"跨平台认一次：版本类一致 + 歌名归一化相近 + 歌手有交集 + 时长 ≤4s。
//
// 第②步为什么**不**直接用 `NameMatch.sameRecording`：那套口径是给"搜索/换源"用的——
// 候选集已经被歌名约束过，所以它允许「歌手 + 时长对上、歌名不同」（译名场景）。
// 放在一张完整列表上就危险了：同一位歌手两首歌时长相近（《晴天》269s / 《七里香》270s），
// 会被判成同一首、定位到隔壁那行。所以这里多一道 `titleMatches`（歌名必须归一化相近），
// 版本类改成**双向相等**（原唱 ↔ Live 是两条录音，谁也不能定位到谁）。
enum ListLocate {

    /// 在当前列表里找"正在播放的这一首"。
    /// - Parameters:
    ///   - current: `PlayerEngine.currentSong`（没在播放就传 nil）
    ///   - songs: 列表里按显示顺序排的歌
    /// - Returns: 命中的行下标；没在播放 / 空列表 / 不在此列表都返回 nil
    static func index(of current: Song?, in songs: [Song]) -> Int? {
        guard let current, !songs.isEmpty else { return nil }

        // ① 同一条数据：重复出现时取第一处（列表里同一首出现两遍时，用户想看到的是上面那条）
        if let exact = songs.firstIndex(where: { $0.id == current.id }) {
            return exact
        }

        // ② 跨平台同一条录音
        return songs.firstIndex(where: { sameRecording(current, $0) })
    }

    /// 跨平台认"同一条录音"（比 `NameMatch.sameRecording` 更严，只服务于"定位"这个动作）
    static func sameRecording(_ a: Song, _ b: Song) -> Bool {
        guard a.id != b.id else { return false }
        // 版本类必须一致：原唱 / Live / 伴奏 / 翻唱 之间互不定位
        guard NameMatch.versionClass(a.name) == NameMatch.versionClass(b.name) else { return false }
        // 歌名必须归一化相近：防止"同歌手 + 时长碰巧相近"的另一首歌被误认
        guard NameMatch.titleMatches(a.name, b.name) else { return false }
        // 歌手要有交集（任一方没写歌手时这条不拦，与 NameMatch 同口径）
        guard NameMatch.singerMatches(a.singer, b.singer) else { return false }
        // 两边都有时长才卡 4s；缺时长时上面三条已经够严
        if a.durationSec > 0, b.durationSec > 0 {
            return abs(a.durationSec - b.durationSec) <= NameMatch.maxDurationDiffSec
        }
        return true
    }

    /// 把**同一份显示顺序**的下载条目一次拆成 `songs` + `rowIDs` —— 两者同源、同序、同长。
    ///
    /// 为什么必须走这一个口子（2026-11-23 真机："点定位确实切回全部了，但没滚过去"）：
    /// 调用点当时传的是 `songs: downloads.completedSongs`（全库 + **落库顺序**，老→新）
    /// 配 `rowIDs: finished.map(\.id)`（**显示顺序**，新→老，而且已按歌手筛选）。
    /// `index(of:in:)` 是在 `songs` 里算下标的，再拿这个下标去 `rowIDs` 取行 id：
    ///   · 顺序相反 → 滚到**镜像那一行**（v2.4.73 把列表改成"新的在最上面"之后一直如此）；
    ///   · 筛了歌手 → 两个数组长度都不一样，越界后连滚动都不发（静默没反应）。
    /// 现在两列只从这一个函数产出，调用点想传错都没有别的写法。
    static func pair(_ items: [DownloadItem]) -> (songs: [Song], rowIDs: [UUID]) {
        (items.map(\.song), items.map(\.id))
    }
}
