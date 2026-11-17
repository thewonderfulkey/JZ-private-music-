import Foundation

// MARK: - 搜索事件（供 UI 边搜边显示）
enum SearchEvent {
    case started(MusicPlatform)
    case results(MusicPlatform, [Song])
    case failed(MusicPlatform, String)
    case finished
}

// MARK: - 并发搜索编排
/// 与 Android `SearchService` 同口径：
/// 四个平台并发、每个平台独立 8s 超时；**任何单平台异常都不得外抛**（就地转成该平台失败）。
final class SearchService {

    static let shared = SearchService()

    private let adapters: [SearchAdapter] = SearchAdapters.all

    /// v2.1.9：6s → 8s（酷我慢网/大响应 rn=20≈45KB 更稳）
    let perSourceTimeout: TimeInterval = 8

    private init() {}

    /// 当前真正参与并发搜索的平台（UI 的平台状态行读这里，不写死）
    var platforms: [MusicPlatform] { adapters.map(\.platform) }

    /// 每个平台的搜索结果（保持平台维度）
    struct PlatformResult: Sendable {
        let platform: MusicPlatform
        let songs: [Song]
        let error: String?
        let elapsedMs: Int

        var failed: Bool { error != nil }
    }

    /// 并发搜索全部平台，等所有完成（单平台失败只标 error，绝不抛出）
    func searchAll(keyword: String, limit: Int = 20, page: Int = 1) async -> [PlatformResult] {
        let timeout = perSourceTimeout
        return await withTaskGroup(of: PlatformResult.self) { group in
            for adapter in adapters {
                group.addTask {
                    let started = Date()
                    do {
                        let songs = try await withThrowingTaskGroup(of: [Song].self) { inner -> [Song] in
                            inner.addTask {
                                try await adapter.search(keyword: keyword, limit: limit, page: page)
                            }
                            inner.addTask {
                                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                                throw APIError.timeout
                            }
                            guard let first = try await inner.next() else { throw APIError.timeout }
                            inner.cancelAll()
                            return first
                        }
                        return PlatformResult(
                            platform: adapter.platform, songs: songs, error: nil,
                            elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
                    } catch {
                        let msg = (error as? APIError) == APIError.timeout
                            ? "超时"
                            : (error.localizedDescription.isEmpty ? "失败" : error.localizedDescription)
                        return PlatformResult(
                            platform: adapter.platform, songs: [], error: msg,
                            elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
                    }
                }
            }
            var out: [PlatformResult] = []
            for await r in group { out.append(r) }
            // 固定按 QQ → 网易 → 酷我 → 酷狗 输出，避免 UI 每轮顺序跳
            let order: [MusicPlatform: Int] = [.qq: 0, .netease: 1, .kuwo: 2, .kugou: 3]
            return out.sorted { (order[$0.platform] ?? 9) < (order[$1.platform] ?? 9) }
        }
    }

    /// 合并 + 全局排序 + 跨平台去重（搜索页最终展示的就是这个）
    ///
    /// 去重口径与 Android v2.1.10 一致：**先排序、再按归一化歌名+歌手 distinct**，
    /// 所以同一个（歌名, 歌手）留下的是匹配度最高的那条（平台位次先验也参与在内）。
    /// 被合并掉的其他平台版本不是丢失——点播放时 `SameSongCrossResolver` 仍会跨平台补源。
    func searchRanked(keyword: String, limit: Int = 20, page: Int = 1)
        async -> (songs: [Song], platforms: [PlatformResult]) {
        let results = await searchAll(keyword: keyword, limit: limit, page: page)
        let merged = results.flatMap(\.songs)
        let ranked = SearchRanker.dedupe(SearchRanker.rank(keyword: keyword, songs: merged))
        return (ranked, results)
    }

    /// 流式搜索（边到边显示；UI 用）
    func search(keyword: String, limit: Int = 20, page: Int = 1) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let task = Task {
                for adapter in self.adapters {
                    continuation.yield(.started(adapter.platform))
                }
                let results = await self.searchAll(keyword: keyword, limit: limit, page: page)
                for r in results {
                    if let err = r.error {
                        continuation.yield(.failed(r.platform, err))
                    } else {
                        continuation.yield(.results(r.platform, r.songs))
                    }
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
