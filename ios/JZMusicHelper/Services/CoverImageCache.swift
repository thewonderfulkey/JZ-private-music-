import Foundation
import ImageIO
import UIKit

// MARK: - 封面内存缓存 + 磁盘缓存
//
// 为什么要有内存缓存：列表滚动时 `AsyncImage` 会把同一张封面反复下载/解码（离开屏幕再回来就重来一次），
// 一屏 20 行滚起来流量和 CPU 都在抖。NSCache 系统管淘汰，只留在内存里。
//
// 为什么后来又加了磁盘缓存（老板 r84："打开软件需要加载的东西都特别慢，能不能加载一次以后长时间不用再加载"）：
// 内存缓存一杀进程就没了。实测一首歌的封面 20~50 KB，一屏 20 行、几十上百首常用歌也就几 MB ——
// 落在 Caches 目录里，**下次冷启动直接读盘**（本地 IO，几十毫秒），不用等网络、也不用再求一次 rid_pic。
// 目录用 `Caches`（系统在空间紧张时可以自己清），最多 600 张 / 约 40 MB，超出按最后访问时间淘汰。
//
// 取图顺序：内存 → 磁盘 → 网络（网络成功后同时写内存和磁盘）。
final class CoverImageCache: @unchecked Sendable {

    static let shared = CoverImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// 磁盘缓存目录（Caches/cover-images）
    private let diskDirectory: URL
    /// 磁盘上限（张）。一套常用曲库的封面远小于这个数
    private let diskLimit = 600

    private init() {
        // 2026-11-21（老板："播放中翻搜索结果，90 秒后 App 直接回桌面"）：
        // 原来 cost 写死 16KB/张，60MB 上限形同虚设，真正生效的只有"300 张"这一个张数上限；
        // 一张 1080 的封面解码就是 4.6MB，300 张 = 1.4GB → jetsam 杀进程。
        // 现在：按**真实解码字节**计费 + 张数/字节双上限 + 内存警告立即清空。
        cache.countLimit = 120
        cache.totalCostLimit = 40 * 1024 * 1024   // 40MB（按真实字节算）
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.clearMemory()
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = caches.appendingPathComponent("cover-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        // 淘汰放到后台，别拖慢启动
        let dir = diskDirectory
        let limit = diskLimit
        Task.detached(priority: .utility) {
            CoverImageCache.trimDisk(directory: dir, limit: limit)
        }
    }

    /// 只读缓存（同步、不触发下载）
    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 本地文件封面（`Download/Cover/<基名>.jpg`）：已下载/导入的歌离线也要有图。
    /// 走同一套内存缓存，key 用文件 URL，互不干扰。
    func image(forFile url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let data = try? Data(contentsOf: url),
              let img = Self.downsample(data, maxPixel: Self.maxDisplayPixel) else { return nil }
        store(img, for: url)
        return img
    }

    /// 取图：内存 → 磁盘 → 网络（同一 URL 并发只下一次）
    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }

        lock.lock()
        if let task = inFlight[url] {
            lock.unlock()
            return await task.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }

            // ① 磁盘：冷启动就能命中，不用等网络（读出来也降采样，磁盘上可能是原图）
            if let onDisk = Self.loadFromDisk(url, directory: diskDirectory,
                                              maxPixel: Self.maxDisplayPixel) {
                self.store(onDisk, for: url)
                return onDisk
            }

            // ② 网络
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = Self.downsample(data, maxPixel: Self.maxDisplayPixel) else {
                return nil
            }
            self.store(image, for: url)
            Self.saveToDisk(data, url: url, directory: diskDirectory)
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

    /// 列表/播放页真正显示的最大边长。所有封面解码到这个尺寸就够，多出来的全是浪费内存。
    static let maxDisplayPixel = 300

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.decodedBytes(of: image))
    }

    /// 一张图真正占多少内存（CGImage 的 bytesPerRow × height），而不是拍脑袋的常数
    static func decodedBytes(of image: UIImage) -> Int {
        guard let cg = image.cgImage else {
            return Int(image.size.width * image.size.height * 4)
        }
        return cg.bytesPerRow * cg.height
    }

    /// 降采样解码：**不先把整张大图解出来**，直接按目标边长解码（ImageIO），
    /// 这是内存峰值最低的一条路（1500×1500 的专辑图解码成 300 只要 1/25 的内存）。
    static func downsample(_ data: Data, maxPixel: Int = 300) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    /// 把封面数据压到合适边长再落盘（写 `Cover/` 旁车用）：
    /// 原图 1500–3000px 的专辑图解码一次就是 9–36MB，既占磁盘也占内存。
    static func compressedCoverData(_ data: Data, maxPixel: Int = 600) -> Data {
        guard let image = downsample(data, maxPixel: maxPixel) else { return data }
        return image.jpegData(compressionQuality: 0.85) ?? data
    }

    /// 内存警告 / 后台时清空（缓存本来就可重建）
    func clearMemory() {
        cache.removeAllObjects()
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
        // 这个地址加载不出来（404 / CDN 拒绝 / 解码失败）：拉黑它，再走下一级兜底。
        // 不拉黑的话，缓存里那个坏地址会被反复返回，固定几首歌就永远没有封面（老板 r90 的截图）。
        if let raw = resolved {
            await CoverResolver.shared.markDead(raw, for: song)
        }

        let fallback = await CoverResolver.shared.coverURLIgnoringOriginal(for: song)
        if let raw = fallback, let url = URL(string: raw), let image = await image(for: url) {
            return image
        }
        if let raw = fallback {
            await CoverResolver.shared.markDead(raw, for: song)
        }
        return nil
    }

    func clear() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    // MARK: 磁盘读写（全部在后台任务里调用）

    private static func fileURL(for url: URL, directory: URL) -> URL {
        // 文件名用 URL 的 MD5：`Digest.md5Hex`（APIClient.swift 里那个，酷狗签名同款）。
        // 不能用 `hashValue`——Swift 的字符串哈希每次启动都换种子，重启后文件名全变，缓存等于没有。
        let name = Digest.md5Hex(url.absoluteString)
        return directory.appendingPathComponent(name).appendingPathExtension("img")
    }

    private static func loadFromDisk(_ url: URL, directory: URL,
                                     maxPixel: Int = 300) -> UIImage? {
        let file = fileURL(for: url, directory: directory)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        // 顺手刷一下修改时间：淘汰按"最后访问"排序，常用的封面不会被清掉
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return downsample(data, maxPixel: maxPixel)
    }

    private static func saveToDisk(_ data: Data, url: URL, directory: URL) {
        let file = fileURL(for: url, directory: directory)
        try? data.write(to: file, options: .atomic)
    }

    /// 超出上限时删掉最久没被访问的那些（按修改时间升序）
    private static func trimDisk(directory: URL, limit: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        guard files.count > limit else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        for file in sorted.prefix(files.count - limit) {
            try? fm.removeItem(at: file)
        }
    }
}
