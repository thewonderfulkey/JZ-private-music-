import Foundation
import Observation

// MARK: - 发现页数据源
//
// 发现页的内容由三条真链路拼出来（与 Android 同口径）：
//   ① 编辑精选：本地预置池（DiscoverCatalog）按日期轮换 20 首，点开才去搜真实音源
//   ② 热门音乐：**首选酷我官方热歌榜**（`KuwoChart`，真榜、每日更新），拿不到才回落到
//      原来的「6 个种子词 → 四平台并发搜索 → `DiscoverRules.pick` 选 21 首」
//   ③ 最新单曲：**酷我官方歌单「每日最新单曲推荐」**（`KuwoPlaylist`，1082685104），
//      带封面与发行日；与热门音乐同一趟加载、同一个本地日边界（老板："和酷我的接口保持同进度"）
//   ④ 猜你喜欢：从最近播放里抽 3 个歌手 → 搜他们的歌 → 剔掉听过的 → 取 6 首
//
// 第二十轮（老板："把酷我热歌榜换到热门音乐里，原来的热门音乐逻辑作为兜底，优先用热歌榜，
// 保持热门音乐的样式和页数"）：榜单不再单独占编辑精选的一个卡位，而是成为热门音乐的数据源；
// 「查看全部」进榜单页。兜底链路原样保留——榜单接口挂了，热门音乐还是会有内容。
//
// 这里不造假数据：榜单和搜索都拿不到才显示失败态 + 重试，绝不写死几首假歌糊住页面。
@MainActor
@Observable
final class DiscoverFeed {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var hotSongs: [Song] = []
    private(set) var hotState: LoadState = .idle
    /// 这批热门是"酷我官方榜"还是"四平台合并兜底"——只用来写副标题，不参与排序
    private(set) var hotFromChart = false
    /// 这批热门是哪一天的（兜底数据用：跨本地日要重算）
    private var hotDay: Int = -1
    /// 榜单数据对应的**服务端 `pub` 日期**（这才是"换榜"的信号）
    private var hotChartDate: String?
    /// 每次启动只按服务端日期核对一次，避免每次回发现页都打一次探测请求
    private var didRevalidateHot = false

    /// 最新单曲：一页 100 首，模块只露前 `DiscoverRules.newSongsModuleLimit` 张卡，
    /// 「查看全部」进整页。「当天只拉一次」的判据是 `newDay`（本地日），不是服务端日期
    /// —— 歌单没有 `pub` 字段，老板要的就是"第二天刷新"。
    private(set) var newReleases: [KuwoPlaylist.Release] = []
    private(set) var newState: LoadState = .idle
    private var newDay: Int = -1

    private(set) var guessSongs: [Song] = []
    private(set) var guessState: LoadState = .idle

    private let defaults = UserDefaults.standard
    /// v2：热门从"种子词结果"换成"榜单优先"，旧缓存（v1）必须失效，否则当天还会显示旧的 21 首
    private static let hotCacheKey = "discover_hot_cache_v2"
    /// 猜你喜欢的当天缓存（同一天 + 同一批"最近播放"才复用）
    private static let guessCacheKey = "discover_guess_cache_v1"    /// 猜你喜欢的「换一批」轮次（每点一次换一组歌手关键词）
    private(set) var guessRound = 0

    /// 当天序号（本地日历天，见 `DiscoverRules.today`）
    var day: Int { DiscoverRules.today }

    private struct HotCache: Codable {
        let day: Int
        let songs: [Song]
        let fromChart: Bool
        /// 榜单的 `pub` 日期（老缓存没有这个字段 → 可选类型兼容）
        let chartDate: String?
    }

    private struct GuessCache: Codable {
        let day: Int
        let signature: String
        let songs: [Song]
    }

    /// 编辑精选的「上次展示日」：key = 类别|歌名|歌手 → 天序号（没有 = 从没展示过）

    init() {
        // 第二十一轮（老板 r84："一打开就到处在转圈，能不能加载一次就别再加载"）：
        // 缓存**在 init 里同步读进来**，这样发现页第一帧就有内容，不再先闪一屏骨架屏。
        // 热门/猜你喜欢都是一天定死的数据，同一天再打开直接复用，一个请求都不发。
        primeFromCaches()
    }

