import Foundation
import Observation

// MARK: - 资料库（收藏 / 最近播放 / 搜索历史 / 识曲历史）
//
// 与 Android 的口径一致（上限一个不改）：收藏无上限、最近播放 50、搜索历史 20、识曲历史 50。
// 存储用 JSON 文件放在 Documents（和旧的 HistoryStore 同一批文件，首次启动会做一次迁移）。
//
// 为什么是 @Observable 而不是 ObservableObject：iOS 17 基线（见 IOS-ROLLOUT §0），
// SwiftUI 直接观察属性访问，不需要 @Published / objectWillChange 那套样板。
@Observable
final class LibraryStore {

    static let shared = LibraryStore()

    private enum Limits {
        static let recent = 50
        static let search = 20
        static let recognize = 50
    }

    private(set) var favorites: [Song] = []
    private(set) var recentSongs: [Song] = []
    private(set) var searchHistory: [String] = []
    private(set) var recognizeHistory: [Song] = []

    /// 收藏时间 / 搜索时间（`Song.id` / 关键词 → 时间）。
    ///
    /// 心动模式的画像要按"多久以前"衰减：收藏 45 天半衰、搜索 10 天半衰。
    /// 单独存一份映射而不是改 `favorites.json` 的结构——旧数组格式不动，升级不丢收藏。
    private(set) var favoriteDates: [String: Date] = [:]
    private(set) var searchDates: [String: Date] = [:]

    /// 文件级指纹（songID → 实测 字节/时长/码率）。后台解析得到，用于「同一个文件」去重。
    private(set) var fingerprints: [String: FavoriteFingerprint] = [:]
    /// 合并产生的别名：保留那条的 id → 被并走的 id（跨平台、或标题不同但文件相同）。
    /// 有了它，两个平台的同一条歌**再搜到都显示已收藏**，不会再被收第二遍。
    private(set) var aliases: [String: [String]] = [:]

    private let favoritesURL = LibraryStore.docURL("favorites.json")
    private let fingerprintsURL = LibraryStore.docURL("favorite_fingerprints.json")
    private let aliasesURL = LibraryStore.docURL("favorite_aliases.json")
    private let recentURL = LibraryStore.docURL("recent_songs.json")
    private let searchURL = LibraryStore.docURL("search_history.json")
    private let recognizeURL = LibraryStore.docURL("recognize_history.json")
    private let favoriteDatesURL = LibraryStore.docURL("favorite_dates.json")
    private let searchDatesURL = LibraryStore.docURL("search_dates.json")

    private init() {
        load()
    }

    // MARK: 收藏
    //
    // 2026-11-21 老板需求：收藏一多就忘了收过同一首，又收一遍；封面不同但**音乐文件是同一条录音**。
    // 所以收藏的身份不是 `Song.id`（= 平台_ID，跨平台同曲天然算多条），而是「同一条录音」——
    // 口径在 `FavoriteRules`（歌名核心 + 歌手 + 时长 ±4s + 版本类完全一致）。
    // 行为：已经有同曲 → 不新增行；交互式再点一次 = 取消收藏（爱心本来就是实的）。
    // 历史里已经存在的重复，`load()` 里做一次自动合并。

    /// 收藏页浮层提示（根视图统一渲染，2.4 秒自动消失）
    private(set) var favoriteNotice: String?

    /// 一次收藏变更的结果（视图可以据此做不同反馈；不关心就忽略）
    enum FavoriteChange: Equatable {
        case added
        case removed
        case merged(into: Song)
    }

    /// 「同曲」判定的缓存：`favorites` 一变就清空（`isFavorite` 每行都会调，不能每次扫全表）
    private var favoriteMatchCache: [String: Bool] = [:]

