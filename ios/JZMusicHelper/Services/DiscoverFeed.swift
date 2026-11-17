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

    private(set) var guessSongs: [Song] = []
    private(set) var guessState: LoadState = .idle

    private let defaults = UserDefaults.standard
    /// v2：热门从"种子词结果"换成"榜单优先"，旧缓存（v1）必须失效，否则当天还会显示旧的 21 首
    private static let hotCacheKey = "discover_hot_cache_v2"
    /// 猜你喜欢的当天缓存（同一天 + 同一批"最近播放"才复用）
    private static let guessCacheKey = "discover_guess_cache_v1"
    /// 猜你喜欢的「换一批」轮次（每点一次换一组歌手关键词）
    private(set) var guessRound = 0

    /// 当天序号（UTC 天，与 Android `HomeCache.today` 一致）
    var day: Int { Int(Date().timeIntervalSince1970 / 86_400) }

    private struct HotCache: Codable {
        let day: Int
        let songs: [Song]
        let fromChart: Bool
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

    /// 同步预载当天缓存（只读本地，不发请求）
    private func primeFromCaches() {
        if let cached = cachedHot(), cached.day == day, !cached.songs.isEmpty {
            hotSongs = cached.songs
            hotFromChart = cached.fromChart
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
        if !hotSongs.isEmpty { return }
        if let cached = cachedHot(), cached.day == day, !cached.songs.isEmpty {
            hotSongs = cached.songs
            hotFromChart = cached.fromChart
            hotState = .loaded
            return
        }
        await refreshHot()
    }

    func refreshHot() async {
        hotState = .loading

        // ① 首选：酷我官方热歌榜（真榜，100 首/日更，模块只取前 21）
        if let page = try? await KuwoChart.fetchPage(.hot),
           let songs = DiscoverRules.hotModuleSongs(page.songs) {
            hotSongs = songs
            hotFromChart = true
            hotState = .loaded
            saveHot(songs, fromChart: true)
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
        hotState = .loaded
        saveHot(picked, fromChart: false)
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
        let base = DiscoverRules.guessKeywords(from: recent, limit: 9)
        let singers: [String]
        if base.isEmpty {
            singers = []
        } else {
            let shift = (guessRound * 3) % base.count
            singers = Array(base.dropFirst(shift)).prefix(3).map { $0 }
        }

        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for singer in singers {
                group.addTask {
                    let result = await SearchService.shared.searchRanked(keyword: singer, limit: 12)
                    return result.songs
                }
            }
            for await songs in group {
                pool.append(contentsOf: songs)
            }
        }

        let played = Set(recent.map { DiscoverRules.coreName($0.name) })
        var picked = DiscoverRules.pick(pool, limit: 6, excluding: played)
        // 搜索失败的兜底：拿今天的热门里没听过的补位（仍然是真数据，不编造）
        if picked.count < 3 {
            let fromHot = DiscoverRules.pick(hotSongs, limit: 6, excluding: played)
            for song in fromHot where picked.count < 6 {
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
        if guessState == .loaded, !guessSongs.isEmpty,
           cachedGuess()?.signature == DiscoverRules.guessSignature(recent) {
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
        let keyword = "\(seed.name) \(seed.singer)".trimmingCharacters(in: .whitespaces)
        let ranked = await SearchService.shared.searchRanked(keyword: keyword, limit: 12)
        let songs = ranked.songs
        if let both = songs.first(where: {
            NameMatch.titleMatches(seed.name, $0.name) && NameMatch.singerMatches(seed.singer, $0.singer)
        }) {
            return both
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

    private func saveHot(_ songs: [Song], fromChart: Bool) {
        let cache = HotCache(day: day, songs: songs, fromChart: fromChart)
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
