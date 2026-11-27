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
    /// 上次向酷我核对「榜换没换」的时间与本地日。
    ///
    /// r121（老板："今天都 19 号了，热门音乐还是 11-17 的内容"）：以前是"每次启动只查一次"，
    /// 但 iOS App 可以在后台活好几天——进程不重启就永远不再核对，于是榜单一直停在旧日期。
    /// 现在改成：**最多每 `hotRevalidateIntervalSec` 查一次 + 跨本地日必查 + App 回前台也查一次**。
    private var lastHotRevalidateAt: Date?
    private var lastHotRevalidateDay: Int = -1

    /// 最新单曲：一页 100 首，模块只露前 `DiscoverRules.newSongsModuleLimit` 张卡，
    /// 「查看全部」进整页。「当天只拉一次」的判据是 `newDay`（本地日），不是服务端日期
    /// —— 歌单没有 `pub` 字段，老板要的就是"第二天刷新"。
    private(set) var newReleases: [KuwoPlaylist.Release] = []
    private(set) var newState: LoadState = .idle
    private var newDay: Int = -1


    // MARK: 发现页 2.0：BANNER（网易首页轮播，只留站内可跳的）
    //
    // 为什么落到网易：酷我没有匿名 banner 接口。实测（2026-11-26）网易首页 8 条里
    // 4 条是歌单（targetType 1000，站内可跳）、4 条是演出/外链（3000），
    // 外链在 `BannerRules.usable` 里被过滤掉——**点哪儿都还在 App 里**。
    /// 只存"能用"的那几条（已过滤外链、已过滤空图）
    private(set) var banners: [NeteaseBannerItem] = []
    private(set) var bannerState: LoadState = .idle
    /// 这批 banner 属于哪一天（本地日；跨天要重取，因为运营会换图）
    private var bannerDay: Int = -1
    private static let bannerCacheKey = "discover_banner_cache_v1"

    /// 今天该不该显示 BANNER：有内容就显示（老板 2026-11-27："不希望能关，当作一个新模块"）
    var showsBanner: Bool { BannerRules.shouldShow(count: banners.count) }

    /// 手上有没有"开屏退场就能立刻显示"的内容（缓存已同步读进来）
    ///
    /// 2026-11-27 开屏闸门用：有缓存才值得等开屏（等的时候屏幕上有东西可看）；
    /// 什么都没有（刚装好第一次开）就别等了——等完还是一片骨架，不如让数据先跑。
    var hasPrimedContent: Bool {
        !hotSongs.isEmpty || !newReleases.isEmpty || !banners.isEmpty
    }

    // MARK: 发现页 2.0：网易的两条榜（热门第二行 / 最新单曲的第二条腿）
    //
    // 老板口径：发现页不再单点依赖酷我。这里两条都是网易**官方榜**（匿名可拉、带真实时长）：
    //   · 热歌榜 3778678 → 热门音乐第二行
    //   · 新歌榜 3779629 → 并进"最新单曲"那一排（与酷我每日最新交替）
    // 不放进 init 预载（开屏那一下不要再解码无关内容），等开屏退场后再读缓存/拉网络。
    private(set) var neteaseHot: [Song] = []
    private(set) var neteaseHotState: LoadState = .idle
    private var neteaseHotDay: Int = -1
    private(set) var neteaseNewSongs: [Song] = []
    private(set) var neteaseNewState: LoadState = .idle
    private var neteaseNewDay: Int = -1
    private static let neteaseHotCacheKey = "discover_netease_hot_chart_v1"
    private static let neteaseNewCacheKey = "discover_netease_new_chart_v1"


    private let defaults = UserDefaults.standard
    /// v2：热门从"种子词结果"换成"榜单优先"，旧缓存（v1）必须失效，否则当天还会显示旧的 21 首
    private static let hotCacheKey = "discover_hot_cache_v2"
    /// 猜你喜欢的当天缓存（同一天 + 同一批"最近播放"才复用）

    /// 当天序号（本地日历天，见 `DiscoverRules.today`）
    var day: Int { DiscoverRules.today }

    private struct HotCache: Codable {
        let day: Int
        let songs: [Song]
        let fromChart: Bool
        /// 榜单的 `pub` 日期（老缓存没有这个字段 → 可选类型兼容）
        let chartDate: String?
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
        // BANNER：缓存与"今天关过了"都同步读进来，第一帧就能定下"显示 / 不显示"
        if let cached = cachedBanners() {
            banners = BannerRules.usable(cached.items)
            if !banners.isEmpty { bannerState = .loaded }
        }
    }

    // MARK: 每日一趟（热门 + 最新单曲）

    /// 发现页首屏的"当天数据"：热门音乐 + 最新单曲 **同一趟并发拉**。
    ///
    /// 老板 r96："最新单曲……同样保持加载一次当天不再加载除非第二天刷新，
    /// **和酷我的接口保持同进度**"——两个模块都是酷我接口、都是一天定死的数据，
    /// 所以合成一个入口：一起进加载态、一起靠本地日判缓存、下拉刷新一起重取。
    /// 顺序不保证（谁先回来谁先铺），但状态机是各自的，互不阻塞。
    /// 2026-11-27（老板）：分批用——酷我这一组（热榜/最新单曲/BANNER）单独一段，
    /// 网易三块留到后面再拉，避免开屏刚退场就 9 路并发。
    func loadKuwoDaily() async {
        async let hot: Void = loadHotIfNeeded()
        async let fresh: Void = loadNewSongsIfNeeded()
        async let banner: Void = loadBannersIfNeeded()
        _ = await (hot, fresh, banner)
    }

    /// 网易那一组（热歌榜/新歌/歌单），在酷我之后单独一段
    func loadNeteaseDaily() async {
        async let nHot: Void = loadNeteaseHotIfNeeded()
        async let nNew: Void = loadNeteaseNewIfNeeded()
        async let nPl: Void = loadNeteasePlaylistsIfNeeded()
        _ = await (nHot, nNew, nPl)
    }

    func loadDaily() async {
        async let hot: Void = loadHotIfNeeded()
        async let fresh: Void = loadNewSongsIfNeeded()
        async let banner: Void = loadBannersIfNeeded()
        async let nHot: Void = loadNeteaseHotIfNeeded()
        async let nNew: Void = loadNeteaseNewIfNeeded()
        async let nPl: Void = loadNeteasePlaylistsIfNeeded()
        _ = await (hot, fresh, banner, nHot, nNew, nPl)
    }

    /// 下拉刷新：热门 / 最新单曲 / BANNER / 网易两条榜 / 猜你喜欢 一起重取（都强制，不吃缓存）
    func refreshAll(recent: [Song]) async {
        async let hot: Void = refreshHot()
        async let fresh: Void = refreshNewSongs()
        async let banner: Void = refreshBanners()
        async let nHot: Void = refreshNeteaseHot()
        async let nNew: Void = refreshNeteaseNew()
        async let nPl: Void = refreshNeteasePlaylists()
        _ = await (hot, fresh, banner, nHot, nNew, nPl)
    }

    // MARK: 网易榜（热门第二行 / 最新单曲第二条腿）

    /// 一小段缓存：这条榜属于哪一天 + 歌曲
    private struct ChartCache: Codable {
        let day: Int
        let songs: [Song]
    }

    func loadNeteaseHotIfNeeded() async {
        if neteaseHotState == .loading { return }
        if neteaseHotDay == day, !neteaseHot.isEmpty { return }
        if let cached = cachedChart(Self.neteaseHotCacheKey), !cached.songs.isEmpty {
            neteaseHot = DiscoverLatestRules.hotRow(cached.songs)
            neteaseHotState = .loaded
            if cached.day == day { neteaseHotDay = day; return }
        }
        await refreshNeteaseHot()
    }

    func refreshNeteaseHot() async {
        if neteaseHot.isEmpty { neteaseHotState = .loading }
        if let page = await NeteaseDiscover.playlistDetail(id: DiscoverSourceIDs.neteaseHotChartID) {
            let songs = DiscoverLatestRules.hotRow(page.songs)
            if !songs.isEmpty {
                neteaseHot = songs
                neteaseHotDay = day
                neteaseHotState = .loaded
                saveChart(Self.neteaseHotCacheKey, songs: songs)
                return
            }
        }
        // 拉空不清空已有内容（网易挂了不该让今天的第二行突然消失）
        neteaseHotState = neteaseHot.isEmpty ? .failed : .loaded
    }

    func loadNeteaseNewIfNeeded() async {
        if neteaseNewState == .loading { return }
        if neteaseNewDay == day, !neteaseNewSongs.isEmpty { return }
        if let cached = cachedChart(Self.neteaseNewCacheKey), !cached.songs.isEmpty {
            neteaseNewSongs = cached.songs
            neteaseNewState = .loaded
            if cached.day == day { neteaseNewDay = day; return }
        }
        await refreshNeteaseNew()
    }

    func refreshNeteaseNew() async {
        if neteaseNewSongs.isEmpty { neteaseNewState = .loading }
        if let page = await NeteaseDiscover.playlistDetail(id: DiscoverSourceIDs.neteaseNewChartID) {
            let songs = Array(page.songs.prefix(DiscoverSourceIDs.hotRowLimit))
            if !songs.isEmpty {
                neteaseNewSongs = songs
                neteaseNewDay = day
                neteaseNewState = .loaded
                saveChart(Self.neteaseNewCacheKey, songs: songs)
                return
            }
        }
        neteaseNewState = neteaseNewSongs.isEmpty ? .failed : .loaded
    }

    /// 最新单曲那一排（酷我 + 网易交替合并）
    var latestReleases: [KuwoPlaylist.Release] {
        DiscoverLatestRules.latestRow(kuwo: newReleases, netease: neteaseNewSongs)
    }

    // MARK: 网易歌单（歌单广场的第二条腿）

    private(set) var neteasePlaylists: [NeteasePlaylistBrief] = []
    private(set) var neteasePlaylistState: LoadState = .idle
    private var neteasePlaylistDay: Int = -1
    private static let neteasePlaylistCacheKey = "discover_netease_playlists_v1"

    private struct PlaylistCache: Codable {
        let day: Int
        let items: [NeteasePlaylistBrief]
    }

    func loadNeteasePlaylistsIfNeeded() async {
        if neteasePlaylistState == .loading { return }
        if neteasePlaylistDay == day, !neteasePlaylists.isEmpty { return }
        if let cached = cachedPlaylists(), !cached.items.isEmpty {
            neteasePlaylists = cached.items
            neteasePlaylistState = .loaded
            if cached.day == day { neteasePlaylistDay = day; return }
        }
        await refreshNeteasePlaylists()
    }

    func refreshNeteasePlaylists() async {
        if neteasePlaylists.isEmpty { neteasePlaylistState = .loading }
        let items = await NeteaseDiscover.playlists(limit: 30)
        guard !items.isEmpty else {
            // 2026-11-27（老板）：失败要留证据——以前只把状态改成 .failed，
            // 界面上那行直接消失，看起来像"我们没接网易"。现在把原因记进播放诊断。
            neteasePlaylistFailure = "接口返回空（/api/playlist/list 200 但解析出 0 条，或超时）"
            neteasePlaylistState = neteasePlaylists.isEmpty ? .failed : .loaded
            PlaybackTrace.shared.log("网易歌单", "取数失败：" + (neteasePlaylistFailure ?? "—"))
            return
        }
        neteasePlaylists = items
        neteasePlaylistFailure = nil
        neteasePlaylistDay = day
        neteasePlaylistState = .loaded
        if let data = try? JSONEncoder().encode(PlaylistCache(day: day, items: items)) {
            defaults.set(data, forKey: Self.neteasePlaylistCacheKey)
        }
    }

    /// 最近一次「网易歌单」取数失败的原因（成功时清空）；供界面提示与播放诊断使用
    private(set) var neteasePlaylistFailure: String?

    /// 用户点「重试」：强制再拉一次（不等当天缓存）
    func retryNeteasePlaylists() async {
        neteasePlaylistFailure = nil
        neteasePlaylistDay = -1
        await refreshNeteasePlaylists()
    }

    private func cachedPlaylists() -> PlaylistCache? {
        guard let data = defaults.data(forKey: Self.neteasePlaylistCacheKey) else { return nil }
        return try? JSONDecoder().decode(PlaylistCache.self, from: data)
    }

    private func cachedChart(_ key: String) -> ChartCache? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ChartCache.self, from: data)
    }

    private func saveChart(_ key: String, songs: [Song]) {
        guard let data = try? JSONEncoder().encode(ChartCache(day: day, songs: songs)) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: BANNER

    private struct BannerCache: Codable {
        let day: Int
        let items: [NeteaseBannerItem]
    }

    func loadBannersIfNeeded() async {
        if bannerState == .loading { return }
        if bannerDay == day, !banners.isEmpty { return }
        if let cached = cachedBanners() {
            let usable = BannerRules.usable(cached.items)
            if !usable.isEmpty {
                // 有缓存就先铺（哪怕是昨天的）：第一帧就有图，不闪骨架
                banners = usable
                bannerState = .loaded
                if cached.day == day {
                    bannerDay = day
                    return
                }
            }
        }
        await refreshBanners()
    }

    func refreshBanners() async {
        if banners.isEmpty { bannerState = .loading }
        let items = BannerRules.usable(await NeteaseDiscover.banners())
        guard !items.isEmpty else {
            // 拉空不清空已有内容（网易挂了不该让今天的 banner 突然消失）
            bannerState = banners.isEmpty ? .failed : .loaded
            return
        }
        banners = items
        bannerDay = day
        bannerState = .loaded
        saveBanners(items)
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

    /// 按服务端的换榜日期核对（探测请求 rn=1 仅约 1.5 KB）。
    ///
    /// 榜单没换（`pub` 与本地记录一致）→ **一个整页请求都不发**；
    /// 换了 → 重取 100 首（`refreshHot` 会顺带写回新的 `chartDate`）。
    ///
    /// 节流口径（r121）：跨本地日必查；同一天内最多每 `DiscoverRules.hotRevalidateIntervalSec` 查一次。
    /// 不再"每个进程只查一次"——App 在后台挂两天也不会自己发现换榜。
    private func revalidateHotIfNeeded() async {
        guard hotFromChart else { return }
        let now = Date()
        guard DiscoverRules.needsHotRevalidate(lastCheckAt: lastHotRevalidateAt,
                                              lastCheckDay: lastHotRevalidateDay,
                                              today: day, now: now) else { return }
        lastHotRevalidateAt = now
        lastHotRevalidateDay = day
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

        // ①.5 拉失败但手上本来就有一份**榜单**内容：保留它，别用种子词把它换掉。
        // 网络抖一下就把"昨天的真榜"换成"兜底混排"，看起来就像"榜单没更新/乱了一下"（r121）
        if hotFromChart, !hotSongs.isEmpty {
            hotState = .loaded
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

    private func cachedBanners() -> BannerCache? {
        guard let data = defaults.data(forKey: Self.bannerCacheKey) else { return nil }
        return try? JSONDecoder().decode(BannerCache.self, from: data)
    }

    private func saveBanners(_ items: [NeteaseBannerItem]) {
        let cache = BannerCache(day: day, items: items)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.bannerCacheKey)
    }
}