    private func note(_ text: String) {
        favoriteNotice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if favoriteNotice == text { favoriteNotice = nil }
        }
    }

    func isFavorite(_ song: Song) -> Bool {
        if let hit = favoriteMatchCache[song.id] { return hit }
        var hit = FavoriteRules.duplicateIndex(of: song, in: favorites) != nil
        if !hit {
            // 文件级合并留下的别名：标题不同、但确认是同一个文件的那两首
            hit = favorites.contains { fav in
                fav.id == song.id || (aliases[fav.id]?.contains(song.id) ?? false)
            }
        }
        favoriteMatchCache[song.id] = hit
        return hit
    }

    @discardableResult
    func toggleFavorite(_ song: Song) -> FavoriteChange {
        if let idx = FavoriteRules.duplicateIndex(of: song, in: favorites) {
            let removed = favorites.remove(at: idx)
            favoriteDates.removeValue(forKey: removed.id)
            forgetIdentity(of: removed)
            persistFavorites()
            mergeUndo = nil
            refreshDuplicateGroups()
            return .removed
        }
        return addFavorite(song)
    }

    /// 取消收藏时把它的文件指纹与别名一起清掉 —— 老板的口径：
    /// "除非再次取消收藏再收藏"，否则不该又冒出一条重复。
    private func forgetIdentity(of song: Song) {
        var ids = Set([song.id])
        ids.formUnion(aliases[song.id] ?? [])
        aliases.removeValue(forKey: song.id)
        for id in ids { fingerprints.removeValue(forKey: id) }
        // 别的条目里把它当别名记着，也要摘掉（先收集 key 再改，别边遍历边写字典）
        let affected = aliases.filter { $0.value.contains(song.id) }.map(\.key)
        for canonical in affected {
            aliases[canonical] = aliases[canonical]?.filter { $0 != song.id }
        }
        save(fingerprints, to: fingerprintsURL)
        save(aliases, to: aliasesURL)
    }

    /// 非交互式收藏（批量 / 导入）：已有同曲就合并空字段，**不新增行**
    @discardableResult
    func addFavorite(_ song: Song) -> FavoriteChange {
        if let idx = FavoriteRules.duplicateIndex(of: song, in: favorites) {
            let merged = FavoriteRules.merge(existing: favorites[idx], incoming: song)
            if merged != favorites[idx] {
                favorites[idx] = merged
                persistFavorites()
            }
            note("已在收藏里：《\(favorites[idx].name)》")
            return .merged(into: favorites[idx])
        }
        favorites.insert(song, at: 0)
        favoriteDates[song.id] = Date()
        persistFavorites()
        // 后台补一条文件指纹：有了它，下一次和别的平台同文件时才能合并
        Task { @MainActor in FavoriteDedupeService.shared.captureAfterAdd(song) }
        mergeUndo = nil
        refreshDuplicateGroups()
        return .added
    }

    func removeFavorite(_ song: Song) {
        favorites.removeAll { $0.id == song.id }
        favoriteDates.removeValue(forKey: song.id)
        forgetIdentity(of: song)
        persistFavorites()
        mergeUndo = nil
        refreshDuplicateGroups()
    }

    /// 收藏落盘 + 失效判定缓存（所有改动都走这里，避免漏掉缓存）
    private func persistFavorites() {
        favoriteMatchCache.removeAll()
        save(favorites, to: favoritesURL)
        save(favoriteDates, to: favoriteDatesURL)
    }

    // MARK: 最近播放

    func recordPlayed(_ song: Song) {
        recentSongs.removeAll { $0.id == song.id }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > Limits.recent {
            recentSongs = Array(recentSongs.prefix(Limits.recent))
        }
        save(recentSongs, to: recentURL)
    }

    func clearRecent() {
        recentSongs.removeAll()
        save(recentSongs, to: recentURL)
    }

    // MARK: 搜索历史

    func recordSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > Limits.search {
            searchHistory = Array(searchHistory.prefix(Limits.search))
        }
        searchDates[trimmed] = Date()
        save(searchHistory, to: searchURL)
        save(searchDates, to: searchDatesURL)
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        searchDates.removeAll()
        save(searchHistory, to: searchURL)
        save(searchDates, to: searchDatesURL)
    }

    // MARK: 识曲历史

    func recordRecognized(_ song: Song) {
        recognizeHistory.removeAll { $0.id == song.id }
        recognizeHistory.insert(song, at: 0)
        if recognizeHistory.count > Limits.recognize {
            recognizeHistory = Array(recognizeHistory.prefix(Limits.recognize))
        }
        save(recognizeHistory, to: recognizeURL)
    }

    func clearRecognizeHistory() {
        recognizeHistory.removeAll()
        save(recognizeHistory, to: recognizeURL)
    }

    // MARK: 持久化

    private static func docURL(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(name)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        if let data = try? Data(contentsOf: favoritesURL),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            favorites = list
        }
        if let data = try? Data(contentsOf: recentURL),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            recentSongs = Array(list.prefix(Limits.recent))
        }
        // 旧版 HistoryStore 把搜索历史存成 [SearchHistoryItem]，这里做一次迁移
        if let data = try? Data(contentsOf: searchURL) {
            if let list = try? JSONDecoder().decode([String].self, from: data) {
                searchHistory = Array(list.prefix(Limits.search))
            } else if let items = try? JSONDecoder().decode([SearchHistoryItem].self, from: data) {
                searchHistory = Array(items.map(\.keyword).prefix(Limits.search))
            }
        }
        if let data = try? Data(contentsOf: recognizeURL),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            recognizeHistory = Array(list.prefix(Limits.recognize))
        }
        if let data = try? Data(contentsOf: favoriteDatesURL),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            favoriteDates = map
        }
        if let data = try? Data(contentsOf: searchDatesURL),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            searchDates = map
        }
        if let data = try? Data(contentsOf: fingerprintsURL),
           let map = try? JSONDecoder().decode([String: FavoriteFingerprint].self, from: data) {
            fingerprints = map
        }
        if let data = try? Data(contentsOf: aliasesURL),
           let map = try? JSONDecoder().decode([String: [String]].self, from: data) {
            aliases = map
        }
        if let data = try? Data(contentsOf: dismissedURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            dismissedPairs = Set(list)
        }
        backfillMissingDates()
        dedupeExistingFavorites()
        refreshDuplicateGroups()
    }

    /// 一次性清理历史重复：升级上来的老收藏里，同一首跨平台收过多条（封面不同、录音相同）。
    ///
    /// 为什么放在 load 里而不是等到下次收藏：老板要的是"自动化"，不该让他自己回头翻一遍。
    /// 合并只减行不加行，收藏时间保留最早的那条（心动画像的衰减按"喜欢多久了"算）。
    private func dedupeExistingFavorites() {
        let result = FavoriteRules.dedupe(favorites)
        guard result.merged > 0 else { return }
        favorites = result.songs
        let kept = Set(favorites.map(\.id))
        favoriteDates = favoriteDates.filter { kept.contains($0.key) }
        save(favorites, to: favoritesURL)
        save(favoriteDates, to: favoriteDatesURL)
        note("收藏已自动去重：合并 \(result.merged) 条重复")
    }

    // MARK: 文件级去重（后台）
    //
    // 老板 2026-11-21：添加后由收藏"自己在后台"去重，**最重要的维度是歌曲文件是不是同一个**；
    // 一样就合并、并把封面换成专辑原封面；两首不同平台的歌再次搜索仍然都显示已收藏。

    /// 记一条实测指纹（后台解析得到）。返回是否因此触发了合并。
    @discardableResult
    func recordFingerprint(of song: Song, bytes: Int64, durationSec: Int, kbps: Int64) -> Bool {
        guard FavoriteIdentity.isUsable(bytes: bytes, durationSec: durationSec) else { return false }
        fingerprints[song.id] = FavoriteFingerprint(bytes: bytes, durationSec: durationSec,
                                                    kbps: kbps, capturedAt: Date())
        save(fingerprints, to: fingerprintsURL)
        return mergeByContentFingerprint() > 0
    }

    /// 按"同一个文件"合并。返回合并条数。
    ///
    /// 与元数据级（`FavoriteRules`）互补：这里连"标题完全不同、但文件一模一样"也能合并
    /// （同一段录音被不同平台起了不同名字），前提是指纹过了体积闸门。
    @discardableResult
    func mergeByContentFingerprint() -> Int {
        guard fingerprints.count >= 2, favorites.count >= 2 else { return 0 }
        var kept: [(song: Song, fp: FavoriteFingerprint)] = []
        var survivors: [Song] = []
        var mergedInto: [String] = []
        var merged = 0

        for song in favorites {
            guard let fp = fingerprints[song.id] else { survivors.append(song); continue }
            if let hit = kept.firstIndex(where: { FavoriteIdentity.isSameFile($0.fp, fp) }) {
                let keeper = kept[hit].song
                if let idx = survivors.firstIndex(where: { $0.id == keeper.id }) {
                    survivors[idx] = FavoriteRules.merge(existing: survivors[idx], incoming: song)
                }
                var list = aliases[keeper.id] ?? []
                list.append(song.id)
                list.append(contentsOf: aliases[song.id] ?? [])
                aliases[keeper.id] = Array(Set(list.filter { $0 != keeper.id }))
                aliases.removeValue(forKey: song.id)
                mergedInto.append(keeper.id)
                merged += 1
            } else {
                kept.append((song, fp))
                survivors.append(song)
            }
        }

        guard merged > 0 else { return 0 }
        favorites = survivors
        let alive = Set(favorites.map(\.id)).union(aliases.values.flatMap { $0 })
        fingerprints = fingerprints.filter { alive.contains($0.key) }
        favoriteDates = favoriteDates.filter { alive.contains($0.key) }
        persistFavorites()
        save(fingerprints, to: fingerprintsURL)
        save(aliases, to: aliasesURL)
        note("已合并「同一个文件」的 \(merged) 首重复")
        upgradeCoversToAlbum(ids: Array(Set(mergedInto)))
        return merged
    }

    /// 合并后把封面换成**专辑原封面**（走 `CoverResolver` 的平台链，带验活与坏地址拉黑）；
    /// 拿不到就保留原封面 —— 宁可不换，也不贴错图。
    private func upgradeCoversToAlbum(ids: [String]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            for id in ids {
                guard let idx = favorites.firstIndex(where: { $0.id == id }) else { continue }
                let song = favorites[idx]
                guard let url = await CoverResolver.shared.coverURLIgnoringOriginal(for: song),
                      !url.isEmpty, url != song.picURL else { continue }
                favorites[idx] = Song(platform: song.platform, platformID: song.platformID,
                                      name: song.name, singer: song.singer, album: song.album,
                                      duration: song.duration, picURL: url)
                persistFavorites()
            }
        }
    }

    // MARK: 灰区复核（老板拍板：不主动弹，只在收藏页给一个入口）
    //
    // 机械判不了的才进来：同名同歌手但时长差 4–12s、歌名相似度 0.6–0.75、一边缺时长/歌手。
    // 用户逐组决定「合并」或「不是同一首」；后者写否定缓存，以后同一对不再出现。

    /// 疑似重复的组（每组 2 首）
    private(set) var duplicateGroups: [[Song]] = []
    /// 否定缓存（`FavoriteReview.pairKey`）
    private var dismissedPairs: Set<String> = []
    /// 上一次合并前的快照（撤销用）
    private var mergeUndo: (favorites: [Song], dates: [String: Date],
                            fingerprints: [String: FavoriteFingerprint],
                            aliases: [String: [String]])?
    var canUndoMerge: Bool { mergeUndo != nil }

    private let dismissedURL = LibraryStore.docURL("favorite_review_dismissed.json")

    /// 重算疑似重复组（收藏变了 / 进入收藏页时调；按歌名首字分桶，避免 n² 全量比）
    func refreshDuplicateGroups() {
        guard favorites.count >= 2 else {
            if !duplicateGroups.isEmpty { duplicateGroups = [] }
            return
        }
        var buckets: [Character: [(song: Song, key: String)]] = [:]
        for song in favorites {
            let key = FavoriteRules.titleKey(song.name)
            guard let c = key.first else { continue }
            buckets[c, default: []].append((song, key))
        }
        var groups: [[Song]] = []
        var used = Set<String>()
        for (_, list) in buckets where list.count >= 2 {
            for i in 0..<list.count {
                let a = list[i]
                if used.contains(a.song.id) { continue }
                for j in (i + 1)..<list.count {
                    let b = list[j]
                    if used.contains(b.song.id) { continue }
                    guard FavoriteReview.isGreyPair(a.song, b.song,
                                                    keyA: a.key, keyB: b.key) else { continue }
                    guard !dismissedPairs.contains(FavoriteReview.pairKey(a.song, b.song)) else {
                        continue
                    }
                    used.insert(a.song.id)
                    used.insert(b.song.id)
                    groups.append([a.song, b.song])
                    break
                }
            }
        }
        duplicateGroups = Array(groups.prefix(30))
    }

    /// 「不是同一首」：记住否定，别再来烦
    func dismissAsDifferent(_ a: Song, _ b: Song) {
        dismissedPairs.insert(FavoriteReview.pairKey(a, b))
        save(Array(dismissedPairs), to: dismissedURL)
        refreshDuplicateGroups()
    }

    /// 「合并」：保留**音质更好**的那条（码率 → 体积），另一条记为别名，封面换专辑原图
    @discardableResult
    func mergeGroup(_ group: [Song]) -> Bool {
        guard group.count >= 2 else { return false }
        let a = group[0]
        let b = group[1]
        let keeper = FavoriteReview.preferred(a, b, fingerprints: fingerprints)
        let loser = keeper.id == a.id ? b : a
        guard keeper.id != loser.id else { return false }

        mergeUndo = (favorites, favoriteDates, fingerprints, aliases)

        let merged = FavoriteRules.merge(existing: keeper, incoming: loser)

        var list = aliases[keeper.id] ?? []
        list.append(loser.id)
        list.append(contentsOf: aliases[loser.id] ?? [])
        aliases[keeper.id] = Array(Set(list.filter { $0 != keeper.id }))
        aliases.removeValue(forKey: loser.id)

        if fingerprints[keeper.id] == nil, let fp = fingerprints[loser.id] {
            fingerprints[keeper.id] = fp
        }
        fingerprints.removeValue(forKey: loser.id)

        let earliest = min(favoriteDates[a.id] ?? Date(), favoriteDates[b.id] ?? Date())
        favoriteDates[keeper.id] = earliest
        favoriteDates.removeValue(forKey: loser.id)

        favorites = favorites.compactMap { song in
            if song.id == keeper.id { return merged }
            if song.id == loser.id { return nil }
            return song
        }
        persistFavorites()
        save(fingerprints, to: fingerprintsURL)
        save(aliases, to: aliasesURL)
        upgradeCoversToAlbum(ids: [keeper.id])
        note("已合并，保留音质更好的那条（可撤销）")
        refreshDuplicateGroups()
        return true
    }

    /// 撤销上一次合并（把两条原样放回）
    func undoLastMerge() {
        guard let snap = mergeUndo else { return }
        favorites = snap.favorites
        favoriteDates = snap.dates
        fingerprints = snap.fingerprints
        aliases = snap.aliases
        mergeUndo = nil
        persistFavorites()
        save(fingerprints, to: fingerprintsURL)
        save(aliases, to: aliasesURL)
        favoriteMatchCache.removeAll()
        refreshDuplicateGroups()
        note("已撤销合并")
    }

    /// 老用户升级上来时没有时间戳：按"列表顺序 = 由新到旧"补一个**近似**时间。
    ///
    /// 不补的话这些收藏会被当成"从没收藏过"（画像里等于不存在），
    /// 心动模式的旧爱池会突然变空。每往后一条推 3 天，30 条之后一律按 90 天算。
    private func backfillMissingDates() {
        let now = Date()
        for (index, song) in favorites.enumerated() where favoriteDates[song.id] == nil {
            let days = min(90.0, Double(index) * 3.0)
            favoriteDates[song.id] = now.addingTimeInterval(-days * 86_400)
        }
        for (index, keyword) in searchHistory.enumerated() where searchDates[keyword] == nil {
            let days = min(30.0, Double(index) * 1.5)
            searchDates[keyword] = now.addingTimeInterval(-days * 86_400)
        }
        if !favoriteDates.isEmpty { save(favoriteDates, to: favoriteDatesURL) }
        if !searchDates.isEmpty { save(searchDates, to: searchDatesURL) }
    }
}

