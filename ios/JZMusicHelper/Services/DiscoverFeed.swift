import Foundation
import Observation

// MARK: - 发现页数据源
//
// 四家平台都没有「歌单/榜单」接口，所以发现页的内容由三条真链路拼出来（与 Android 同口径）：
//   ① 编辑精选：本地预置池（DiscoverCatalog）按日期轮换 20 首，点开才去搜真实音源
//   ② 热门音乐：每天取 6 个种子词 → 四平台并发搜索 → `DiscoverRules.pick` 选 21 首 → 当天缓存
//   ③ 猜你喜欢：从最近播放里抽 3 个歌手 → 搜他们的歌 → 剔掉听过的 → 取 6 首
//
// 这里不造假数据：搜不到就显示失败态 + 重试，绝不写死几首假歌糊住页面。
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

    private(set) var guessSongs: [Song] = []
    private(set) var guessState: LoadState = .idle

    private let defaults = UserDefaults.standard
    private static let hotCacheKey = "discover_hot_cache_v1"
    /// 猜你喜欢的「换一批」轮次（每点一次换一组歌手关键词）
    private(set) var guessRound = 0

    /// 当天序号（UTC 天，与 Android `HomeCache.today` 一致）
    var day: Int { Int(Date().timeIntervalSince1970 / 86_400) }

    private struct HotCache: Codable {
        let day: Int
        let songs: [Song]
    }

    init() {}

    // MARK: 热门音乐

    func loadHotIfNeeded() async {
        if hotState == .loading { return }
        if !hotSongs.isEmpty { return }
        if let cached = cachedHot(), cached.day == day, !cached.songs.isEmpty {
            hotSongs = cached.songs
            hotState = .loaded
            return
        }
        await refreshHot()
    }

    func refreshHot() async {
        hotState = .loading
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

        let picked = DiscoverRules.pick(pool, limit: 21)
        if picked.isEmpty {
            hotState = .failed
            return
        }
        hotSongs = picked
        hotState = .loaded
        saveHot(picked)
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
    }

    func nextGuessRound(recent: [Song]) async {
        guessRound += 1
        await refreshGuess(recent: recent)
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

    private func saveHot(_ songs: [Song]) {
        guard let data = try? JSONEncoder().encode(HotCache(day: day, songs: songs)) else { return }
        defaults.set(data, forKey: Self.hotCacheKey)
    }
}
