import Foundation
import Observation

// MARK: - 歌单广场数据源
//
// 两个列表：
//   · 热门（order=hot，1754 张）——发现页模块与广场页的默认 tab 都用它；
//   · 最新（order=new，9086 张）——广场页「最新」tab。
//
// 缓存策略（老板要的"加载一次，当天不再加载"）：
//   · 第一页按**本地日**落盘（`KuwoPlaylist.cachedSquare`），当天再进一个请求都不发；
//   · 第 2 页起只在内存，退出页面不保留；
//   · 刷新锚点跟热门音乐同一趟（本地日），另外有一个 `rn=1` 探测判断"当天有没有新歌单上架"，
//     变了才重取第一页——见 `probeNewestIfNeeded`。
@MainActor
@Observable
final class SquareFeed {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var hot: [KuwoPlaylist.Summary] = []
    private(set) var latest: [KuwoPlaylist.Summary] = []
    private(set) var hotTotal = 0
    private(set) var latestTotal = 0
    private(set) var hotState: LoadState = .idle
    private(set) var latestState: LoadState = .idle
    private(set) var loadingMoreHot = false
    private(set) var loadingMoreLatest = false

    private var hotPage = 1
    private var latestPage = 1
    private var hotDay = -1
    private var latestDay = -1
    /// 探测节流：同一个 App 会话里最多每 30 分钟问一次"最新歌单 id"
    private var lastProbeAt: Date?

    var hotHasMore: Bool { hot.count < hotTotal }
    var latestHasMore: Bool { latest.count < latestTotal }

    init() {
        // 跨天冷启动也先把旧内容铺上（不闪骨架），再由 `loadIfNeeded` 决定要不要换
        if let page = KuwoPlaylist.cachedSquareAnyDay(.hot) {
            hot = page.items
            hotTotal = page.total
            hotState = .loaded
        }
        if let page = KuwoPlaylist.cachedSquareAnyDay(.new) {
            latest = page.items
            latestTotal = page.total
            latestState = .loaded
        }
    }

    // MARK: 发现页模块（只要热门第一页）

    func loadIfNeeded() async {
        if hotState == .loading { return }
        if hotDay == DiscoverRules.today, !hot.isEmpty { return }
        if let page = KuwoPlaylist.cachedSquare(.hot) {
            adopt(page, sort: .hot)
            hotDay = DiscoverRules.today
            return
        }
        await refresh(.hot)
    }

    // MARK: 广场页

    func loadLatestIfNeeded() async {
        if latestState == .loading { return }
        if latestDay == DiscoverRules.today, !latest.isEmpty { return }
        if let page = KuwoPlaylist.cachedSquare(.new) {
            adopt(page, sort: .new)
            latestDay = DiscoverRules.today
            return
        }
        await refresh(.new)
    }

    func refreshAll() async {
        async let hotTask: Void = refresh(.hot)
        async let newTask: Void = refresh(.new)
        _ = await (hotTask, newTask)
    }

    func refresh(_ sort: KuwoPlaylist.Sort) async {
        switch sort {
        case .hot:
            if hot.isEmpty { hotState = .loading }
            do {
                let page = try await KuwoPlaylist.fetchSquare(sort: .hot)
                adopt(page, sort: .hot)
                hotDay = DiscoverRules.today
            } catch {
                hotState = hot.isEmpty ? .failed : .loaded
            }
        case .new:
            if latest.isEmpty { latestState = .loading }
            do {
                let page = try await KuwoPlaylist.fetchSquare(sort: .new)
                adopt(page, sort: .new)
                latestDay = DiscoverRules.today
            } catch {
                latestState = latest.isEmpty ? .failed : .loaded
            }
        }
    }

    func loadMore(_ sort: KuwoPlaylist.Sort) async {
        switch sort {
        case .hot:
            guard !loadingMoreHot, hotHasMore else { return }
            loadingMoreHot = true
            defer { loadingMoreHot = false }
            let next = hotPage + 1
            if let page = try? await KuwoPlaylist.fetchSquare(sort: .hot, page: next) {
                hot = merged(hot, page.items)
                hotTotal = page.total
                hotPage = next
            }
        case .new:
            guard !loadingMoreLatest, latestHasMore else { return }
            loadingMoreLatest = true
            defer { loadingMoreLatest = false }
            let next = latestPage + 1
            if let page = try? await KuwoPlaylist.fetchSquare(sort: .new, page: next) {
                latest = merged(latest, page.items)
                latestTotal = page.total
                latestPage = next
            }
        }
    }

    // MARK: "当天有没有新歌单上架"（老板：新上架的立刻能看到）

    /// `rn=1` 问一次最新歌单首条 id（约 1KB）：
    ///   · 与上次记录不同 → 说明有新的上架，重取热门 + 最新第一页；
    ///   · 相同 → 什么都不做（一个整页都不重取）。
    /// 节流 30 分钟，避免回前台就发请求；跨天第一次一定问。
    func probeNewestIfNeeded() async {
        if let last = lastProbeAt, Date().timeIntervalSince(last) < 1800 { return }
        lastProbeAt = Date()

        guard let newest = await KuwoPlaylist.latestNewPlaylistID() else { return }
        let stored = KuwoPlaylist.storedNewestID()
        KuwoPlaylist.storeNewestID(newest)
        // 第一次（没有记录）只记下来，不重取——这一刻本来就在取第一页
        guard let stored, stored != newest else { return }
        await refreshAll()
    }

    // MARK: 内部

    private func adopt(_ page: KuwoPlaylist.SquarePage, sort: KuwoPlaylist.Sort) {
        switch sort {
        case .hot:
            hot = page.items
            hotTotal = page.total
            hotPage = 1
            hotState = .loaded
        case .new:
            latest = page.items
            latestTotal = page.total
            latestPage = 1
            latestState = .loaded
        }
    }

    /// 翻页合并：按 id 去重，接口偶尔会在页与页之间重复塞同一条
    private func merged(_ old: [KuwoPlaylist.Summary], _ new: [KuwoPlaylist.Summary]) -> [KuwoPlaylist.Summary] {
        var seen = Set(old.map(\.id))
        var out = old
        for item in new where seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }
}