    /// 同步预载缓存（只读本地，不发请求）
    ///
    /// 热门不再按"我们这边的哪一天"判断：**只要缓存里有内容就先铺上去**，
    /// 之后再按酷我返回的 `pub` 日期核对要不要换（见 `revalidateHotIfNeeded`）。
    private func primeFromCaches() {
        if let cached = cachedHot(), !cached.songs.isEmpty {
            hotSongs = cached.songs
            hotFromChart = cached.fromChart
            hotDay = cached.day
            hotChartDate = cached.chartDate
            hotState = .loaded
        }
        if let cached = cachedGuess(),
           cached.day == day,
           cached.signature == DiscoverRules.guessSignature(LibraryStore.shared.recentSongs),
           !cached.songs.isEmpty {
            guessSongs = cached.songs
            guessState = .loaded
        }
        // 最新单曲：缓存里只要过了"本地日"就**先铺上去**（哪怕不是今天的），
        // 以免跨天冷启动先闪一屏骨架；`loadNewSongsIfNeeded` 会按 `newDay` 决定要不要重取。
        if let cached = KuwoPlaylist.cachedAnyDay(.newSongs) {
            newReleases = cached
            newState = .loaded
        }
        if let cached = KuwoPlaylist.cached(.newSongs, day: day) {
            newReleases = cached
            newDay = day
            newState = .loaded
        }
    }

    // MARK: 每日一趟（热门 + 最新单曲）

    /// 发现页首屏的"当天数据"：热门音乐 + 最新单曲 **同一趟并发拉**。
    ///
    /// 老板 r96："最新单曲……同样保持加载一次当天不再加载除非第二天刷新，
    /// **和酷我的接口保持同进度**"——两个模块都是酷我接口、都是一天定死的数据，
    /// 所以合成一个入口：一起进加载态、一起靠本地日判缓存、下拉刷新一起重取。
    /// 顺序不保证（谁先回来谁先铺），但状态机是各自的，互不阻塞。
    func loadDaily() async {
        async let hot: Void = loadHotIfNeeded()
        async let fresh: Void = loadNewSongsIfNeeded()
        _ = await (hot, fresh)
    }

    /// 下拉刷新：热门 / 最新单曲 / 猜你喜欢 三块一起重取（都强制，不吃缓存）
    func refreshAll(recent: [Song]) async {
        async let hot: Void = refreshHot()
        async let fresh: Void = refreshNewSongs()
        async let guess: Void = refreshGuess(recent: recent)
        _ = await (hot, fresh, guess)
    }

    // MARK: 最新单曲

    func loadNewSongsIfNeeded() async {
        if newState == .loading { return }
        if newDay == day, !newReleases.isEmpty { return }
        // 缓存已经是今天的（init 里可能刚读过）→ 直接复用，一个请求都不发
        if let cached = KuwoPlaylist.cached(.newSongs, day: day), !cached.isEmpty {
            newReleases = cached
            newDay = day
            newState = .loaded
            return
        }
        await refreshNewSongs()
    }

    /// 真正拉一次（一页 100 首）。失败时**不清空已有内容**：
    /// 刷新失败不该把用户正在看的那排卡片抽走（与热门音乐同一口径）。
    ///
    /// 加载态也只在"手上没有内容"时才亮骨架：昨天那页还在屏幕上时，重取是后台行为，
    /// 不该把整排卡片换成灰块（r84："一打开什么都在加载"的观感就是从这儿来的）。
    func refreshNewSongs() async {
        if newReleases.isEmpty { newState = .loading }
        do {
            let releases = try await KuwoPlaylist.fetch(.newSongs)
            newReleases = releases
            newDay = day
            newState = .loaded
        } catch {
            newState = newReleases.isEmpty ? .failed : .loaded
        }
    }

    // MARK: 热门音乐

    func loadHotIfNeeded() async {
        if hotState == .loading { return }

        if !hotSongs.isEmpty {
            // 榜单：按**酷我返回的 `pub` 日期**决定要不要换（老板："跟接口一起换"）；
            // 兜底数据（种子词）没有服务端日期，仍按本地日重算。
            await revalidateHotIfNeeded()
            if !hotFromChart, hotDay != day { await refreshHot() }
            return
        }
        if let cached = cachedHot(), !cached.songs.isEmpty {
            hotSongs = cached.songs
            hotFromChart = cached.fromChart
            hotDay = cached.day
            hotChartDate = cached.chartDate
            hotState = .loaded
            await revalidateHotIfNeeded()
            if !hotFromChart, hotDay != day { await refreshHot() }
            return
        }
        await refreshHot()
    }

    /// 按服务端的换榜日期核对一次（每次启动只查一次；探测请求 rn=1 仅约 1.5 KB）。
    ///
    /// 榜单没换（`pub` 与本地记录一致）→ **一个整页请求都不发**；
    /// 换了 → 重取 100 首（`refreshHot` 会顺带写回新的 `chartDate`）。
    private func revalidateHotIfNeeded() async {
        guard !didRevalidateHot else { return }
        didRevalidateHot = true
        guard hotFromChart else { return }
        guard let latest = await KuwoChart.latestPublishedDate(.hot) else { return }
        if latest != hotChartDate {
            await refreshHot()
        }
    }

