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
//   · 再播这一首优先用本地缓存；上限按"首数"配置（设置页），满了就**头进尾出**：
//     新歌从头上进来、最早进缓存的那首从尾巴挤出去，总量恒定。
//
// 为什么用 `AVAssetResourceLoader`（而不是 Android 那套"先播流 + 后台下 + 落完切本地"）：
// 那套在"落盘完成前"的那几秒仍然是播放器自己连 CDN，断了就停，事后切本地救不回来。
// 走我们自己的字节层，播放器从头到尾只跟我们要字节，换 token 是"我们内部的事"。
//
// 线程模型：每个 `CacheSession` 一条串行队列，所有状态都在那条队列上改；
// 播放器的回调（`AVAssetResourceLoaderDelegate`）也投到同一条队列，不用再锁。

/// 播放打点：`PlaybackTrace` 是 `@MainActor` 的，缓存层在后台队列 → 统一从这里跳回主线程。
private func trace(_ stage: String, _ note: String) {
    Task { @MainActor in PlaybackTrace.shared.log(stage, note) }
}

final class PlaybackCache: @unchecked Sendable {

    static let shared = PlaybackCache()

    struct Entry: Codable {
        let songID: String
        let fileName: String
        let totalBytes: Int64
        let container: String
        let contentType: String
        var completed: Bool
        /// 什么时候进缓存的（**淘汰就看它**：头进尾出，先进来的先走）
        let savedAt: Date
        /// 最近一次播放（只用于显示/排查，不参与淘汰）
        var lastPlayedAt: Date
        // MARK: 身份（2026-11-25《众》播成《侧脸》之后加的）
        //
        // 老条目没有这几项 → 解码成 nil → 一律当"来历不明"作废（升级时清一次，见 `load`）。
        // 有身份才能回答：这份文件是给哪条候选写的、它自己有多长、和当前这首歌对不对得上。
        var matchedName: String? = nil
        var matchedSinger: String? = nil
        var matchedPlatformID: String? = nil
        var matchedDurationSec: Double? = nil
        /// 文件自己的长度（下载完成后从本地文件头解出来的）
        var measuredDurationSec: Double? = nil
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

    /// 一次命中的缓存文件（带身份，供播放页的"音源详情"和起播时判断用）
    struct CachedFile {
        let url: URL
        let totalBytes: Int64
        let matchedName: String?
        let matchedSinger: String?
        let matchedPlatformID: String?
        let matchedDurationSec: Double?
        let measuredDurationSec: Double?
    }

