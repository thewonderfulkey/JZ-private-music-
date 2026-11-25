import AVFoundation
import CryptoKit
import Foundation

// MARK: - 播放缓存（2026-11-25）
//
// 老板口径：
//   · 取到流就**整首落盘**，边落边播；
//   · 断流/403 时换一条新 token，**续写同一个文件**——播放器要字节就向我们要，
//     它只会感觉"读得慢一点"，永远收不到网络错误，所以听感上不中断、不重载；
//   · 新 token 拿到的如果不是同一份文件（总长/首段指纹不一致）→ 换下一条；
//     全都对不上就停（不播错的、也不从 0 重播）；
//   · 再播这一首优先用本地缓存；上限按"首数"配置（设置页），超出按最近播放淘汰。
//
// 为什么用 `AVAssetResourceLoader`（而不是 Android 那套"先播流 + 后台下 + 落完切本地"）：
// 那套在"落盘完成前"的那几秒仍然是播放器自己连 CDN，断了就停，事后切本地救不回来。
// 走我们自己的字节层，播放器从头到尾只跟我们要字节，换 token 是"我们内部的事"。
//
// 线程模型：每个 `CacheSession` 一条串行队列，所有状态都在那条队列上改；
// 播放器的回调（`AVAssetResourceLoaderDelegate`）也投到同一条队列，不用再锁。
final class PlaybackCache: @unchecked Sendable {

    static let shared = PlaybackCache()

    struct Entry: Codable {
        let songID: String
        let fileName: String
        let totalBytes: Int64
        let container: String
        let contentType: String
        var completed: Bool
        var lastPlayedAt: Date
    }

    private let queue = DispatchQueue(label: "jz.playback.cache", qos: .utility)
    private var entries: [String: Entry] = [:]
    /// 正在下/正在播的会话（同一首歌只留一个）
    private var sessions: [String: CacheSession] = [:]

    let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("PlaybackCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
        load()
        enforceLimit(keeping: "")
    }

    // MARK: 查询

    /// 已经完整落盘的那一首（再播时优先用它，连解析都省了）
    func completeFile(for songID: String) -> URL? {
        var out: URL?
        queue.sync {
            guard let e = entries[songID], e.completed else { return }
            let url = directory.appendingPathComponent(e.fileName)
            if FileManager.default.fileExists(atPath: url.path) { out = url }
        }
        if out != nil { touch(songID) }
        return out
    }

    func isComplete(_ songID: String) -> Bool { completeFile(for: songID) != nil }