    func refreshHot() async {
        hotState = .loading

        // ① 首选：酷我官方热歌榜（真榜，100 首/日更，模块只取前 21）
        if let page = try? await KuwoChart.fetchPage(.hot),
           let songs = DiscoverRules.hotModuleSongs(page.songs) {
            hotSongs = songs
            hotFromChart = true
            hotDay = day
            hotChartDate = page.publishedDate
            hotState = .loaded
            saveHot(songs, fromChart: true, chartDate: page.publishedDate)
            return
        }

        // ② 兜底：原来的种子词四平台合并（榜单接口不通时热门音乐也不会空着）
        let words = DiscoverRules.rotate(DiscoverCatalog.hotSeedWords, day: day, take: 6)

        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for word in words {
                group.addTask {
                    let result = await SearchService.shared.searchRanked(keyword: word, limit: 10)
                    return result.songs
                }
            }
            for await songs in group {
                pool.append(contentsOf: songs)
            }
        }

        let picked = DiscoverRules.pick(pool, limit: DiscoverRules.hotModuleLimit)
        if picked.isEmpty {
            hotState = .failed
            return
        }
        hotSongs = picked
        hotFromChart = false
        hotDay = day
        hotChartDate = nil
        hotState = .loaded
        saveHot(picked, fromChart: false, chartDate: nil)
    }

    // MARK: 猜你喜欢

    func refreshGuess(recent: [Song]) async {
        guard !recent.isEmpty else {
            guessSongs = []
            guessState = .loaded
            return
        }
        guessState = .loading

        // 换一批：每点一次整体跳过一组歌手
        let base = DiscoverRules.guessKeywords(from: recent, limit: 12)
        let singers: [String]
        if base.isEmpty {
            singers = []
        } else {
            let count = DiscoverRules.guessSingerCount
            let shift = (guessRound * count) % base.count
            singers = Array(base.dropFirst(shift)).prefix(count).map { $0 }
        }

        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for singer in singers {
                group.addTask {
                    let result = await SearchService.shared.searchRanked(keyword: singer, limit: 15)
                    return result.songs
                }
            }
            for await songs in group {
                pool.append(contentsOf: songs)
            }
        }

        let played = Set(recent.map { DiscoverRules.coreName($0.name) })
        var picked = DiscoverRules.pick(pool, limit: DiscoverRules.guessLimit, excluding: played)
        // 搜索失败的兜底：拿今天的热门里没听过的补位（仍然是真数据，不编造）
        if picked.count < DiscoverRules.guessLimit {
            let fromHot = DiscoverRules.pick(hotSongs, limit: DiscoverRules.guessLimit, excluding: played)
            for song in fromHot where picked.count < DiscoverRules.guessLimit {
                if !picked.contains(where: { $0.id == song.id }) { picked.append(song) }
            }
        }
        guessSongs = picked
        guessState = picked.isEmpty ? .failed : .loaded
        if !picked.isEmpty {
            saveGuess(picked, signature: DiscoverRules.guessSignature(recent))
        }
    }

    /// 打开发现页时调用：缓存已经有内容就**一个请求都不发**；
    /// 只有"最近播放"变了（指纹不同）才在后台悄悄换一批，界面先照旧显示旧的。
    func refreshGuessIfStale(recent: [Song]) async {
        guard !recent.isEmpty else { return }
        // 同一批输入 + **同一天**才算新鲜；跨天必须重算（老板："除非第二天或者点换一批"）
        if guessState == .loaded, !guessSongs.isEmpty,
           let cached = cachedGuess(), cached.day == day,
           cached.signature == DiscoverRules.guessSignature(recent) {
            return
        }
        await refreshGuess(recent: recent)
    }

    func nextGuessRound(recent: [Song]) async {
        guessRound += 1
        await refreshGuess(recent: recent)
    }

    // MARK: 缓存

    private func cachedHot() -> HotCache? {
        guard let data = defaults.data(forKey: Self.hotCacheKey) else { return nil }
        return try? JSONDecoder().decode(HotCache.self, from: data)
    }

    private func saveHot(_ songs: [Song], fromChart: Bool, chartDate: String?) {
        let cache = HotCache(day: day, songs: songs, fromChart: fromChart, chartDate: chartDate)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.hotCacheKey)
    }

    private func cachedGuess() -> GuessCache? {
        guard let data = defaults.data(forKey: Self.guessCacheKey) else { return nil }
        return try? JSONDecoder().decode(GuessCache.self, from: data)
    }

    private func saveGuess(_ songs: [Song], signature: String) {
        let cache = GuessCache(day: day, signature: signature, songs: songs)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.guessCacheKey)
    }
}
