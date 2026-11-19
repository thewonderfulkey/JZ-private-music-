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

    private let favoritesURL = LibraryStore.docURL("favorites.json")
    private let recentURL = LibraryStore.docURL("recent_songs.json")
    private let searchURL = LibraryStore.docURL("search_history.json")
    private let recognizeURL = LibraryStore.docURL("recognize_history.json")
    private let favoriteDatesURL = LibraryStore.docURL("favorite_dates.json")
    private let searchDatesURL = LibraryStore.docURL("search_dates.json")

    private init() {
        load()
    }

    // MARK: 收藏

    func isFavorite(_ song: Song) -> Bool {
        favorites.contains { $0.id == song.id }
    }

    @discardableResult
    func toggleFavorite(_ song: Song) -> Bool {
        if let idx = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: idx)
            favoriteDates.removeValue(forKey: song.id)
            save(favorites, to: favoritesURL)
            save(favoriteDates, to: favoriteDatesURL)
            return false
        }
        favorites.insert(song, at: 0)
        favoriteDates[song.id] = Date()
        save(favorites, to: favoritesURL)
        save(favoriteDates, to: favoriteDatesURL)
        return true
    }

    func removeFavorite(_ song: Song) {
        favorites.removeAll { $0.id == song.id }
        favoriteDates.removeValue(forKey: song.id)
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
        backfillMissingDates()
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