    /// 只查、**不更新最近播放时间**（预取用；否则会把没听过的歌顶成"最近用过"）
    func hasComplete(_ songID: String) -> Bool {
        var ok = false
        queue.sync {
            guard let e = entries[songID], e.completed else { return }
            ok = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(e.fileName).path)
        }
        return ok
    }

    /// 起播前的"文件自己的索引"闸门（2026-11-25）。
    ///
    /// 只取头部 128KB（大多数歌不到 0.2 秒），用 `MediaIndexRules` 解出**文件自己写的长度**，
    /// 再和曲目时长比 ±5 秒。这是老板要的"只相信文件自己的索引"：
    ///   · 解得出且对得上 → `.match`（显示百分比、允许判播完）
    ///   · 解得出但对不上 → `.mismatch`（这一条不是同一份，换下一条，不播错的）
    ///   · 解不出         → `.unverified`（不是"错的"，只是没证据：播，但不显示百分比、不判播完）
    func indexGate(song: Song, source: StreamSource) async -> PlaybackCacheRules.DurationGate {
        guard PlaybackCacheRules.enabled, let url = URL(string: source.url) else { return .unverified }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        req.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue(StreamVerifier.referer(forHost: url.host), forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode < 400, !data.isEmpty else {
            return .unverified
        }
        let sniffed = StreamVerifier.sniffHead([UInt8](data.prefix(16)))
        let container = sniffed == "unknown" ? source.format.lowercased() : sniffed
        let sec = MediaIndexRules.duration(head: data, container: container,
                                           totalBytes: source.totalBytes)
        let gate = PlaybackCacheRules.gate(candidate: sec, expected: song.duration)
        PlaybackTrace.shared.log("索引闸门",
                                 "\(song.name) \(container) 文件 \(sec.map { "\(Int($0))s" } ?? "解不出")"
                                 + " / 曲目 \(Int(song.duration))s → \(gate)")
        return gate
    }

    func touch(_ songID: String) {
        queue.async {
            guard var e = self.entries[songID] else { return }
            e.lastPlayedAt = Date()
            self.entries[songID] = e
            self.save()
        }
    }

    /// 已缓存首数 / 占用字节（设置页显示）
    func usage() -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        queue.sync {
            for e in entries.values where e.completed {
                count += 1
                bytes += e.totalBytes
            }
        }
        return (count, bytes)
    }

    func clear() {
        queue.sync {
            for s in sessions.values { s.cancel() }
            sessions.removeAll()
            entries.removeAll()
            if let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil) {
                for f in files { try? FileManager.default.removeItem(at: f) }
            }
            save()
        }
    }

    /// 上限变了（设置页拖数字）：立刻按最近播放淘汰
    func setLimit(_ limit: Int) {
        queue.async { self.enforceLimit(keeping: "") }
    }

    // MARK: 给播放器造 item

    /// 造一个"从我们这里取字节"的播放项。返回 nil 表示缓存关闭/不可用，调用方退回直连。
    func playbackItem(song: Song, source: StreamSource, container: String,
                      resolver: @escaping (Set<String>) async -> StreamSource?)
        -> (item: AVPlayerItem, session: CacheSession)? {
        guard PlaybackCacheRules.enabled, SettingsStore.shared.playbackCacheLimit > 0,
              source.totalBytes > 0 else { return nil }
        var made: (item: AVPlayerItem, session: CacheSession)?
        queue.sync {
            let session = CacheSession(song: song, source: source, container: container,
                                       resolver: resolver, store: self)
            sessions[song.id] = session
            guard let url = URL(string: "jzcache://song/\(session.token)") else { return }
            let asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(session, queue: session.queue)
            let item = AVPlayerItem(asset: asset)
            made = (item: item, session: session)
            session.start()
        }
        return made
    }

    /// 只落盘、不播放（下一首预取 / 心动缓存）
    func prefetch(song: Song, source: StreamSource) {
        guard PlaybackCacheRules.enabled, SettingsStore.shared.playbackCacheLimit > 0,
              source.totalBytes > 0 else { return }
        queue.async {
            if let existing = self.sessions[song.id], !existing.finished { return }
            if self.entries[song.id]?.completed == true { return }
            let session = CacheSession(song: song, source: source,
                                       container: source.format, resolver: { _ in nil }, store: self)
            self.sessions[song.id] = session
            session.start()
        }
    }

    func cancel(songID: String) {
        queue.async {
            self.sessions[songID]?.cancel()
            self.sessions[songID] = nil
        }
    }

    // MARK: 落盘完成 / 淘汰

    fileprivate func finished(song: Song, source: StreamSource, container: String,
                              file: URL, bytes: Int64) {
        queue.async {
            let name = file.lastPathComponent
            let entry = Entry(songID: song.id, fileName: name, totalBytes: bytes,
                              container: container,
                              contentType: PlaybackCacheRules.contentType(container: container,
                                                                          format: source.format),
                              completed: true, lastPlayedAt: Date())
            self.entries[song.id] = entry
            self.sessions[song.id]?.finished = true
            self.save()
            self.enforceLimit(keeping: song.id)
        }
    }

    private func enforceLimit(keeping: String) {
        let limit = PlaybackCacheRules.clampLimit(SettingsStore.shared.playbackCacheLimit)
        guard limit > 0 else { return }
        let ordered = entries.values
            .filter { $0.completed }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }
            .map { (id: $0.songID, lastPlayed: $0.lastPlayedAt) }
        let victims = PlaybackCacheRules.victims(orderedByLastPlayed: ordered,
                                                 limit: limit, keeping: keeping)
        for id in victims {
            guard let e = entries.removeValue(forKey: id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.fileName))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.fileName + ".json"))
        }
        if !victims.isEmpty { save() }
    }

    // MARK: 索引落盘

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.songID, $0) })
    }

    private func save() {
        let list = Array(entries.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - 单首歌的会话：下载 + 供字节

final class CacheSession: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate,
                          @unchecked Sendable {

    let queue = DispatchQueue(label: "jz.playback.cache.session", qos: .userInitiated)
    let token = UUID().uuidString

    private let song: Song
    private var source: StreamSource
    private let container: String
    private let resolver: (Set<String>) async -> StreamSource?
    private unowned let store: PlaybackCache

    private var urlSession: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?

    /// 已连续写入到哪个字节（0..<frontier 一定在文件里）
    private var frontier: Int64 = 0
    private var totalBytes: Int64 = 0
    /// 服务端忽略 Range 回了 200 时，前面的字节要丢掉
    private var skip: Int64 = 0
    private var attempts = 0
    private var triedURLs: Set<String> = []
    private var headHash: String?
    private var pending: [Pending] = []
    private var completed = false
    var finished = false

    private var partURL: URL
    private var finalURL: URL

    private struct Pending {
        let request: AVAssetResourceLoadingRequest
        let offset: Int64
        var sent: Int64
        var length: Int64
        var toEndOfResource: Bool
    }

    var contentType: String
    var contentLength: Int64 { totalBytes }

    init(song: Song, source: StreamSource, container: String,
         resolver: @escaping (Set<String>) async -> StreamSource?, store: PlaybackCache) {
        self.song = song
        self.source = source
        self.container = container
        self.resolver = resolver
        self.store = store
        self.contentType = PlaybackCacheRules.contentType(container: container,
                                                          format: source.format)
        let name = PlaybackCacheRules.fileName(songID: song.id)
        self.partURL = store.directory.appendingPathComponent(name + ".part")
        self.finalURL = store.directory.appendingPathComponent(name)
        self.totalBytes = source.totalBytes
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: 生命周期

    func start() {
        queue.async {
            guard !self.completed else { return }
            self.openFile()
            self.request(path: self.source.url)
        }
    }

    func cancel() {
        queue.async {
            self.task?.cancel()
            self.task = nil
            self.fillError("已取消")
        }
    }

    private func openFile() {
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: partURL)
        let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
        frontier = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        _ = try? handle?.seekToEnd()
    }

    private func request(path: String) {
        guard let url = URL(string: path) else { fail(); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("bytes=\(frontier)-", forHTTPHeaderField: "Range")
        req.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue(StreamVerifier.referer(forHost: url.host), forHTTPHeaderField: "Referer")
        triedURLs.insert(path)
        skip = 0
        task = urlSession.dataTask(with: req)
        task?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel); return
            }
            if http.statusCode == 403 || http.statusCode == 404 || http.statusCode >= 500 {
                completionHandler(.cancel)
                self.retryOrFail("HTTP \(http.statusCode)")
                return
            }
            if http.statusCode == 200, self.frontier > 0 {
                // 服务端不认 Range：整段重发，前面已写的要跳过
                self.skip = self.frontier
            }
            if self.totalBytes <= 0 {
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = range.lastIndex(of: "/"),
                   let n = Int64(range[range.index(after: slash)...]) {
                    self.totalBytes = n
                } else if let len = http.value(forHTTPHeaderField: "Content-Length"),
                          let n = Int64(len) {
                    self.totalBytes = n
                }
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            var chunk = data
            if self.skip > 0 {
                let drop = Int(min(self.skip, Int64(chunk.count)))
                chunk = chunk.subdata(in: drop..<chunk.count)
                self.skip -= Int64(drop)
                if chunk.isEmpty { return }
            }
            guard let handle = self.handle else { return }
            try? handle.write(contentsOf: chunk)
            self.frontier += Int64(chunk.count)
            if self.headHash == nil, self.frontier >= 4096 {
                self.headHash = self.hashOfHead()
            }
            self.pump()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            if let error {
                self.retryOrFail(error.localizedDescription)
                return
            }
            if self.totalBytes > 0, self.frontier < self.totalBytes {
                self.retryOrFail("提前结束")
                return
            }
            self.finishFile()
        }
    }

    // MARK: 落盘 / 重试

    private func hashOfHead() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: partURL) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !head.isEmpty else { return nil }
        return SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
    }

    private func finishFile() {
        guard !completed else { return }
        completed = true
        finished = true
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: partURL, to: finalURL)
        store.finished(song: song, source: source, container: container,
                       file: finalURL, bytes: max(frontier, totalBytes))
        pump()
        // 全下完了：还在等字节的请求由 pump 收尾
        if pending.isEmpty { finishAllRequests() }
    }

    private func retryOrFail(_ reason: String) {
        PlaybackTrace.shared.log("缓存断流", "\(song.name)：\(reason)（已下 \(frontier)/\(totalBytes)）")
        guard attempts < 3 else {
            fail()
            return
        }
        attempts += 1
        let tried = triedURLs
        Task { [weak self] in
            guard let self else { return }
            guard let next = await self.resolver(tried) else {
                self.queue.async { self.fail() }
                return
            }
            let same = await self.sameFile(as: next)
            self.queue.async {
                if same {
                    PlaybackTrace.shared.log("缓存续拉", "\(self.song.name) ← \(next.backendName)")
                    self.source = next
                    self.request(path: next.url)
                } else {
                    PlaybackTrace.shared.log("缓存换版本", "\(self.song.name)：不是同一份，换下一条")
                    self.retryOrFail("不是同一份文件")
                }
            }
        }
    }

    /// 新直链是不是同一份文件：总长 + 首段指纹
    private func sameFile(as next: StreamSource) async -> Bool {
        let oldBytes = totalBytes
        let oldHash = headHash
        var newBytes = next.totalBytes
        var newHash: String?
        if let url = URL(string: next.url) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            req.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
            req.setValue(StreamVerifier.referer(forHost: url.host), forHTTPHeaderField: "Referer")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400, !data.isEmpty {
                newHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if newBytes <= 0, let range = (resp as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Range"),
                   let slash = range.lastIndex(of: "/"),
                   let n = Int64(range[range.index(after: slash)...]) {
                    newBytes = n
                }
            }
        }
        return PlaybackCacheRules.sameFile(oldBytes: oldBytes, newBytes: newBytes,
                                           oldHash: oldHash, newHash: newHash)
    }

    private func fail() {
        fillError("这一首的文件取不全了（源都换过，但不是同一份）")
    }

    private func fillError(_ message: String) {
        for p in pending {
            p.request.finishLoading(with: NSError(domain: "jz.cache", code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]))
        }
        pending.removeAll()
        finished = true
    }

    private func finishAllRequests() {
        for p in pending { p.request.finishLoading() }
        pending.removeAll()
    }

    // MARK: 供字节（AVAssetResourceLoader）

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        queue.async { self.attach(loadingRequest) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        queue.async {
            self.pending.removeAll { $0.request === loadingRequest }
        }
    }

    private func attach(_ request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            if totalBytes > 0 { info.contentLength = totalBytes }
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return
        }
        let toEnd = data.requestsAllDataToEndOfResource
        var length = data.requestedLength
        if toEnd, totalBytes > 0 { length = max(0, totalBytes - data.requestedOffset) }
        pending.append(Pending(request: request, offset: data.requestedOffset, sent: 0,
                               length: length, toEndOfResource: toEnd))
        pump()
    }

    /// 把已经落盘的字节喂给播放器；还不够就等下载推进
    private func pump() {
        guard !pending.isEmpty else { return }
        var keep: [Pending] = []
        for var p in pending {
            while p.sent < p.length || (p.toEndOfResource && !completed) {
                let want = p.length > 0 ? p.length - p.sent : 262_144
                let available = frontier - (p.offset + p.sent)
                if available <= 0 { break }
                let n = Int(min(Int64(want), available))
                if let chunk = read(offset: p.offset + p.sent, length: n) {
                    p.request.dataRequest?.respond(with: chunk)
                    p.sent += Int64(chunk.count)
                } else {
                    break
                }
                if p.length > 0, p.sent >= p.length { break }
                if p.toEndOfResource, completed, p.sent >= totalBytes - p.offset { break }
            }
            let done = p.length > 0 ? p.sent >= p.length
                : (completed && p.sent >= max(0, totalBytes - p.offset))
            if done {
                p.request.finishLoading()
            } else {
                keep.append(p)
            }
        }
        pending = keep
    }

    private func read(offset: Int64, length: Int) -> Data? {
        let url = completed ? finalURL : partURL
        guard length > 0, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: UInt64(offset))
            return try fh.read(upToCount: length) ?? Data()
        } catch {
            return nil
        }
    }
}