    /// 已经完整落盘的那一首（再播时优先用它，连解析都省了）
    ///
    /// 2026-11-25：这里现在**要过身份复核**。以前只查"条目在、文件在"，
    /// 《众》的条目里装着《侧脸》的字节也照样命中，于是错音频永远播下去。
    /// 对不上就当场作废（删条目 + 删文件）并返回 nil，调用方会重新解析。
    func cachedFile(for song: Song) -> CachedFile? {
        var out: CachedFile?
        queue.sync {
            guard let e = entries[song.id], e.completed else { return }
            let url = directory.appendingPathComponent(e.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            guard NameMatch.cacheIdentityOK(displayed: song,
                                            matchedName: e.matchedName,
                                            matchedSinger: e.matchedSinger,
                                            matchedDurationSec: e.matchedDurationSec,
                                            measuredDurationSec: e.measuredDurationSec) else {
                entries[song.id] = nil
                try? FileManager.default.removeItem(at: url)
                self.removeOtherFiles(songID: song.id, keeping: "")
                save()
                Task { @MainActor in
                    PlaybackTrace.shared.log("缓存作废",
                                             "\(song.name)：条目里的候选不是这首歌，已删并重解析")
                }
                return
            }
            out = CachedFile(url: url, totalBytes: e.totalBytes,
                             matchedName: e.matchedName, matchedSinger: e.matchedSinger,
                             matchedPlatformID: e.matchedPlatformID,
                             matchedDurationSec: e.matchedDurationSec,
                             measuredDurationSec: e.measuredDurationSec)
        }
        if out != nil { touch(song.id) }
        return out
    }

    /// 只查存在（UI 的「已缓存」标记用；不做身份复核，避免在滚动列表里触发删文件）
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
    ///
    /// 2026-11-25：这里也要过身份复核——否则一条坏的缓存会让"预取"永远跳过这首歌。
    func hasComplete(_ song: Song) -> Bool {
        cachedFile(for: song) != nil
    }

    /// 起播前的一次探测（2026-11-25）：文件自己的索引 + 首段指纹。
    ///
    /// 只取头部 128KB（大多数歌不到 0.2 秒），一次请求同时拿到两样东西：
    ///   · 索引解出的时长 → 和曲目比 ±5 秒（`gate`）
    ///   · 首 4KB 的 SHA256 → **半截 .part 能不能接着写**（`PlaybackCacheRules.canResume`）
    /// 指纹是硬要求：没有它就无法证明"这次的源和上次那半截是同一份文件"。
    struct Probe {
        let gate: PlaybackCacheRules.DurationGate
        let headHash: String?
        let totalBytes: Int64
    }

    func probe(song: Song, source: StreamSource) async -> Probe {
        let empty = Probe(gate: .unverified, headHash: nil, totalBytes: source.totalBytes)
        guard PlaybackCacheRules.enabled, let url = URL(string: source.url) else { return empty }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        req.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue(StreamVerifier.referer(forHost: url.host), forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode < 400, !data.isEmpty else {
            return empty
        }
        var total = source.totalBytes
        if total <= 0, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"), let n = Int64(range[range.index(after: slash)...]) {
            total = n
        }
        let headHash = SHA256.hash(data: data.prefix(4096))
            .map { String(format: "%02x", Int($0)) }.joined()
        let sniffed = StreamVerifier.sniffHead([UInt8](data.prefix(16)))
        let container = sniffed == "unknown" ? source.format.lowercased() : sniffed
        let sec = MediaIndexRules.duration(head: data, container: container, totalBytes: total)
        let gate = PlaybackCacheRules.gate(candidate: sec, expected: song.duration)
        trace("索引闸门",
              "\(song.name) \(container) 文件 \(sec.map { "\(Int($0))s" } ?? "解不出")"
              + " / 曲目 \(Int(song.duration))s → \(gate)")
        return Probe(gate: gate, headHash: headHash, totalBytes: total)
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
    ///
    /// `headHash` 来自 `probe`：`CacheSession` 只用它判断"上次那半截 .part 还是不是这份文件"。
    func playbackItem(song: Song, source: StreamSource, container: String, headHash: String?,
                      resolver: @escaping (Set<String>) async -> StreamSource?)
        -> (item: AVPlayerItem, session: CacheSession)? {
        guard PlaybackCacheRules.enabled, SettingsStore.shared.playbackCacheLimit > 0,
              source.totalBytes > 0 else { return nil }
        var made: (item: AVPlayerItem, session: CacheSession)?
        queue.sync {
            // 同一首歌**只许有一个写者**：先把旧的会话停掉，否则两个会话会同时往一个 .part 里写
            // （真机事故：字节交错 → 播放器读出来是垃圾 → 一直抖、一直失败）
            sessions[song.id]?.cancel()
            let session = CacheSession(song: song, source: source, container: container,
                                       expectedHeadHash: headHash,
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
            // 预取没有探测指纹可对，**不许续写旧半截**：先清掉，从 0 下（多下几 MB，换一个确定的正确）
            let name = PlaybackCacheRules.fileBase(songID: song.id)
            for suffix in [".part", ".part.json"] {
                try? FileManager.default.removeItem(
                    at: self.directory.appendingPathComponent(name + suffix))
            }
            let session = CacheSession(song: song, source: source, container: source.format,
                                       expectedHeadHash: nil,
                                       resolver: { _ in nil }, store: self)
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
            // 同一个 songID 只留一份：换了容器（mp3→m4a）会生成另一个后缀的文件，
            // 旧那份必须清掉（否则既是垃圾、又可能被当成另一条缓存）
            self.removeOtherFiles(songID: song.id, keeping: name)
            let measured = Self.measure(file: file, fallbackContainer: container, totalBytes: bytes)
            let entry = Entry(songID: song.id, fileName: name, totalBytes: bytes,
                              container: container,
                              contentType: PlaybackCacheRules.contentType(container: container,
                                                                          format: source.format),
                              completed: true, savedAt: Date(), lastPlayedAt: Date(),
                              matchedName: source.matchedName,
                              matchedSinger: source.matchedSinger,
                              matchedPlatformID: source.matchedPlatformID,
                              matchedDurationSec: source.matchedDurationSec,
                              measuredDurationSec: measured)
            self.entries[song.id] = entry
            self.sessions[song.id]?.finished = true
            self.save()
            self.enforceLimit(keeping: song.id)
            Task { @MainActor in
                PlaybackTrace.shared.log("缓存完成",
                                         "\(song.name) ← \(source.matchedName ?? "?") "
                                         + "文件 \(measured.map { "\(Int($0))s" } ?? "长度解不出")")
            }
        }
    }

    /// 从刚下完的**本地文件**里解长度（文件自己的索引，不联网）
    private static func measure(file: URL, fallbackContainer: String, totalBytes: Int64) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 262_144)) ?? Data()
        guard !head.isEmpty else { return nil }
        let sniffed = StreamVerifier.sniffHead([UInt8](head.prefix(16)))
        let container = sniffed == "unknown" ? fallbackContainer : sniffed
        return MediaIndexRules.duration(head: head, container: container, totalBytes: totalBytes)
    }

