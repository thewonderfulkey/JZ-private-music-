import Foundation

// MARK: - 搜索事件
/// 搜索过程中推送给 UI 的事件。
enum SearchEvent {
    /// 某个平台开始搜索
    case started(MusicPlatform)
    /// 某个平台返回结果（先到先显示）
    case results(MusicPlatform, [Song])
    /// 某个平台失败（超时/错误，自动忽略）
    case failed(MusicPlatform, String)
    /// 全部平台完成
    case finished
}

// MARK: - 搜索服务
/// 并发搜索所有平台：提前返回的提前显示，未返回的继续搜索直到超时或错误自动忽略。
final class SearchService {

    static let shared = SearchService()

    /// 启用搜索的平台（App 内置全部 4 个平台）
    private let adapters: [SearchAdapter] = [
        QQSearchAdapter(),
        NeteaseSearchAdapter(),
        KuwoSearchAdapter(),
        KugouSearchAdapter()
    ]

    /// 单平台搜索超时
    private let perSourceTimeout: TimeInterval = 10

    private init() {}

    /// 并发搜索，通过 AsyncStream 流式推送事件。
    func search(keyword: String, limit: Int = 20) -> AsyncStream<SearchEvent> {
        AsyncStream { continuation in
            let searchTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    for adapter in self.adapters {
                        group.addTask {
                            continuation.yield(.started(adapter.platform))
                            do {
                                let songs = try await self.runWithTimeout {
                                    try await adapter.search(keyword: keyword, limit: limit)
                                }
                                continuation.yield(.results(adapter.platform, songs))
                            } catch {
                                continuation.yield(.failed(adapter.platform, error.localizedDescription))
                            }
                        }
                    }
                    await group.waitForAll()
                    continuation.yield(.finished)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                searchTask.cancel()
            }
        }
    }

    /// 带超时的异步包装：超时抛出 -1 错误（调用方视为该平台失败，自动忽略）。
    private func runWithTimeout<T>(_ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(self.perSourceTimeout))
                throw APIError.httpStatus(-1)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - 完整搜索（等待全部平台结束，返回合并结果）
    /// 供需要一次性拿到全部结果的场景使用。
    func searchAll(keyword: String, limit: Int = 20) async -> [Song] {
        var all: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for adapter in adapters {
                group.addTask {
                    do {
                        return try await self.runWithTimeout {
                            try await adapter.search(keyword: keyword, limit: limit)
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await songs in group {
                all.append(contentsOf: songs)
            }
        }
        return all
    }
}
