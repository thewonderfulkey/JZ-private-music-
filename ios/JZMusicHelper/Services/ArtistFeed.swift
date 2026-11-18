import Foundation
import Observation

// MARK: - 歌手大全数据源
//
// 一个分类 + 一个字母（空串 = "热门"，不按字母）就是一份列表：
//   · 发现页模块用「全部 / 热门」第一页；
//   · 大全页切分类 / 点字母时调 `select(...)`，第一页按本地日缓存（只缓存"热门"那份）。
//
// 和歌单广场同一套口径：第一页当天只拉一次，翻页只在内存；刷新跟热门那一趟。
@MainActor
@Observable
final class ArtistFeed {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var items: [KuwoArtist.Artist] = []
    private(set) var total = 0
    private(set) var state: LoadState = .idle

    /// 当前筛选：分类 id（0 = 全部）与字母（"" = 热门）
    private(set) var category = 0
    private(set) var prefix = ""

    private var page = 1
    private var day = -1
    private var loadingMore = false

    var hasMore: Bool { items.count < total }

    init() {
        if let cached = KuwoArtist.cachedAnyDay(category: 0) {
            items = cached.items
            total = cached.total
            state = .loaded
        }
    }

    /// 发现页模块：全部 / 热门第一页
    func loadIfNeeded() async {
        if state == .loading { return }
        if day == DiscoverRules.today, !items.isEmpty, category == 0, prefix.isEmpty { return }
        if category == 0, prefix.isEmpty, let cached = KuwoArtist.cached(category: 0) {
            adopt(cached)
            day = DiscoverRules.today
            return
        }
        await load(category: category, prefix: prefix, force: false)
    }

    /// 切换分类 / 字母：清空旧列表再取（不保留旧筛选的内容，避免闪错内容）
    func select(category: Int, prefix: String) async {
        guard category != self.category || prefix != self.prefix else { return }
        self.category = category
        self.prefix = prefix
        items = []
        total = 0
        state = .loading
        page = 1

        // 只有"热门"（无字母）才有当天缓存
        if prefix.isEmpty, let cached = KuwoArtist.cached(category: category) {
            adopt(cached)
            day = DiscoverRules.today
            return
        }
        await load(category: category, prefix: prefix, force: true)
    }

    func refresh() async {
        await load(category: category, prefix: prefix, force: true)
    }

    func loadMore() async {
        guard !loadingMore, hasMore, state == .loaded else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = page + 1
        guard let result = try? await KuwoArtist.fetchDirectory(
            category: category, prefix: prefix, page: next) else { return }
        var seen = Set(items.map(\.id))
        var merged = items
        for artist in result.items where seen.insert(artist.id).inserted {
            merged.append(artist)
        }
        items = merged
        total = result.total
        page = next
    }

    // MARK: 内部

    private func load(category: Int, prefix: String, force: Bool) async {
        if state == .loading, !force { return }
        if items.isEmpty { state = .loading }
        do {
            let result = try await KuwoArtist.fetchDirectory(
                category: category, prefix: prefix, page: 1)
            adopt(result)
            day = DiscoverRules.today
            page = 1
        } catch {
            state = items.isEmpty ? .failed : .loaded
        }
    }

    private func adopt(_ page: KuwoArtist.Page) {
        items = page.items
        total = page.total
        state = .loaded
    }
}