    /// 把这一首的缓存判成**坏的**：删索引、删文件（含半截）。播放层在"缓存文件读不出来"时调它。
    ///
    /// 同步执行是硬要求：调用方紧接着就 `beginLoad()` 重播，那一刻必须已经不命中——
    /// 否则又会命中同一个坏文件，回到"无限换源"（2026-11-25 真机事故的形态）。
    func discard(songID: String) {
        queue.sync {
            self.sessions[songID]?.cancel()
            self.sessions[songID] = nil
            if let e = self.entries.removeValue(forKey: songID) {
                try? FileManager.default.removeItem(
                    at: self.directory.appendingPathComponent(e.fileName))
            }
            self.removeOtherFiles(songID: songID, keeping: "")
            self.save()
        }
    }

    /// 清掉同一首歌除 `keeping` 之外的所有文件（旧后缀的成品、半截 `.part`、`.part.json`）
    private func removeOtherFiles(songID: String, keeping: String) {
        let base = PlaybackCacheRules.fileBase(songID: songID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let n = f.lastPathComponent
            guard n.hasPrefix(base + "."), n != keeping else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func enforceLimit(keeping: String) {
        let limit = PlaybackCacheRules.clampLimit(SettingsStore.shared.playbackCacheLimit)
        guard limit > 0 else { return }
        // 头进尾出：按"进缓存的时间"排队，最先进来的先淘汰（老板 2026-11-25 定）
        let ordered = entries.values
            .filter { $0.completed }
            .sorted { $0.savedAt < $1.savedAt }
            .map { (id: $0.songID, cachedAt: $0.savedAt) }
        let victims = PlaybackCacheRules.victims(orderedByCachedAt: ordered,
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
        // 只收"后缀是已知音频容器"的条目：v2.4.112–115 缓存下来的是 `p_xxx.audio`，
        // 那种文件 AVFoundation 认不出类型（2026-11-25 真机事故）。升级时直接丢掉并删文件，
        // 否则老板装上新包、点开那首已经缓存过的歌，还是同一个 0:00 卡死。
        //
        // 2026-11-25 第二刀：**没有身份的条目一律作废**。v2.4.116 及以前的条目只记了
        // "这是哪首歌的缓存"，没记"字节是从哪条候选下来的"——《众》的条目里就可能是
        // 《侧脸》的字节。判断不了就删掉重下（一次性，最多 50 首）。
        var kept: [String: Entry] = [:]
        var dropped: [Entry] = []
        for e in list {
            let playable = PlaybackCacheRules.isPlayableExtension((e.fileName as NSString).pathExtension)
            let identified = !((e.matchedName ?? "").isEmpty)
            if playable && identified {
                kept[e.songID] = e
            } else {
                dropped.append(e)
            }
        }
        for e in dropped {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.fileName))
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(e.fileName + ".json"))
        }
        entries = kept
        if !dropped.isEmpty { save() }
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
    /// 这次要写的源的首段指纹（来自起播前的 probe）；nil = 没有证据，那就不许续写旧半截
    private let expectedHeadHash: String?
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

    init(song: Song, source: StreamSource, container: String, expectedHeadHash: String?,
         resolver: @escaping (Set<String>) async -> StreamSource?, store: PlaybackCache) {
        self.song = song
        self.source = source
        self.container = container
        self.expectedHeadHash = expectedHeadHash
        self.resolver = resolver
        self.store = store
        self.contentType = PlaybackCacheRules.contentType(container: container,
                                                          format: source.format)
        let base = PlaybackCacheRules.fileBase(songID: song.id)
        // 落盘文件用**真容器**当后缀：缓存命中时这个文件会被直接交给 AVFoundation，
        // 它按扩展名判类型（旧版写死 `.audio` → 认不出 → 一起播就失败，真机事故）
        let ext = PlaybackCacheRules.fileExtension(container: container, format: source.format)
        self.partURL = store.directory.appendingPathComponent(base + ".part")
        self.finalURL = store.directory.appendingPathComponent(base + "." + ext)
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
            self.savePartMeta()
            try? self.handle?.close()
            self.handle = nil
            self.finished = true
            self.fillError("已取消")
        }
    }

