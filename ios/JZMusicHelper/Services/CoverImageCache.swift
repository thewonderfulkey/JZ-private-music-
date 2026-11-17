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

    /// 按**歌曲**取封面（列表行与播放页共用同一条链，r65 老板反馈 ① 就修在这里）：
    ///   1. 已下载 → 下载时一起存的本地封面（无网络也有图）
    ///   2. 歌曲自带的 `picURL`（若没有/已失效，`CoverResolver` 会用「歌名 + 歌手」去 QQ 兜底）
    ///   3. 兜底解析出来的 URL 也加载失败 → 忽略原图，强制再兜底一次
    ///
    /// 旧版播放页只读 `song.picURL`，所以"列表里有封面、进播放页却是空占位"
    /// （网易/酷我大量歌曲 picURL 为空，全靠 CoverResolver 才有图）。
    func image(for song: Song) async -> UIImage? {
        if let path = DownloadManager.shared.localCoverURL(for: song)?.path,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let local = UIImage(data: data) {
            return local
        }

        let resolved = await CoverResolver.shared.coverURL(for: song)
        if let raw = resolved, let url = URL(string: raw), let image = await image(for: url) {
            return image
        }

        let fallback = await CoverResolver.shared.coverURLIgnoringOriginal(for: song)
        if let raw = fallback, let url = URL(string: raw), let image = await image(for: url) {
            return image
        }
        return nil
    }

    func clear() {
        cache.removeAllObjects()
    }
}
