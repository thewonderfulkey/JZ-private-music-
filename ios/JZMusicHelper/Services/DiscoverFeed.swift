import Foundation
import Observation

// MARK: - 发现页数据源
//
// 发现页的内容由三条真链路拼出来（与 Android 同口径）：
//   ① 编辑精选：本地预置池（DiscoverCatalog）按日期轮换 20 首，点开才去搜真实音源
//   ② 热门音乐：**首选酷我官方热歌榜**（`KuwoChart`，真榜、每日更新），拿不到才回落到
//      原来的「6 个种子词 → 四平台并发搜索 → `DiscoverRules.pick` 选 21 首」
//   ③ 猜你喜欢：从最近播放里抽 3 个歌手 → 搜他们的歌 → 剔掉听过的 → 取 6 首
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

    private(set) var guessSongs: [Song] = []
    private(set) var guessState: LoadState = .idle

    private let defaults = UserDefaults.standard
    /// v2：热门从"种子词结果"换成"榜单优先"，旧缓存（v1）必须失效，否则当天还会显示旧的 21 首
    private static let hotCacheKey = "discover_hot_cache_v2"
    /// 猜你喜欢的当天缓存（同一天 + 同一批"最近播放"才复用）
    private static let guessCacheKey = "discover_guess_cache_v1"
    /// 猜你喜欢的「换一批」轮次（每点一次换一组歌手关键词）
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
    private static let shownKey = "discover_shown_days_v1"
    private var shownDays: [String: Int] = [:]

    init() {
        shownDays = defaults.dictionary(forKey: Self.shownKey) as? [String: Int] ?? [:]
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

    // MARK: 编辑精选：把当天没写死的那几首后台补齐
    //
    // 包内写死了 102/120 首；剩下十几首（多为 Live/KTV/纯音乐 版被过滤掉的、或搜索里确实没有原版的）
    // 如果等用户点进歌单页再解析，那几行还是会"先文字后变歌"。这里在**发现页加载完之后**
    // 后台把它们补齐并写进 `ResolvedSongCache`，用户真正进歌单时基本都是现成的。
    private(set) var prefetchingEditor = false

    func prefetchEditorSeeds() async {
        guard !prefetchingEditor else { return }
        prefetchingEditor = true
        defer { prefetchingEditor = false }

        for playlist in DiscoverCatalog.playlists {
            if Task.isCancelled { return }
            for seed in editorSeeds(for: playlist, rotation: 0) {
                if Task.isCancelled { return }
                if BakedSeedSongs.song(name: seed.name, singer: seed.singer) != nil { continue }
                if ResolvedSongCache.shared.song(name: seed.name, singer: seed.singer) != nil { continue }
                if ResolvedSongCache.shared.isKnownUnresolved(
                    name: seed.name, singer: seed.singer, day: day) { continue }
                if let song = await resolve(seed: seed) {
                    ResolvedSongCache.shared.store(song, seedName: seed.name, seedSinger: seed.singer)
                    // 顺手把封面也写进磁盘缓存：老板反馈"封面加载完下次还要再加载"，
                    // 预取时一起拉一遍，进歌单页时封面就是本地 IO 了。
                    _ = await CoverImageCache.shared.image(for: song)
                } else {
                    ResolvedSongCache.shared.markUnresolved(
                        name: seed.name, singer: seed.singer, day: day)
                }
            }
        }
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

    // MARK: 编辑精选：每日这一批（最久没展示的优先）

    /// 当天这批 20 首：按「最久没展示」排，`rotation` 只用来做「换一批」（0 = 今天第一组）
    func editorSeeds(for playlist: DiscoverCatalog.Playlist, rotation: Int = 0) -> [DiscoverCatalog.Seed] {
        DiscoverRules.pickByRecency(
            playlist.seeds,
            key: { Self.seedKey(playlist: playlist.title, seed: $0) },
            lastShown: shownDays,
            day: day,
            take: 20,
            offset: rotation * 20)
    }

    /// 展示过就记下今天（下次优先推别的）——只在 .task 里调，不要在 body 里调（会改状态）
    func markShown(_ seeds: [DiscoverCatalog.Seed], in playlist: DiscoverCatalog.Playlist) {
        var changed = false
        for seed in seeds {
            let key = Self.seedKey(playlist: playlist.title, seed: seed)
            if shownDays[key] != day {
                shownDays[key] = day
                changed = true
            }
        }
        if changed { defaults.set(shownDays, forKey: Self.shownKey) }
    }

    private static func seedKey(playlist: String, seed: DiscoverCatalog.Seed) -> String {
        "\(playlist)|\(seed.name)|\(seed.singer)"
    }

    // MARK: 编辑精选：把「歌名 + 歌手」换成真实 Song

    /// 点歌单里的某一首时调用：先按「歌名 + 歌手」搜，再按身份校验挑最像的那条。
    /// 与播放层一致：叫不出名字的宁可返回 nil（行尾显示失败），也不放错歌。
    func resolve(seed: DiscoverCatalog.Seed) async -> Song? {
        // 预置池里的歌**写死**在包里（`BakedSeedSongs`）：命中就不用搜索，点下去立刻是歌。
        // 这是老板 r85 要的"一步到位"——没有这一层，每次点进去都要先等四平台搜索。
        if let baked = BakedSeedSongs.song(name: seed.name, singer: seed.singer) {
            return baked
        }
        let keyword = "\(seed.name) \(seed.singer)".trimmingCharacters(in: .whitespaces)
        let ranked = await SearchService.shared.searchRanked(keyword: keyword, limit: 12)
        let songs = ranked.songs
        // 歌名+歌手都对得上的候选里，**优先时长正常的录音室原版**：
        // 截图里出现过「丑八怪 00:31」这种 31 秒片段版（播放侧 ±25s 闸门会直接判坏源）。
        let both = songs.filter {
            NameMatch.titleMatches(seed.name, $0.name) && NameMatch.singerMatches(seed.singer, $0.singer)
        }
        if !both.isEmpty {
            let solid = both.filter { $0.durationSec >= 60 }
            return StudioPick.pickBest(solid.isEmpty ? both : solid) ?? both[0]
        }
        if let titleOnly = songs.first(where: { NameMatch.titleMatches(seed.name, $0.name) }) {
            return titleOnly
        }
        // 最后兜底：搜索结果第一首（与 Android「点单曲才搜索播放」同口径）
        return songs.first
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