    /// `.part` 的身份（首段指纹 + 已下字节）：续写之前必须对得上，对不上就从 0 重下
    private struct PartMeta: Codable {
        let headHash: String
        let bytes: Int64
    }

    private var sidecarURL: URL { URL(fileURLWithPath: partURL.path + ".json") }

    private func openFile() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
        let existing = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let stored = (try? Data(contentsOf: sidecarURL))
            .flatMap { try? JSONDecoder().decode(PartMeta.self, from: $0) }
        let resume = PlaybackCacheRules.canResume(partBytes: existing,
                                                  partHash: stored?.headHash,
                                                  newHash: expectedHeadHash,
                                                  newBytes: totalBytes)
        if existing > 0, !resume {
            // 真机事故的根：旧半截和这次要写的不是同一份，混在一起就是垃圾音频
            trace("缓存丢弃", "\(song.name)：旧半截 \(existing)B 不是这份，从 0 重下")
            try? FileManager.default.removeItem(at: partURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: partURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: partURL.path))
            .flatMap { $0[.size] as? NSNumber }?.int64Value ?? 0
        frontier = resume ? size : 0
        _ = try? handle?.seekToEnd()
    }

    private func savePartMeta() {
        guard let h = headHash, frontier > 0 else { return }
        let meta = PartMeta(headHash: h, bytes: frontier)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }

    private func request(path: String) {
        if totalBytes > 0, frontier >= totalBytes {
            finishFile()          // 上次已经下完，只是没来得及改名
            return
        }
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
                self.savePartMeta()
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
        return SHA256.hash(data: head).map { String(format: "%02x", Int($0)) }.joined()
    }

    private func finishFile() {
        guard !completed else { return }
        completed = true
        finished = true
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: partURL, to: finalURL)
        try? FileManager.default.removeItem(at: sidecarURL)
        store.finished(song: song, source: source, container: container,
                       file: finalURL, bytes: max(frontier, totalBytes))
        pump()
        // 全下完了：还在等字节的请求由 pump 收尾
        if pending.isEmpty { finishAllRequests() }
    }

    private func retryOrFail(_ reason: String) {
        trace("缓存断流", "\(song.name)：\(reason)（已下 \(frontier)/\(totalBytes)）")
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
                    trace("缓存续拉", "\(self.song.name) ← \(next.backendName)")
                    self.source = next
                    self.request(path: next.url)
                } else {
                    trace("缓存换版本", "\(self.song.name)：不是同一份，换下一条")
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
               ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 400, !data.isEmpty {
                newHash = SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
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
        // 坏掉的半截文件必须删掉：留着的话下一次还会续写它，永远好不了（真机事故就是这么"一直抖"的）
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: partURL)
        try? FileManager.default.removeItem(at: sidecarURL)
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
        var length = Int64(data.requestedLength)
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
