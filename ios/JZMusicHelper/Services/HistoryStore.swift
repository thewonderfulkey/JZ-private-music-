import Foundation

// MARK: - 历史与偏好存储
/// JSON 文件持久化：搜索历史、下载记录、用户设置。
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published var searchHistory: [SearchHistoryItem] = []
    @Published var recentSongs: [Song] = []

    private let maxSearchHistory = 20

    // MARK: - 文件路径

    private var searchHistoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("search_history.json")
    }

    private var recentSongsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("recent_songs.json")
    }

    private var downloadsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("downloads.json")
    }

    private var settingsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("settings.json")
    }

    // MARK: - 搜索历史

    func recordSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0.keyword == trimmed }
        searchHistory.insert(SearchHistoryItem(keyword: trimmed), at: 0)
        if searchHistory.count > maxSearchHistory {
            searchHistory = Array(searchHistory.prefix(maxSearchHistory))
        }
        saveSearchHistory()
    }

    func recordSong(_ song: Song) {
        recentSongs.removeAll { $0.id == song.id }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > 50 {
            recentSongs = Array(recentSongs.prefix(50))
        }
        saveRecentSongs()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
    }

    // MARK: - 下载记录

    func loadDownloadItems() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: downloadsURL) else { return [] }
        return (try? JSONDecoder().decode([DownloadItem].self, from: data)) ?? []
    }

    func saveDownloadItems(_ items: [DownloadItem]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: downloadsURL)
        }
    }

    // MARK: - 设置

    func saveQuality(_ q: QualityLevel) {
        if let data = try? JSONEncoder().encode(q) {
            try? data.write(to: settingsURL)
        }
    }

    func loadQuality() -> QualityLevel {
        guard let data = try? Data(contentsOf: settingsURL),
              let q = try? JSONDecoder().decode(QualityLevel.self, from: data) else {
            return .high
        }
        return q
    }

    // MARK: - 内部

    private func saveSearchHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) {
            try? data.write(to: searchHistoryURL)
        }
    }

    private func saveRecentSongs() {
        if let data = try? JSONEncoder().encode(recentSongs) {
            try? data.write(to: recentSongsURL)
        }
    }

    /// App 启动时加载
    func loadAll() {
        if let data = try? Data(contentsOf: searchHistoryURL),
           let arr = try? JSONDecoder().decode([SearchHistoryItem].self, from: data) {
            searchHistory = arr
        }
        if let data = try? Data(contentsOf: recentSongsURL),
           let arr = try? JSONDecoder().decode([Song].self, from: data) {
            recentSongs = arr
        }
    }
}
