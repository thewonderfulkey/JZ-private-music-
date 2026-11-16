import Foundation
import UIKit

// MARK: - 封面内存缓存
//
// 为什么要它：列表滚动时 `AsyncImage` 会把同一张封面反复下载/解码（离开屏幕再回来就重来一次），
// 一屏 20 行滚起来流量和 CPU 都在抖。这里只做**内存缓存**（NSCache，系统管淘汰），
// 不落盘——封面本来就小，落盘要处理清理策略，收益不抵复杂度。
final class CoverImageCache: @unchecked Sendable {

    static let shared = CoverImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 60 * 1024 * 1024   // 60MB，够一屏几百张小图
    }

    /// 只读缓存（同步、不触发下载）
    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 取图：命中直接返回；否则下载一次（同一 URL 并发只下一次）
    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }

        lock.lock()
        if let task = inFlight[url] {
            lock.unlock()
            return await task.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }
            self.store(image, for: url)
            return image
        }
        inFlight[url] = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        inFlight[url] = nil
        lock.unlock()
        return result
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: 64 * 64 * 4)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