// MARK: - 收藏的「后台文件级去重」服务
//
// 老板 2026-11-21：添加后由收藏自己在后台去重；多维度比对，但**最重要的是文件是否同一个**。
//
// 为什么不在收藏那一刻同步跑：要拿"文件指纹"必须解析一次真实流（网络 0.8–2s），
// 同步做会让点爱心卡一下。所以收藏立即生效（元数据级去重已经在那一刻做完），
// 文件级交给这里：一次只解析 1 首、一次上线最多 3 首，绝不并发轰炸免费后端。
@MainActor
final class FavoriteDedupeService {

    static let shared = FavoriteDedupeService()

    /// 每次上线最多补几首指纹（多首也不会卡 UI，但会打后端）
    private let maxPerLaunchPass = 3
    /// 同一个时刻只跑一条链
    private var running = false

    private init() {}

    /// 刚收藏完：立刻给它补一条指纹，并尝试和已有收藏做"同文件"合并
    func captureAfterAdd(_ song: Song) {
        Task { @MainActor in await capture([song], budget: 1) }
    }

    /// 冷启动后补一批历史收藏的指纹（延迟几秒，别和首屏抢网络）
    func scheduleLaunchPass(delaySeconds: Double = 5) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delaySeconds))
            let lib = LibraryStore.shared
            let todo = lib.favorites
                .filter { lib.fingerprints[$0.id] == nil }
                .prefix(maxPerLaunchPass)
            guard !todo.isEmpty else { return }
            await capture(Array(todo), budget: maxPerLaunchPass)
        }
    }

    private func capture(_ songs: [Song], budget: Int) async {
        guard !running else { return }
        running = true
        defer { running = false }

        var done = 0
        for song in songs where done < budget {
            // 期间被取消收藏了就不再浪费请求
            guard LibraryStore.shared.isFavorite(song) else { continue }
            // 只要**本平台**的真源（跨平台会拿到别家的文件，指纹就不是这首歌自己的了）
            guard let cand = await DownloadResolver.firstPlayable(
                song: song, want: .high, deadline: 8) else { continue }
            let src = cand.source
            guard src.totalBytes > 0 else { continue }
            done += 1
            let merged = LibraryStore.shared.recordFingerprint(
                of: song, bytes: src.totalBytes, durationSec: song.durationSec, kbps: src.kbps)
            if merged { break }   // 合并后列表变了，下一次上线再继续
        }
    }
}
