import Foundation

// MARK: - 解析事件
/// 取流解析过程中推送给 UI 的事件（先返回先显示）。
enum ResolveEvent {
    case started(StreamSourceAdapter)
    case success(StreamSource)
    case failed(String, String)   // 后端名, 错误
    case finished
}

// MARK: - 取流解析器
/// 对一首歌并发尝试所有可用后端：全部成功结果都返回，失败/超时自动忽略。
final class URLResolver {

    static let shared = URLResolver()

    /// 单后端超时
    private let perBackendTimeout: TimeInterval = 12

    private init() {}

    /// 并发解析，流式返回事件。
    func resolve(song: Song, quality: QualityLevel) -> AsyncStream<ResolveEvent> {
        AsyncStream { continuation in
            let adapters = SourceRegistry.adapters(for: song)
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for adapter in adapters {
                        group.addTask {
                            continuation.yield(.started(adapter))
                            do {
                                let source = try await self.runWithTimeout {
                                    try await adapter.resolve(song: song, quality: quality)
                                }
                                continuation.yield(.success(source))
                            } catch {
                                continuation.yield(.failed(adapter.name, error.localizedDescription))
                            }
                        }
                    }
                    await group.waitForAll()
                    continuation.yield(.finished)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 等待全部后端结束，返回所有成功流地址（失败忽略）。
    func resolveAll(song: Song, quality: QualityLevel) async -> [StreamSource] {
        var sources: [StreamSource] = []
        await withTaskGroup(of: StreamSource?.self) { group in
            for adapter in SourceRegistry.adapters(for: song) {
                group.addTask {
                    do {
                        return try await self.runWithTimeout {
                            try await adapter.resolve(song: song, quality: quality)
                        }
                    } catch {
                        return nil
                    }
                }
            }
            for await s in group {
                if let s { sources.append(s) }
            }
        }
        return sources
    }

    private func runWithTimeout<T>(_ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(self.perBackendTimeout))
                throw APIError.httpStatus(-1)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
