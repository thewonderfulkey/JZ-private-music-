import AVFoundation
import CryptoKit
import Darwin
import Foundation
import UIKit
import UserNotifications

// MARK: - 下载管理器
/// 管理下载任务：前台 URLSession（实时进度）+ 后台 URLSession（App 退后台继续下载）。
/// 文件保存到 App 沙盒 Documents/Music/ 目录（已开启 UIFileSharingEnabled，
/// 在"文件"App → 我的 iPhone → JZ 音乐 中可见）。
///
/// 2026-11-16 第二轮修的三个真问题（老板反馈 ⑥）：
///   ① **下载失败**：`didFinishDownloadingTo` 里把临时文件 `moveItem` 放进了 `DispatchQueue.main.async`，
///      而那个临时文件在 delegate 回调返回的瞬间就可能被系统删掉 → 移动失败 → 记一条失败。
///      现在**在回调线程里同步搬走**，再回主线程更新状态。
///   ② **标着无损实际 320k**：落盘后按文件头（前 16 字节）+ 真实体积重算容器与码率，
///      档位以实测为准，并把文件名后缀改成真实容器（`.flac` 里装的是 mp3 这种会当场改回 `.mp3`）。
///   ③ 同一份 taskMap 被 delegate 队列和主线程同时读写 → 用锁包起来。
final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()

    /// 主线程发布：下载列表
    @Published var items: [DownloadItem] = [] {
        didSet {
            // 任何条目变化都让"本地路径/封面"缓存失效（2026-11-21 老板："打开下载 tab 会卡一下"）
            localFileCache.removeAll()
            localCoverCache.removeAll()
        }
    }
    @Published var backgroundTaskCount: Int = 0

    /// `song.id` → 本地音频路径（空串 = 查过、没有）。
    ///
    /// `localFileURL` / `localCoverURL` 原来每次都线性扫 `items`、还各做 1–3 次 `fileExists`；
    /// 下载页**每一行封面**都要走这条路 → N 首就是 O(N²) + 上千次磁盘 stat，
    /// 打开下载页/刚导入完（列表变大）时就会卡一下。
    private var localFileCache: [String: String] = [:]
    /// `song.id` → 本地封面路径（空串 = 查过、没有）
    private var localCoverCache: [String: String] = [:]
    /// 最近一次导入的结果（挂在 manager 上，而不是 View 的 @State —— 否则
    /// 从 Task.detached 里写不回去，用户看不到任何提示）
    @Published var lastImportReport: String?
    /// 导入进度（nil = 没在导入）。后台写、主线程读。
    @Published var importProgress: ImportProgress?
    /// 取消标记（导入循环每首检查一次）
    var importCancelled = false

    private let backgroundID = "com.jz.musichelper.downloads"

    private var foregroundSession: URLSession!
    private var backgroundSession: URLSession!

    // taskIdentifier 相关状态：delegate 队列与主线程都会碰，统一加锁
    private let taskLock = NSLock()
    private var taskMap: [Int: UUID] = [:]
    private var taskFileNames: [Int: String] = [:]

    // 歌词/封面补料状态（老板反馈 ⑧）。补料任务跑在后台，删除下载在主线程，
    // 两边都要碰这两个集合，所以同样用锁保护（跟 taskMap 一样，delegate/主线程不共享裸状态）。
    //   · companionRunning：同一 item 只补一次（下载完成回调理论上只来一次，但重试/极端时序仍要防）
    //   · companionCancelled：删除下载时给在飞的任务打标记，让它在写盘前退出，
    //     否则会出现"音频删了、旁车又被写回来"的孤儿文件
    private let companionLock = NSLock()
    private var companionRunning: Set<UUID> = []
    private var companionCancelled: Set<UUID> = []

    /// 下载记录的落盘路径（原来借 HistoryStore，现在 Downloads 自己存，避免两个 store 互相依赖）
    private var recordsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("downloads.json")
    }

    private override init() {
        super.init()
        let fgConfig = URLSessionConfiguration.default
        fgConfig.timeoutIntervalForRequest = 60
        foregroundSession = URLSession(configuration: fgConfig, delegate: self, delegateQueue: nil)

        let bgConfig = URLSessionConfiguration.background(withIdentifier: backgroundID)
        bgConfig.sessionSendsLaunchEvents = true
        bgConfig.isDiscretionary = false
        backgroundSession = URLSession(configuration: bgConfig, delegate: self, delegateQueue: nil)

        loadPersisted()
        // 第四十轮补丁 4：把旧版 `Documents/Music` 里的文件搬进新的三个子目录，搬空后删掉这个文件夹
        // （老板："后台文件既然全都存在 Downloads 中了，为什么还留着 Music 文件夹，可以删了"）
        migrateLegacyMusicFolderIfNeeded()
    }

    // MARK: - 旧版目录迁移

    /// 旧版把音频和旁车都放在 `Documents/Music`。新版是根目录下的 `Music / Lyrics / Cover`，
    /// 根目录默认 `Documents/Download`。
    ///
    /// 这里做一次**搬家**（不是删除）：按扩展名分到对应子目录、把 `downloads.json` 里的
    /// 绝对路径同步改掉，最后把搬空的旧 `Music` 删掉。
    /// 顺序很重要：先搬文件、再改记录，否则"点播"会去找一个已经不存在的旧路径
    /// （老板 r115 的"点播没了、只剩照片"就是这个现象）。
    private func migrateLegacyMusicFolderIfNeeded() {
        let docs = DownloadLocation.documentsDirectory()
        let legacy = docs.appendingPathComponent("Music", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        let music = DownloadLocation.musicDirectory()
        let lyrics = DownloadLocation.lyricsDirectory()
        let covers = DownloadLocation.coverDirectory()

        var moved: [String: String] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in files {
                let ext = url.pathExtension.lowercased()
                let destinationDir: URL
                if ext == "lrc" {
                    destinationDir = lyrics
                } else if ["jpg", "jpeg", "png", "webp"].contains(ext) {
                    destinationDir = covers
                } else {
                    destinationDir = music
                }
                let target = destinationDir.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                }
                if (try? FileManager.default.moveItem(at: url, to: target)) != nil {
                    moved[url.lastPathComponent] = target.path
                }
            }
        }

        // 记录里的绝对路径跟着改：老的 localPath 指向 Documents/Music/xxx
        var changed = false
        for idx in items.indices {
            guard let old = items[idx].localPath, old.hasPrefix(legacy.path) else { continue }
            let name = URL(fileURLWithPath: old).lastPathComponent
            if let newPath = moved[name] {
                items[idx].localPath = newPath
                changed = true
            }
        }
        if changed { persist() }

        // 搬空了就删掉旧文件夹（里面还有搬不动的东西就留着，别误删）
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    // MARK: - 目录
    //
    // 第四十轮补丁 3（老板："歌曲 / 歌词 / 封面各放一个文件夹"）：
    //   音频 → `文件 › JZ 音乐 › Download › Music`
    //   歌词 → `文件 › JZ 音乐 › Download › Lyrics`
    //   封面 → `文件 › JZ 音乐 › Download › Cover`
    // 根目录由设置页决定（默认 `Download`），三个子目录在根下面同级。

    /// 当前根目录（设置页选的位置；默认 Documents/Download）
    var rootDirectory: URL {
        DownloadLocation.currentDirectory()
    }

    /// 音频目录（`…/Music`）
    var musicDirectory: URL {
        DownloadLocation.musicDirectory()
    }

    /// 歌词旁车目录（`…/Lyrics`）
    var lyricsDirectory: URL {
        DownloadLocation.lyricsDirectory()
    }

    /// 封面旁车目录（`…/Cover`）
    var coverDirectory: URL {
        DownloadLocation.coverDirectory()
    }

    /// 清理文件名中的非法字符
    private func sanitizeFileName(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: illegal).joined(separator: "_")
    }

    // MARK: - task 登记（线程安全）

    private func register(_ task: URLSessionTask, id: UUID, fileName: String) {
        taskLock.lock()
        taskMap[task.taskIdentifier] = id
        taskFileNames[task.taskIdentifier] = fileName
        taskLock.unlock()
    }

    private func itemID(for taskIdentifier: Int) -> UUID? {
        taskLock.lock()
        defer { taskLock.unlock() }
        return taskMap[taskIdentifier]
    }

    private func fileName(for taskIdentifier: Int) -> String? {
        taskLock.lock()
        defer { taskLock.unlock() }
        return taskFileNames[taskIdentifier]
    }

    private func unregister(_ taskIdentifier: Int) {
        taskLock.lock()
        taskMap[taskIdentifier] = nil
        taskFileNames[taskIdentifier] = nil
        taskLock.unlock()
    }

    private func taskIdentifier(forItem id: UUID) -> Int? {
        taskLock.lock()
        defer { taskLock.unlock() }
        return taskMap.first(where: { $0.value == id })?.key
    }

    // MARK: - 下载

    /// 开始下载（后台会话）。返回条目 id。
    /// `expectedBytes` 是取流阶段 Range 探到的真实体积：进度条先按它算百分比，
    /// 落盘后再拿它做 95% 完整性校验（见 `DownloadGuard.isComplete`）。
    @discardableResult
    func download(song: Song, streamSource: StreamSource, expectedBytes: Int64 = 0,
                  useBackground: Bool = true) -> UUID {
        // 同一首歌已经在下就别再排一条（两条任务会抢同一个文件名）
        if let active = activeItem(for: song) { return active.id }

        let ext = Self.extensionForFormat(streamSource.format, url: streamSource.url)
        let fileName = sanitizeFileName("\(song.singer) - \(song.name) [\(song.platform.shortName)/\(streamSource.backendName)].\(ext)")
        let expected = expectedBytes > 0 ? expectedBytes : streamSource.totalBytes
        var item = DownloadItem(song: song,
                                streamURL: streamSource.url,
                                backendName: streamSource.backendName,
                                quality: streamSource.quality,
                                fileName: fileName,
                                status: .pending,
                                totalBytes: max(expected, 0),
                                expectedBytes: expected > 0 ? expected : nil)
        let id = item.id
        guard let url = URL(string: streamSource.url) else {
            item.status = .failed
            item.errorMessage = "无效 URL"
            appendOrUpdate(item)
            return id
        }

        let session: URLSession = useBackground ? backgroundSession : foregroundSession
        let task = session.downloadTask(with: URLRequest.download(url))
        item.status = .downloading
        appendOrUpdate(item)
        register(task, id: id, fileName: fileName)
        task.resume()
        return id
    }

    // MARK: - 查询

    /// 这首歌是否已经下好了（入口显示"已下载"用）
    func hasCompleted(song: Song) -> Bool {
        items.contains { $0.song.id == song.id && $0.status == .completed }
    }

    /// 这首歌是否正在下（同一首歌不重复入库，避免两条任务抢同一个文件名）
    func activeItem(for song: Song) -> DownloadItem? {
        items.first {
            $0.song.id == song.id && ($0.status == .downloading || $0.status == .pending)
        }
    }

    /// 已下好的本地文件路径（播放引擎优先播它：离线可用、省一次解析）
    ///
    /// 第四十轮补丁 4：记录里的绝对路径可能失效（旧版 `Music` 目录被搬走/被用户删掉、
    /// 文件夹被移动过）。这时按"文件名 → 同基名"在 `Download/Music` 里找一次，
    /// 找到就把记录改过来——否则会出现"列表里显示已下载，点播放却只有封面"的现象。
    func localFileURL(for song: Song) -> URL? {
        // 缓存命中：不再线性扫 items、不再 stat 磁盘（下载页每行都要问一次）
        if let cached = localFileCache[song.id] {
            guard !cached.isEmpty else { return nil }
            let url = URL(fileURLWithPath: cached)
            DownloadLocation.openScope(forFile: url)
            return url
        }
        guard let idx = items.firstIndex(where: { $0.song.id == song.id && $0.status == .completed }) else {
            localFileCache[song.id] = ""
            return nil
        }
        if let path = items[idx].localPath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            // 文件可能在用户自选的外部目录里：每次取用前确认作用域开着（同目录只开一次）
            DownloadLocation.openScope(forFile: url)
            localFileCache[song.id] = path
            return url
        }
        guard let found = findExistingAudioFile(for: items[idx]) else {
            localFileCache[song.id] = ""
            return nil
        }
        DownloadLocation.openScope(forFile: found)
        items[idx].localPath = found.path
        localFileCache[song.id] = found.path
        persist()
        return found
    }

    /// 按记录在 `Download/Music`（以及旧版 `Music`）里找回音频文件
    private func findExistingAudioFile(for item: DownloadItem) -> URL? {
        let candidates = [DownloadLocation.musicDirectory(),
                          DownloadLocation.documentsDirectory().appendingPathComponent("Music", isDirectory: true)]
        let base = (item.fileName as NSString).deletingPathExtension
        for dir in candidates {
            let exact = dir.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: exact.path) { return exact }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            if let hit = files.first(where: { $0.deletingPathExtension().lastPathComponent == base }) {
                return hit
            }
        }
        return nil
    }

    /// 离线歌词（播放页在无网络时调用）：已下载完成 + 旁车 .lrc 存在才返回。
    ///
    /// 只读旁车、不读内嵌标签：旁车是我们自己写的 UTF-8 LRC，解析口径完全可控；
    /// 内嵌标签是"拷走也带着"的保险，不是 App 内播放的首选来源。
    /// 第四十轮补丁 3 起旁车在 `…/Lyrics`；旧版下载的旁车在音频同目录（`readLyrics` 里自带回退）。
    /// 只在主线程调用（`items` 只在主线程改）。
    func localLyrics(for song: Song) -> [LyricLine]? {
        guard let audio = localFileURL(for: song) else { return nil }
        return DownloadCompanion.readLyrics(from: audio, in: [lyricsDirectory])
    }

    /// 离线封面（列表/播放页显示本地封面用）：已下载完成 + 旁车 .jpg 存在才返回。
    /// 第四十轮补丁 3 起封面在 `…/Cover`；旧版仍在音频同目录（`readCover` 里自带回退）。
    /// 只在主线程调用（`items` 只在主线程改）。
    func localCoverURL(for song: Song) -> URL? {
        if let cached = localCoverCache[song.id] {
            guard !cached.isEmpty else { return nil }
            return URL(fileURLWithPath: cached)
        }
        guard let audio = localFileURL(for: song) else {
            localCoverCache[song.id] = ""
            return nil
        }
        let base = DownloadCompanion.baseName(for: audio)
        let candidates = [DownloadCompanion.coverURL(in: coverDirectory, baseName: base),
                          DownloadCompanion.legacyCoverURL(for: audio)]
        guard let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            localCoverCache[song.id] = ""
            return nil
        }
        localCoverCache[song.id] = hit.path
        return hit
    }

    /// 已下载完成的歌（按下载顺序）：从下载页点一首时，**整列**就是播放队列。
    /// 第五轮老板反馈 ②："播放列表只有一首歌，列表循环也来回只放这一首"——根因就是从列表点歌时
    /// 只把点中的那一首塞进队列。只在主线程调用（`items` 只在主线程改）。
    var completedSongs: [Song] {
        items.filter { $0.status == .completed }.map(\.song)
    }

    /// 取消下载
    func cancel(itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = items[idx]
        if let tid = taskIdentifier(forItem: itemID) {
            foregroundSession.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == tid })?.cancel()
            }
            backgroundSession.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == tid })?.cancel()
            }
        }
        item.status = .cancelled
        appendOrUpdate(item)
        persist()
    }

    /// 删除下载记录（可选删除文件）
    func remove(itemID: UUID, deleteFile: Bool = true) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = items[idx]
        // 先叫停在飞的补料任务：否则它可能在我们删完文件之后才写旁车，
        // 留下"音频没了、歌词封面还在"的孤儿文件（老板要的是一一对应地删）。
        cancelCompanion(itemID)
        if deleteFile, let path = item.localPath {
            let audio = URL(fileURLWithPath: path)
            // 自选外部目录：删之前同样要确认作用域在开着，否则删除会静默失败
            DownloadLocation.openScope(forFile: audio)
            // 一一对应：删音频之前先把它的 .lrc / .jpg 一起删掉（新位置 + 旧版同目录都清）。
            // 旁车只依赖"音频基名"推导，不需要额外的清单文件，所以"谁被删、谁跟着删"永远对齐。
            DownloadCompanion.removeSidecars(audio: audio,
                                             lyricsDirectory: lyricsDirectory,
                                             coverDirectory: coverDirectory)
            try? FileManager.default.removeItem(at: audio)
        }
        items.remove(at: idx)
        // 删除立刻落盘（节流窗口里丢一次删除，重启后歌会"复活"）
        flushPersist()
    }

    /// 重试失败/取消的下载（沿用原条目 id，保留下载记录上下文）
    func retry(itemID: UUID, useBackground: Bool = true) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = items[idx]
        var newItem = DownloadItem(id: itemID, song: item.song, streamURL: item.streamURL,
                                   backendName: item.backendName, quality: item.quality,
                                   fileName: item.fileName, status: .pending,
                                   totalBytes: item.expectedBytes ?? item.totalBytes,
                                   expectedBytes: item.expectedBytes)
        guard let url = URL(string: item.streamURL) else {
            newItem.status = .failed
            newItem.errorMessage = "无效 URL"
            appendOrUpdate(newItem)
            return
        }
        let session: URLSession = useBackground ? backgroundSession : foregroundSession
        let task = session.downloadTask(with: URLRequest.download(url))
        newItem.status = .downloading
        appendOrUpdate(newItem)
        register(task, id: itemID, fileName: item.fileName)
        task.resume()
    }

    // MARK: - 歌词/封面补料（老板反馈 ⑧）

    /// 下载成功后异步补料：取词 → 取封面 → 写旁车 → 能内嵌就内嵌 → 把结果写回条目。
    ///
    /// 为什么用 detached 后台任务：补料包含网络请求（歌词接口 + 封面 CDN）和一次可能的
    /// 音频文件重写，放主线程会把 UI 卡住；`.utility` 让它不去抢下载/播放的 CPU。
    /// 为什么每个 item 只跑一次：`companionRunning` 去重；`finish` 成功后理论上只调一次，
    /// 但重试/极端时序下仍要防止同一 item 两条补料任务互相覆盖。
    private func startCompanionFill(itemID: UUID, song: Song, audioURL: URL) {
        companionLock.lock()
        if companionRunning.contains(itemID) || companionCancelled.contains(itemID) {
            companionLock.unlock()
            return
        }
        companionRunning.insert(itemID)
        companionLock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.fillCompanion(itemID: itemID, song: song, audioURL: audioURL)
            self.finishCompanionBookkeeping(itemID)
        }
    }

    /// 补料主流程。任何一步失败都只是"少了歌词/封面"（或者没内嵌成功），
    /// 绝不能反过来影响"歌已经下好、能播"这件事。
    private func fillCompanion(itemID: UUID, song: Song, audioURL: URL) async {
        // 条目还在（没被删）才有补料的必要
        guard await isCompletedDownload(itemID) else { return }

        // ① 歌词：QRC/KRC 的逐字时间不落 LRC，落盘只保留行级时间（离线够看，见 lrcText 注释）
        var lines: [LyricLine] = []
        if let result = await LyricsService.shared.fetch(song) {
            lines = result.lines
        }
        if isCompanionCancelled(itemID) { return }
        let lyricsText = lines.isEmpty ? nil : DownloadCompanion.lrcText(
            from: lines, title: song.name, artist: song.singer, durationSec: song.durationSec)

        // ② 封面：只认 song.picURL；下不到就当没有封面（不拿占位图冒充真封面）
        let cover = await fetchCoverData(for: song)
        if isCompanionCancelled(itemID) { return }

        // 2026-11-21：封面先压到 600px 再落盘/内嵌。
        // 原图（1500–3000px）写进 Cover/ 后，每次列表解码就是 9–36MB —— 那是 jetsam 的主因之一。
        let coverData: Data? = cover.map {
            CoverImageCache.compressedCoverData($0.data, maxPixel: 600)
        }

        // 写盘前再确认一次：歌词接口 + 封面下载可能花掉几秒，用户完全可能已经删了这条下载
        guard await isCompletedDownload(itemID) else { return }

        // ③ 旁车：任何容器都能用，是离线播放读取的第一来源。
        //    第四十轮补丁 3：歌词进 `…/Lyrics`、封面进 `…/Cover`，和音频分开摆。
        var sidecars = DownloadCompanion.writeSidecars(audio: audioURL,
                                                       lyricsText: lyricsText,
                                                       coverData: coverData,
                                                       lyricsDirectory: lyricsDirectory,
                                                       coverDirectory: coverDirectory)

        // ④ 内嵌：只有 m4a/mp3 有可靠写法；失败时 AudioTagEmbedder 内部保证保留原文件
        var embedded = false
        if lyricsText != nil || cover != nil,
           DownloadCompanion.canEmbed(extension: audioURL.pathExtension) {
            switch audioURL.pathExtension.lowercased() {
            case "m4a", "mp4":
                embedded = await AudioTagEmbedder.embedM4A(
                    fileURL: audioURL, title: song.name, artist: song.singer,
                    album: song.album, coverData: coverData, lyrics: lyricsText ?? "")
            case "mp3":
                embedded = await AudioTagEmbedder.embedMP3(
                    fileURL: audioURL, title: song.name, artist: song.singer,
                    album: song.album, coverData: coverData,
                    coverMime: cover?.mime ?? "image/jpeg", lyrics: lyricsText ?? "")
            default:
                embedded = false
            }
        }
        sidecars.embedded = embedded

        // ⑤ 回填说明。内嵌会重写音频文件，写完再确认条目还在：别给已删除的条目写说明。
        let note = Self.companionsNote(lyricsText: lyricsText, coverData: coverData,
                                       sidecars: sidecars)
        guard await isCompletedDownload(itemID) else { return }
        await MainActor.run {
            guard let idx = self.items.firstIndex(where: { $0.id == itemID }),
                  self.items[idx].status == .completed else { return }
            if self.items[idx].companionsNote != note {
                self.items[idx].companionsNote = note
                self.persist()
            }
        }
    }

    /// 清理补料状态（成功/失败/被取消都要清，否则这个 UUID 永远占着 running）
    private func finishCompanionBookkeeping(_ itemID: UUID) {
        companionLock.lock()
        companionRunning.remove(itemID)
        companionCancelled.remove(itemID)
        companionLock.unlock()
    }

    private func isCompanionCancelled(_ itemID: UUID) -> Bool {
        companionLock.lock()
        defer { companionLock.unlock() }
        return companionCancelled.contains(itemID)
    }

    /// 删除下载时叫停在飞补料。
    /// 只给**真在跑**的任务打标记，否则会给一个永远不会被清理的 UUID 留垃圾。
    private func cancelCompanion(_ itemID: UUID) {
        companionLock.lock()
        if companionRunning.contains(itemID) { companionCancelled.insert(itemID) }
        companionLock.unlock()
    }

    /// 条目是否还处于"已下载完成"。
    /// `items` 只在主线程改，所以补料任务读它必须切主线程拿一份快照，不能在后台线程裸读。
    private func isCompletedDownload(_ itemID: UUID) async -> Bool {
        await MainActor.run {
            self.items.contains { $0.id == itemID && $0.status == .completed }
        }
    }

    /// 封面下载结果：字节 + MIME（MIME 只给 mp3 的 APIC 帧用）
    private struct CoverPayload {
        let data: Data
        let mime: String
    }

    /// 直接下 `song.picURL`（不走 CoverResolver 的 QQ 兜底：下载完成后不再为了封面多搜一次接口）。
    /// 无 picURL / 超时 / 非 2xx / 空 body 全部返回 nil —— 结果只是"没有封面"，不影响别的。
    private func fetchCoverData(for song: Song, timeout: TimeInterval = 20) async -> CoverPayload? {
        guard let raw = song.picURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // 与音频下载同一套头：部分 CDN 不带 Referer 会直接 403
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard !data.isEmpty else { return nil }
            return CoverPayload(data: data, mime: Self.imageMimeType(data, response: response))
        } catch {
            return nil
        }
    }

    /// 封面 MIME：优先用响应头；服务端不给/给错时按文件头猜。
    /// 只影响 mp3 APIC 的 MIME 字段（旁车文件名固定 .jpg，播放端按内容解码）。
    private static func imageMimeType(_ data: Data, response: URLResponse?) -> String {
        if let mime = response?.mimeType?.lowercased(), mime.hasPrefix("image/") { return mime }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.count >= 12, data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(data[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return "image/jpeg"
    }

    /// 一句能放下载列表的说明（老板要能看出"词和图到底有没有跟着歌走"）
    private static func companionsNote(lyricsText: String?, coverData: Data?,
                                       sidecars: DownloadCompanion.Sidecars) -> String? {
        let hasLyrics = !(lyricsText ?? "").isEmpty
        let hasCover = !(coverData ?? Data()).isEmpty
        guard hasLyrics || hasCover else { return nil }
        if sidecars.embedded {
            if hasLyrics && hasCover { return "已内嵌歌词+封面" }
            return hasLyrics ? "已内嵌歌词" : "已内嵌封面"
        }
        let savedLyrics = sidecars.lyricsURL != nil
        let savedCover = sidecars.coverURL != nil
        guard savedLyrics || savedCover else { return nil }
        if savedLyrics && savedCover { return "歌词封面已存旁车" }
        return savedLyrics ? "歌词已存旁车" : "封面已存旁车"
    }

    // MARK: - 持久化

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: recordsURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }
        items = saved
    }

    /// 落盘：JSON 编码 + 写盘都丢到后台串行队列（2026-11-21 老板："导入的时候会卡一下"）
    ///
    /// 原来每次条目变化都在主线程 `JSONEncoder().encode(items)` + 原子写整个文件；
    /// 导入 100 首就是 100 次全量编码 + 100 次磁盘写，列表越大越卡。
    private let persistQueue = DispatchQueue(label: "com.jz.downloads.persist", qos: .utility)
    private var lastPersistAt = Date.distantPast
    private var persistScheduled = false

    private func persist() {
        // 节流：0.6 秒内只写一次（第一次立即写，之后合并成一次尾写）
        let now = Date()
        let since = now.timeIntervalSince(lastPersistAt)
        if since < 0.6 || persistScheduled {
            guard !persistScheduled else { return }
            persistScheduled = true
            let wait = max(0.05, 0.6 - since)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.persistScheduled = false
                self.lastPersistAt = Date()
                self.writeRecords()
            }
            return
        }
        lastPersistAt = now
        writeRecords()
    }

    /// 立刻落盘（进后台 / 退出前 / 用户删条目时调用，别让节流窗口吞掉一次删除）
    func flushPersist() {
        persistScheduled = false
        lastPersistAt = Date()
        writeRecords()
    }

    private func writeRecords() {
        let snapshot = items          // 主线程取快照，编码与写盘在后台
        let url = recordsURL
        persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func appendOrUpdate(_ item: DownloadItem) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx] = item
            } else {
                self.items.append(item)
            }
            self.persist()
        }
    }

    private static func extensionForFormat(_ format: String, url: String) -> String {
        let f = format.lowercased()
        if f.contains("flac") { return "flac" }
        if f.contains("m4a") || f.contains("aac") || f.contains("m4b") { return "m4a" }
        if f.contains("ogg") { return "ogg" }
        if f.contains("mp3") { return "mp3" }
        if f.contains("wav") { return "wav" }
        if let path = URL(string: url)?.pathExtension, !path.isEmpty, path.count <= 5 {
            return path
        }
        return "mp3"
    }
}

// MARK: - 请求构造

private extension URLRequest {
    /// 下载与重试共用同一套头：缺 Referer 时部分 CDN 直接 403（这也是"下载失败"的一类来源）
    static func download(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        return request
    }
}

// MARK: - URLSessionDownloadDelegate
extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = itemID(for: downloadTask.taskIdentifier) else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            var item = self.items[idx]
            item.progress = min(progress, 1.0)
            item.receivedBytes = totalBytesWritten
            // 服务端不给 Content-Length 时这里是 -1，别把预期体积冲掉（进度条分母要靠它）
            if totalBytesExpectedToWrite > 0 {
                item.totalBytes = totalBytesExpectedToWrite
            }
            self.items[idx] = item
            self.persist()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tid = downloadTask.taskIdentifier
        guard let id = itemID(for: tid) else { return }
        let plannedName = fileName(for: tid)
        unregister(tid)

        // ⚠️ 必须在本回调里**同步**搬走：location 是系统给的临时文件，
        // 回调一返回就可能被删（上一版丢进 main.async 再搬，于是"下载失败"）
        let dir = musicDirectory
        let target = dir.appendingPathComponent(plannedName ?? "download-\(id.uuidString).m4a")
        var moved = false
        var moveError: String?
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            moved = true
        } catch {
            moveError = error.localizedDescription
        }

        // 落盘后的实测（容器 + 真实码率）：只读前 16 字节，不做整文件读取。
        // 放到主线程做是因为要读 `items` 里的时长（delegate 队列不碰 items，避免数据竞争）。
        var actualSize: Int64 = 0
        if moved,
           let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
           let size = attrs[.size] as? Int64 {
            actualSize = size
        }
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            let duration = self.items[idx].song.durationSec
            let verdict = moved
                ? DownloadGuard.verdict(prefix: Self.readPrefix(of: target, count: 16),
                                        size: actualSize, durationSec: duration)
                : nil
            self.finish(itemID: id, moved: moved, target: target,
                        actualSize: actualSize, moveError: moveError, verdict: verdict)
        }
    }

    /// 收尾：体积防线 + 档位实测 + 改名 + 状态更新
    private func finish(itemID id: UUID, moved: Bool, target: URL, actualSize: Int64,
                        moveError: String?, verdict: DownloadGuard.Verdict?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[idx]

        guard moved else {
            item.status = .failed
            item.progress = 0
            item.errorMessage = "文件写入失败：\(moveError ?? "未知原因")"
            items[idx] = item
            persist()
            return
        }

        item.totalBytes = actualSize
        let expected = item.expectedBytes ?? 0
        guard DownloadGuard.isComplete(actual: actualSize, expected: expected) else {
            try? FileManager.default.removeItem(at: target)
            item.localPath = nil
            item.status = .failed
            item.progress = 0
            item.errorMessage = "文件不完整（\(DownloadGuard.sizeText(actualSize)) / 预期 \(DownloadGuard.sizeText(expected))），已删除"
            items[idx] = item
            persist()
            return
        }

        // 档位以实测为准：容器 / 码率与记录不一致时改回来（"标着无损其实是 320k"就死在这一步）
        var finalURL = target
        if let verdict {
            if verdict.extensionName != finalURL.pathExtension.lowercased() {
                let renamed = finalURL.deletingPathExtension()
                    .appendingPathExtension(verdict.extensionName)
                if (try? FileManager.default.moveItem(at: finalURL, to: renamed)) != nil {
                    finalURL = renamed
                }
            }
            if verdict.quality != item.quality {
                item.actualNote = "实测 \(verdict.container.uppercased()) · \(verdict.kbps) kbps（\(verdict.quality.displayName)），与标注的 \(item.quality.displayName) 不一致"
                item.quality = verdict.quality
            }
        }

        item.fileName = finalURL.lastPathComponent
        item.localPath = finalURL.path
        item.status = .completed
        item.progress = 1.0
        item.finishedAt = Date()
        item.errorMessage = nil
        items[idx] = item
        persist()
        notifyCompletion(item)
        // 音频落盘、记录落库之后才补词和图（老板反馈 ⑧）：
        // 补料是纯附加值，异步做，失败绝不影响"歌已经能播"这件事。
        startCompanionFill(itemID: id, song: item.song, audioURL: finalURL)
    }

    private static func readPrefix(of url: URL, count: Int) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: count)
        return [UInt8](data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = itemID(for: task.taskIdentifier) else { return }
        if let error = error {
            unregister(task.taskIdentifier)
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                var item = self.items[idx]
                if item.status != .cancelled {
                    item.status = .failed
                    item.errorMessage = Self.friendlyError(error)
                }
                self.items[idx] = item
                self.persist()
            }
        }
    }

    /// 把 `NSURLError` 翻成一句人话（"下载失败"三个字对用户没有任何帮助）
    static func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "网络未连接（NSURLErrorNotConnectedToInternet）"
        case NSURLErrorTimedOut: return "下载超时，换 Wi-Fi 或稍后重试"
        case NSURLErrorNetworkConnectionLost: return "网络中断，下载没完成"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "连不上音源服务器"
        case NSURLErrorBadServerResponse: return "音源服务器返回错误（可能已失效或被拒绝）"
        case NSURLErrorHTTPTooManyRedirects: return "音源地址跳转异常"
        default: return "\(ns.localizedDescription)（\(ns.code)）"
        }
    }

    // 后台会话完成后的系统回调
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundTaskCount = 0
            AppDelegate.completeBackgroundSession(for: session.configuration.identifier ?? "")
        }
    }

    private func notifyCompletion(_ item: DownloadItem) {
        guard item.status == .completed else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "下载完成"
            content.body = "\(item.song.name) - \(item.song.singer)"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - App 委托（后台下载完成回调桥接）
/// SwiftUI 生命周期通过 UIApplicationDelegateAdaptor 接入本类。
/// 注意：SwiftUI 会自行实例化一个委托对象，因此后台回调处理器用静态存储，
/// 保证 DownloadManager 与系统委托实例访问同一份数据。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 后台会话完成的系统回调（静态，跨实例共享）
    private static var backgroundCompletionHandlers: [String: () -> Void] = [:]

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashReporter.install()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 下载记录是节流落盘的：进后台先强行写一次，别让系统随时收走进程时丢进度
        DownloadManager.shared.flushPersist()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 用户/系统正在收掉 App：把"音乐软件留在系统里的东西"一次性清干净。
        // `assumeIsolated`：UIKit 一定在主线程调 willTerminate，而这里要碰的
        // NowPlayingCenter 是 @MainActor —— 同步执行，不排进队列
        // （排进队列的话进程可能已经没了，清理根本不会跑）。
        DownloadManager.shared.flushPersist()
        MainActor.assumeIsolated {
            NowPlayingCenter.shared.teardown()
        }
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppDelegate.backgroundCompletionHandlers[identifier] = completionHandler
        // 确保后台会话存在（让 URLSession 继续处理）
        _ = DownloadManager.shared
    }

    // MARK: 「用 JZ 音乐打开」/ 共享到本 App 的音频（第三条导入入口）

    /// scene-based 的 App（SwiftUI 就是）里系统多半走场景回调，`application(_:open:)` 未必会来
    /// —— 所以根视图上还有一个 `.onOpenURL`（见 `JZMusicHelperApp`），两条都汇到
    /// `DownloadManager.enqueueOpenIn`（0.4s 去重合并，不会导两次）。
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        DownloadManager.enqueueOpenIn([url])
        return true
    }

    /// 由 DownloadManager.urlSessionDidFinishEvents 调用，执行系统要求的收尾回调。
    static func completeBackgroundSession(for identifier: String) {
        backgroundCompletionHandlers[identifier]?()
        backgroundCompletionHandlers[identifier] = nil
    }
}


// MARK: - 崩溃 / 内存取证（2026-11-21）
//
// 老板报："播放中翻搜索结果，约 90–100 秒后 App 没有任何报错就回桌面。"
// 这种死法只有三种：内存被杀（jetsam）、看门狗超时、信号崩溃。三者都**不会**在 App 里留下痕迹，
// 所以先加最轻的取证：
//   · 每 10 秒记一条内存曲线（resident MB + 封面缓存张数 + 收藏/下载条数）→ `诊断/life.log`
//   · 记录启动 / 前后台切换（如果最后一条是"进后台后再没起来"，且内存接近阈值 → jetsam）
//   · 未捕获异常（NSException）写 `诊断/crash-<时间>.log`
// 没加信号处理器是刻意的：Swift 的越界/断言是 SIGTRAP，在信号处理里做 Swift 字符串拼接
// 有死锁风险（malloc 锁），反而会让问题更难查。内存曲线足以区分 jetsam 与 trap。
enum CrashReporter {

    static let folderName = "诊断"

    static func directory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        _ = directory()

        // C 函数指针不能是"捕获上下文"的闭包 —— 必须用文件级函数（见文件末尾）
        NSSetUncaughtExceptionHandler(jzUncaughtExceptionHandler)

        log("app launched · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // SIGABRT 的具体断言文本只写在 stderr（CoreAudio/AVFoundation 的 Assertion failed 都走这里）。
        // 把它重定向到 `诊断/stderr.log`，下次复现就能看到原文。
        let errPath = directory().appendingPathComponent("stderr.log").path
        if let cPath = errPath.cString(using: .utf8) {
            freopen(cPath, "a", stderr)
        }

        // 信号崩溃取证：预创建 4 个文件各留一个 fd，handler 里只 write 一个字节
        // （Swift 的越界/断言是 SIGTRAP，NSException 收不到 —— life.log 已证明不是内存问题）
        for (sig, name) in [(SIGTRAP, "signal-TRAP.log"), (SIGSEGV, "signal-SEGV.log"),
                            (SIGABRT, "signal-ABRT.log"), (SIGBUS, "signal-BUS.log")] {
            let url = directory().appendingPathComponent(name)
            try? Data().write(to: url, options: .atomic)
            let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return open(path, O_WRONLY | O_APPEND)
            }
            switch sig {
            case SIGTRAP: gFDtrap = fd
            case SIGSEGV: gFDsegv = fd
            case SIGABRT: gFDabrt = fd
            case SIGBUS: gFDbus = fd
            default: break
            }
            signal(sig, jzSignalHandler)
        }
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                log(name == UIApplication.didEnterBackgroundNotification ? "→ background" : "→ foreground")
            }
        }
        Task { @MainActor in
            while true {
                log("mem \(String(format: "%.0f", residentMB()))MB · covers \(coverCount())")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    static func log(_ line: String) {
        append("\(stamp()) \(line)\n", to: "life.log")
    }

    // MARK: - trace 落盘（播放动作的"最后遗言"）

    private static let traceQueue = DispatchQueue(label: "com.jz.diagnostics.trace", qos: .utility)

    /// 导入时被拒/被改名的文件：记"文件名 + 前 16 字节"，用来判断对方 App 的容器格式
    /// （例如 Light Player 的 `.lexClip` —— 是改名 m4a 还是加密容器，一看便知）
    static func logImportSniff(_ name: String, head: Data, verdict: String) {
        let hex = head.map { String(format: "%02x", $0) }.joined(separator: " ")
        append("\(stamp()) \(name) | \(hex) | \(verdict)\n", to: "import-sniff.log")
    }

    /// 导入链路的分步日志（`诊断/import.log`）：选择器进出、回调、扫描、逐首结果。
    ///
    /// 为什么单开一个文件：老板这台机器上系统选择器的「打开」**按下去不回调**
    /// （2026-11-19 的「保存位置」、2026-11-21 的三次导入修都是同一症状）。
    /// 只看 UI 无法区分"按钮没反应 / 回调没来 / 回调来了但导入卡住"，
    /// 落一份分步日志，下一次复现就能一眼定位死在哪一步。
    static func logImport(_ line: String) {
        append("\(stamp()) \(line)\n", to: "import.log")
    }

    /// 把 PlaybackTrace 的每一行写到 `诊断/trace.log`（崩了内存里那 200 条会一起消失）
    static func trace(_ line: String) {
        let url = directory().appendingPathComponent("trace.log")
        traceQueue.async {
            let text = line + "\n"
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                if let size = try? handle.offsetInFile, size > 200_000 {
                    try? FileManager.default.removeItem(at: url)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - 内部

    fileprivate static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    fileprivate static func append(_ text: String, to name: String) {
        let url = directory().appendingPathComponent(name)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        // life.log 超过 200KB 就轮转一次，别无限长
        if name == "life.log",
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    fileprivate static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }

    fileprivate static func coverCount() -> Int {
        // 只为看一眼缓存规模（封面缓存 NSCache 不暴露数量的间接指标：磁盘也不合适）→ 用下载条数代替
        MainActor.assumeIsolated { DownloadManager.shared.items.filter { $0.status == .completed }.count }
    }
}

// MARK: - 本地音乐导入（2026-11-21 老板需求）
//
// 老板："批量导入已经下载好的歌曲文件；导入的音乐文件可以根据音乐去找封面、歌词，
//        下载到对应的文件夹中；专辑等信息要显示无误；导入后异步进行歌词封面专辑匹配。"
//
// 设计（与下载完全共用一套目录与基名约定）：
//   · 音频 → `Download/Music/<歌手 - 歌名>.<ext>`
//   · 歌词 → `Download/Lyrics/<同基名>.lrc`（由 `startCompanionFill` 后台补）
//   · 封面 → `Download/Cover/<同基名>.jpg`（内嵌封面先抽出来写一份，保证离线就有图）
//   · 标签里有的信息一律以标签为准；缺的才用文件名推，绝不瞎填
//   · 同一个文件（字节 SHA-256 相同）直接跳过；同一首（同一条录音）只留音质更高的一条
extension DownloadManager {

    /// 一次导入的结果（给 UI 展示，不静默吞失败）
    struct ImportReport {
        var added = 0
        var duplicateFiles = 0
        var duplicateSongs = 0
        var unsupported: [String] = []
        var failed: [String] = []
        /// 失败原因（与 `failed` 对得上；弹窗里直接告诉老板"为什么失败"）
        var failureReasons: [String] = []
        /// 压根没取到的（系统清理了选择器的临时副本 / 抢取超时）：与 `failed` 分开算
        var missed = 0
        var missedReason: String?
        var addedNames: [String] = []

        var summary: String {
            var parts: [String] = []
            if added > 0 { parts.append("导入 \(added) 首") }
            if duplicateFiles > 0 { parts.append("跳过同文件 \(duplicateFiles) 个") }
            if duplicateSongs > 0 {
                parts.append("跳过重复歌曲 \(duplicateSongs) 首（已有更好的音质）")
            }
            if !unsupported.isEmpty { parts.append("不支持 \(unsupported.count) 个") }
            if !failed.isEmpty { parts.append("读取失败 \(failed.count) 个") }
            if missed > 0 { parts.append(ImportGrabRules.missedSummary(missed)) }
            return parts.isEmpty ? "没有可导入的音频文件" : parts.joined(separator: " · ")
        }

        var detail: String {
            var lines: [String] = [summary]
            if !unsupported.isEmpty {
                let extText = ImportRules.extensionSummary(unsupported)
                lines.append("不支持（\(extText)）\(unsupported.count) 个："
                             + nameList(unsupported))
                if ImportRules.hasOnlyUndecodableExtensions(unsupported) {
                    lines.append("这些格式 iOS 系统本身没有解码器（ape / wma / dsf / ogg…），导进来也是无声，所以直接跳过了。")
                } else {
                    lines.append("认不出这些文件的容器（也可能是别的 App 的加密包，例如 Light Player 的 .lexClip）。")
                }
            }
            if !failed.isEmpty {
                lines.append("读取失败 \(failed.count) 个：" + nameList(failed))
                let reasons = Set(failureReasons).filter { !$0.isEmpty }.sorted()
                if !reasons.isEmpty { lines.append("原因：" + reasons.joined(separator: "；")) }
            }
            if missed > 0, let why = missedReason, !why.isEmpty {
                lines.append("没拿到 \(missed) 个。\(why)")
            }
            return lines.joined(separator: "\n")
        }

        /// 最多列 6 个名字，多的用"…（还有 N 个）"收尾（别让弹窗长到看不完）
        private func nameList(_ names: [String]) -> String {
            let head = names.prefix(6).joined(separator: "、")
            guard names.count > 6 else { return head }
            return head + " …（还有 \(names.count - 6) 个）"
        }
    }

    /// 批量导入（文件或文件夹里筛出来的音频 URL）
    ///
    /// **必须从后台执行**（`Task.detached`）：这里面有"读完整个文件算 SHA-256"和"复制整个文件"，
    /// 2026-11-21 的 bug 就是它在主线程上跑 —— 全选几十首 95MB 的歌把主线程堵死，
    /// 系统文件选择器的「打开」回调没人处理，表现为"点多少次都没反应"。
    func importAudioFiles(_ urls: [URL]) async -> ImportReport {
        var report = ImportReport()
        await MainActor.run { self.lastImportReport = nil }
        CrashReporter.logImport("import: 开始，收到 \(urls.count) 个选中项")
        let musicDir = musicDirectory
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        // 起点快照：不跨线程读 `items`
        let existing: [DownloadItem] = await MainActor.run { self.items }
        var taken = Set(existing.compactMap {
            $0.fileName.isEmpty ? nil : ($0.fileName as NSString).deletingPathExtension
        })
        if let onDisk = try? FileManager.default.contentsOfDirectory(
            at: musicDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in onDisk { taken.insert(url.deletingPathExtension().lastPathComponent) }
        }
        var known = existing

        // 暂存目录：**必须在 Documents 下**。系统的 tmp 会在 App 运行约 1 分钟后被清掉，
        // 那正是 2026-11-21 全选 664 首、第 59 秒起 245 首全部"文件不存在"的根因。
        let staging = Self.importStagingDirectory()
        Self.resetImportStaging(staging)
        defer { Self.resetImportStaging(staging) }

        // ① 展开成文件清单（文件夹递归）。作用域只在这一小段开着：开一次、抄一次、马上关，
        //    绝不把几百个沙盒令牌攥在手里（旧实现 for 循环里 start 了从不 stop）。
        var expanded: [URL] = []
        for picked in urls {
            let scope = picked.startAccessingSecurityScopedResource()
            expanded.append(contentsOf: Self.expandImportTargets(picked))
            if scope { picked.stopAccessingSecurityScopedResource() }
        }
        let totalFiles = max(1, expanded.count)
        CrashReporter.logImport("import: 展开成 \(expanded.count) 个文件")

        // ② 抢：先把文件抄进自己的暂存目录，再谈解析。
        //    同卷 APFS 克隆下这一步是元数据操作（几百个文件几秒），27 GB 也不会真的搬一遍。
        struct Grabbed {
            var original: String
            var ext: String
            var staged: URL
        }
        var grabbed: [Grabbed] = []
        let grabStart = Date()
        var consecutiveMissing = 0
        var stoppedEarly = false

        for (index, src) in expanded.enumerated() {
            let cancelled: Bool = await MainActor.run { self.importCancelled }
            if cancelled { stoppedEarly = true; break }

            let elapsed = Date().timeIntervalSince(grabStart)
            if ImportGrabRules.shouldStopGrabbing(elapsed: elapsed, consecutiveMissing: consecutiveMissing) {
                stoppedEarly = true
                CrashReporter.logImport(
                    "import: 停止抢取 · 已用 \(Int(elapsed))s · 连续不存在 \(consecutiveMissing) 个 · 已抢 \(grabbed.count)/\(expanded.count)")
                break
            }

            await MainActor.run {
                self.importProgress = ImportProgress(phase: .grabbing, done: index, total: totalFiles,
                                                     name: src.lastPathComponent)
            }

            let scope = src.startAccessingSecurityScopedResource()
            defer { if scope { src.stopAccessingSecurityScopedResource() } }

            var ext = src.pathExtension.lowercased()
            // 未知扩展名：按**文件内容**嗅探（对方 App 可能只是把 .flac/.m4a 改了名）
            if !ImportRules.isPlayable(extension: ext) {
                let head = Self.headBytes(of: src, count: 16) ?? Data()
                if let sniffed = Self.sniffAudioExtension(of: src) {
                    CrashReporter.logImportSniff(src.lastPathComponent, head: head,
                                                 verdict: "嗅探成 \(sniffed)，按该扩展名导入")
                    ext = sniffed
                } else {
                    CrashReporter.logImportSniff(src.lastPathComponent, head: head,
                                                 verdict: "不认识（判为不支持）")
                    CrashReporter.logImport("import: 不支持 · \(src.lastPathComponent)")
                    report.unsupported.append(src.lastPathComponent)
                    continue
                }
            }

            let dest = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                grabbed.append(Grabbed(original: src.lastPathComponent, ext: ext, staged: dest))
                consecutiveMissing = 0
                // 系统那份临时副本已经抄完 → 立刻删掉，别让它白占几十 GB
                if Self.isPickerStagingFile(src) { try? FileManager.default.removeItem(at: src) }
            } catch {
                let ns = error as NSError
                consecutiveMissing = ImportGrabRules.isMissingFile(domain: ns.domain, code: ns.code)
                    ? consecutiveMissing + 1 : 0
                CrashReporter.logImport(
                    "import: 抢取失败 · \(src.lastPathComponent) · \(ns.domain)/\(ns.code) · \(error.localizedDescription)")
            }
        }

        // 没抢到的 = 展开出来的 − 已抢的 − 明确"不支持"的（含中止后剩下的）
        let missedCount = max(0, expanded.count - grabbed.count - report.unsupported.count)
        report.missed = missedCount
        if missedCount > 0 {
            report.missedReason = ImportGrabRules.missedReason(count: missedCount, abortedEarly: stoppedEarly)
        }
        CrashReporter.logImport(
            "import: 抢完 \(grabbed.count) 个 · 不支持 \(report.unsupported.count) 个 · 没拿到 \(missedCount) 个 · 用时 \(Int(Date().timeIntervalSince(grabStart)))s")

        // ③ 解析 + 入库：全程只碰自己的暂存副本，系统再怎么清 tmp 都与我们无关
        var done = 0

        for g in grabbed {
            let cancelled: Bool = await MainActor.run { self.importCancelled }
            if cancelled { break }

            await MainActor.run {
                self.importProgress = ImportProgress(done: done, total: totalFiles, name: g.original)
            }

            // 读不出来时**带回真实原因**（旧版一律写成"读不出时长"，把 ENOENT 这种铁证藏了两轮）
            let outcome = await Self.localMetadata(of: g.staged, originalName: g.original)
            guard let meta = outcome.meta else {
                CrashReporter.logImport("import: 读取失败 · \(g.original) · \(outcome.failure)")
                report.failed.append(g.original)
                report.failureReasons.append(outcome.failure)
                done += 1
                continue
            }

            // ① 同一个文件（字节级）
            if known.contains(where: { $0.status == .completed && $0.contentHash == meta.hash }) {
                report.duplicateFiles += 1
                done += 1
                continue
            }

            let kbps: Int64 = meta.duration > 0
                ? Int64((Double(meta.bytes) * 8 / meta.duration / 1000).rounded()) : 0
            let container = (g.ext == "m4a" || g.ext == "m4b" || g.ext == "aac") ? "m4a" : g.ext
            let quality = QualityFacts.quality(container: container, kbps: kbps)

            let incoming = Song.make(platform: .local,
                                     platformID: "imp_" + String(meta.hash.prefix(12)),
                                     name: meta.title, singer: meta.artist, album: meta.album,
                                     duration: meta.duration, picURL: nil)

            // ② 同一首（同一条录音）→ 留音质更高的一条
            if let dup = known.first(where: {
                $0.status == .completed && FavoriteRules.isSameRecording($0.song, incoming)
            }) {
                if Self.kbps(of: dup) >= kbps {
                    report.duplicateSongs += 1
                    done += 1
                    continue
                }
                await MainActor.run { self.remove(itemID: dup.id, deleteFile: true) }
                known.removeAll { $0.id == dup.id }
            }

            // ③ 入库（基名唯一：旁车靠基名对应，撞了会串歌）。
            //    暂存目录与 Music 同卷 → `moveItem` 只是改名，不再多拷一份。
            let wantedBase: String = {
                if !meta.artist.isEmpty && !meta.title.isEmpty {
                    return "\(meta.artist) - \(meta.title)"
                }
                if !meta.title.isEmpty { return meta.title }
                return ImportRules.parseFileName(g.original).title
            }()
            let base = ImportRules.uniqueBaseName(wantedBase, taken: taken)
            let dest = musicDir.appendingPathComponent(base).appendingPathExtension(g.ext)
            var landed = false
            do {
                try FileManager.default.moveItem(at: g.staged, to: dest)
                landed = true
            } catch {
                // 自选保存位置可能在**别的卷**（iCloud 云盘 / 别的 App 的容器）：
                // 跨卷 move 会 EXDEV，退回"复制 + 删暂存"，行为与旧版一致。
                do {
                    try FileManager.default.copyItem(at: g.staged, to: dest)
                    try? FileManager.default.removeItem(at: g.staged)
                    landed = true
                } catch {
                    CrashReporter.logImport("import: 入库失败 · \(g.original) · \(error.localizedDescription)")
                    report.failed.append(g.original)
                    report.failureReasons.append("移入音乐文件夹失败（\(error.localizedDescription)）")
                }
            }
            guard landed else { done += 1; continue }
            taken.insert(base)

            // 内嵌封面先压到 600px 再写成旁车（原图解码一次就是 9–36MB）
            if let artwork = meta.artwork, !artwork.isEmpty {
                let compact = CoverImageCache.compressedCoverData(artwork, maxPixel: 600)
                _ = DownloadCompanion.writeSidecars(audio: dest, lyricsText: nil,
                                                    coverData: compact,
                                                    lyricsDirectory: lyricsDirectory,
                                                    coverDirectory: coverDirectory)
            }

            let id = UUID()
            let song = Song.make(platform: .local,
                                 platformID: "imp_" + String(meta.hash.prefix(12)),
                                 name: meta.title, singer: meta.artist, album: meta.album,
                                 duration: meta.duration, picURL: nil)
            let item = DownloadItem(id: id, song: song, streamURL: dest.absoluteString,
                                    backendName: "本地导入", quality: quality,
                                    fileName: dest.lastPathComponent, localPath: dest.path,
                                    status: .completed, progress: 1,
                                    receivedBytes: meta.bytes, totalBytes: meta.bytes,
                                    expectedBytes: meta.bytes,
                                    createdAt: Date(), finishedAt: Date(),
                                    actualNote: "导入 · \(kbps) kbps",
                                    companionsNote: meta.artwork != nil ? "封面已存旁车" : nil,
                                    origin: "import", contentHash: meta.hash)
            await MainActor.run {
                self.appendOrUpdate(item)
                self.startCompanionFill(itemID: id, song: song, audioURL: dest)
            }
            known.append(item)
            report.added += 1
            report.addedNames.append(song.name)
            done += 1
        }

        await MainActor.run {
            self.importProgress = nil
            self.lastImportReport = report.detail
        }
        CrashReporter.logImport("import: 结束 → \(report.summary)")
        return report
    }

    /// 进度（后台写、主线程读）；nil = 没在导入
    ///
    /// 分两段：`.grabbing` = 正把系统选择器的临时副本抄进自己的暂存目录（约 1 分钟窗口内要抢完），
    /// `.importing` = 在自己那份副本上算哈希/时长/入库。两段的计数各自从 0 开始，所以必须有
    /// `phase` 区分——否则界面上的 "3/664" 会突然跳回 "1/664"，看着像卡住了。
    struct ImportProgress: Equatable {
        enum Phase: Equatable {
            case grabbing
            case importing
        }
        var phase: Phase = .importing
        var done: Int
        var total: Int
        var name: String
    }

    /// 读文件前 N 字节（给导入嗅探日志用）
    static func headBytes(of url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? nil
    }

    /// 未知扩展名按文件头嗅探（只为"对方 App 改了后缀"的情况）
    static func sniffAudioExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = (try? handle.read(upToCount: 16)) ?? nil, !head.isEmpty else { return nil }
        switch StreamVerifier.sniffHead([UInt8](head)) {
        case "flac": return "flac"
        case "mp3": return "mp3"
        case "m4a": return "m4a"
        case "wav": return "wav"
        default: return nil
        }
    }

    /// 取消正在进行的导入（已导入的保留，剩下的不再处理）
    func cancelImport() { importCancelled = true }

    /// 扫 App 自己的 Documents（= 文件 App 里的「JZ 音乐」）里**所有**能导入的音频，递归。
    ///
    /// 给内置导入浏览器的「扫描全部子文件夹」用：这样老板把几十首丢进 `JZ 音乐`（或它下面
    /// 自己建的文件夹）之后，一次就能全导进来，不用一层层点进去。
    /// `诊断` 与隐藏目录跳过（那是崩溃取证和系统垃圾）。
    static func audioFilesInDocuments(limit: Int = 5000) -> [URL] {
        let root = DownloadLocation.documentsDirectory()
        let downloadedDir = DownloadLocation.musicDirectory().path
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        var folders = 0
        while let f = en.nextObject() as? URL {
            if out.count >= limit { break }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                folders += 1
                // `诊断` 是崩溃取证日志；`Download/Music` 里已经是我们自己下载/导入过的歌
                // （再扫一遍只会走"同文件跳过"，白算一遍哈希）→ 两处都不进
                if ImportRules.browserHides(name: f.lastPathComponent) || f.path == downloadedDir {
                    en.skipDescendants()
                }
                continue
            }
            if ImportRules.isPlayable(extension: f.pathExtension) { out.append(f) }
        }
        CrashReporter.logImport("browser: 全容器扫描 → \(out.count) 首 / \(folders) 个文件夹")
        return out
    }

    /// 别的 App「用 JZ 音乐打开」/「共享到 JZ 音乐」送来的文件（`AppDelegate.application(_:open:)`
    /// 或根视图的 `.onOpenURL`）。
    ///
    /// 这是导入的**第三条路**，完全不经过系统文件选择器：在「文件」App 或 LocalSend / 微信 /
    /// 隔空投送里选中歌 →「共享」→「JZ 音乐」。老板那台机器的选择器「打开」不回调，
    /// 这条路绕开了它，且文件是系统**就地**交给我们（`LSSupportsOpeningDocumentsInPlace` 已开）。
    static func importFromOpenIn(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
        CrashReporter.logImport("open-in: \(urls.count) 个 → \(names)")
        Task.detached(priority: .userInitiated) {
            _ = await DownloadManager.shared.importAudioFiles(urls)
        }
    }

    /// 系统逐条回调（一次一个文件），而且 `AppDelegate.application(_:open:)` 与 SwiftUI 的
    /// `.onOpenURL` **可能各来一次**。这里攒 0.4 秒、按路径去重后一次性导入：
    /// 否则批量 20 首会并发跑 20 次导入，互相抢基名集合、重复算哈希。
    private static var pendingOpenIn: [URL] = []
    private static var pendingOpenInWork: DispatchWorkItem?

    static func enqueueOpenIn(_ urls: [URL]) {
        for url in urls where !pendingOpenIn.contains(where: { $0.path == url.path }) {
            pendingOpenIn.append(url)
        }
        pendingOpenInWork?.cancel()
        let work = DispatchWorkItem {
            let batch = pendingOpenIn
            pendingOpenIn = []
            importFromOpenIn(batch)
        }
        pendingOpenInWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 把"用户选中的一个 URL"展开成一批音频文件（文件夹递归，最多 5000 个，防止误选根目录）
    static func expandImportTargets(_ picked: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [picked] }
        guard let en = FileManager.default.enumerator(
            at: picked, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        while let f = en.nextObject() as? URL {
            if out.count >= 5000 { break }
            if ImportRules.isPlayable(extension: f.pathExtension) { out.append(f) }
        }
        return out
    }

    /// 本机是否已有"同一首"的本地文件（下载前的询问用）
    func localDuplicate(of song: Song) -> DownloadItem? {
        items.first { $0.status == .completed && FavoriteRules.isSameRecording($0.song, song) }
    }

    /// 下载列表去重：同一首只留**音质更高**的一条（老板 2026-11-21 拍板）
    @discardableResult
    func dedupeSameRecording() -> (merged: Int, freedBytes: Int64) {
        var merged = 0
        var freed: Int64 = 0
        var kept: [DownloadItem] = []
        for item in items where item.status == .completed {
            if let hitIndex = kept.firstIndex(where: { FavoriteRules.isSameRecording($0.song, item.song) }) {
                let hit = kept[hitIndex]
                let keepExisting = Self.kbps(of: hit) >= Self.kbps(of: item)
                let loser = keepExisting ? item : hit
                let winner = keepExisting ? hit : item
                freed += loser.totalBytes
                remove(itemID: loser.id, deleteFile: true)
                if !keepExisting {
                    kept[hitIndex] = winner
                }
                merged += 1
            } else {
                kept.append(item)
            }
        }
        return (merged, freed)
    }

    // MARK: - 内部

    static func kbps(of item: DownloadItem) -> Int64 {
        let dur = item.song.duration
        guard dur > 0, item.totalBytes > 0 else { return 0 }
        return Int64((Double(item.totalBytes) * 8 / dur / 1000).rounded())
    }

    /// 本地音频的标签/时长（读到的那一份）
    struct LocalMeta {
        var title = ""
        var artist = ""
        var album = ""
        var duration: TimeInterval = 0
        var artwork: Data?
        var hash = ""
        var bytes: Int64 = 0
    }

    /// 读本地音频的标签与时长（异步）。
    ///
    /// **v2.4.51：失败时带回真实原因。** 旧版一律写成"X 读不出时长（可能没下载完、文件损坏，
    /// 或是加密包）"，把 `ENOENT`（系统清掉了临时副本）这种铁证也写成同一句，
    /// 2026-11-21 那 245 首的真因因此被藏了两轮。
    private static func localMetadata(of url: URL, originalName: String) async -> (meta: LocalMeta?, failure: String) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard let hash = sha256Hex(of: url) else {
            return (nil, "读不到文件内容（\(fileReadFailureText(url))）")
        }

        let asset = AVURLAsset(url: url)
        var duration = (try? await asset.load(.duration))?.seconds ?? 0
        // AVURLAsset 读不出时长 ≠ 文件坏了：有些 VBR mp3、头不全的 wav/m4a 就是拿不到。
        // 再给 Core Audio（`AVAudioFile`，只读文件头）一次机会 —— 2026-11-21 老板"有些歌导入失败"
        // 里这一类就是被 `duration <= 0` 一票否决的。
        if !(duration > 0) {
            duration = coreAudioDuration(of: url)
            if duration > 0 {
                CrashReporter.logImport("import: AVURLAsset 读不出时长，Core Audio 兜底成 \(Int(duration))s · \(originalName)")
            }
        }
        let common = (try? await asset.load(.commonMetadata)) ?? []

        var title = ""
        var artist = ""
        var album = ""
        var artwork: Data?

        for item in common {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if let v = try? await item.load(.stringValue) { title = repairMojibake(v) }
            case .commonKeyArtist:
                if let v = try? await item.load(.stringValue) { artist = repairMojibake(v) }
            case .commonKeyAlbumName:
                if let v = try? await item.load(.stringValue) { album = repairMojibake(v) }
            case .commonKeyArtwork:
                if let data = try? await item.load(.dataValue) { artwork = data }
            default:
                break
            }
        }

        // 标签缺失 → 用文件名兜底（并标记为"推测"，UI 不显示成确定信息）
        //
        // 注意：暂存副本的名字是 UUID（避免撞名），所以**必须用原始文件名**兜底，
        // 否则整个库的歌名会变成一串 UUID。
        if title.isEmpty || artist.isEmpty {
            let parsed = ImportRules.parseFileName(originalName)
            if title.isEmpty { title = parsed.title }
            if artist.isEmpty { artist = parsed.artist }
        }
        if title.isEmpty { title = (originalName as NSString).deletingPathExtension }
        if duration <= 0 {
            return (nil, "\(url.pathExtension.lowercased()) 读不出时长（文件损坏或加密包）")
        }

        var meta = LocalMeta()
        meta.title = title
        meta.artist = artist
        meta.album = album
        meta.duration = duration
        meta.artwork = artwork
        meta.hash = hash
        meta.bytes = bytes
        return (meta, "")
    }

    /// 导入暂存目录：**必须在 Documents 下**。
    ///
    /// 为什么不放 `tmp`：系统会在 App 运行约 1 分钟后清掉 `tmp`（前台也清），
    /// 2026-11-21 全选 664 首、第 59 秒起 245 首「文件不存在」就是这么来的。
    /// `Documents` 不会被系统回收，抢进来的副本只有我们自己删。
    static func importStagingDirectory() -> URL {
        let dir = DownloadLocation.documentsDirectory()
            .appendingPathComponent(importStagingFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 暂存目录名（同时加进 `ImportRules.browserHiddenNames`，别让它在导入浏览器里露脸）
    static let importStagingFolderName = "ImportStaging"

    /// 清空暂存目录：每次导入开始与结束各一次，只删这个目录里的东西
    static func resetImportStaging(_ dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    /// 打开失败时把系统原话带出来——`ENOENT`（不存在）和 `EACCES`（没权限）一眼能分
    static func fileReadFailureText(_ url: URL) -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
            return "能打开但读不出内容"
        } catch {
            let ns = error as NSError
            return "\(ns.domain)/\(ns.code) \(error.localizedDescription)"
        }
    }

    /// 系统选择器（`asCopy: true`）把选中的文件复制进来的临时位置：
    /// `Documents/Inbox/…` 或 App 的 tmp 目录。导入完成后可以安全删掉这份副本
    /// （否则同一首歌在 `Music/` 和 `Inbox/` 各占一份）。
    ///
    /// 判据写死在**这两个前缀**上，用户在 `文件 › JZ 音乐` 里自己的文件不会被误删。
    static func isPickerStagingFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let docs = DownloadLocation.documentsDirectory().standardizedFileURL.path
        if path.hasPrefix(docs + "/Inbox/") { return true }
        let tmp = NSTemporaryDirectory()
        if !tmp.isEmpty, path.hasPrefix(tmp) { return true }
        return false
    }

    /// 兜底读时长：`AVAudioFile` 走 Core Audio，只读文件头，对大文件也没开销。
    /// 能打开就算"这个文件其实能播"，长度 = 帧数 / 采样率。
    private static func coreAudioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return 0 }
        return Double(file.length) / rate
    }

    /// 文件 SHA-256（分块读，几百 MB 也不会把内存吃满）
    private static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 修 GBK 乱码：ID3v2.3 里中文常被标成 ISO-8859-1，AVFoundation 解出来是 "ÖÜ½ÜÂ×" 这种。
    /// 只在这两种情况动手：① 原串里没有 CJK；② 按 latin1 取字节后用 GB18030 能解出 CJK。
    private static func repairMojibake(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let hasCJK = s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if hasCJK { return s }
        guard let latin1 = s.data(using: .isoLatin1), !latin1.isEmpty else { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let fixed = String(data: latin1, encoding: String.Encoding(rawValue: gb)),
              fixed.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
        else { return s }
        return fixed
    }
}

/// 未捕获的 Objective-C 异常（Swift 的数组越界/断言是 SIGTRAP，这里收不到，
/// 但内存曲线能区分 jetsam；这个 handler 只负责把真异常写下来）。
private func jzUncaughtExceptionHandler(_ ex: NSException) {
    let text = """
    ==== uncaught exception ====
    \(Date())
    \(ex.name.rawValue): \(ex.reason ?? "")
    \(ex.callStackSymbols.joined(separator: "\n"))

    """
    CrashReporter.append(text, to: "crash-\(CrashReporter.stamp()).log")
}

// MARK: - 信号取证用的全局（文件级：C 函数指针不能捕获上下文）

/// 预分配的栈缓冲（信号上下文里不能 malloc）
private let gFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>? = {
    let p = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    p.initialize(repeating: nil, count: 64)
    return p
}()

private var gFDtrap: Int32 = -1
private var gFDsegv: Int32 = -1
private var gFDabrt: Int32 = -1
private var gFDbus: Int32 = -1

/// 只做一件事：往"该信号对应的文件"里写 1 个字节。
/// 不用 Swift 字符串拼接/格式化（信号上下文里可能死锁）—— 文件存在即证明是哪种信号。
private func jzSignalHandler(_ sig: Int32) {
    var fd: Int32 = -1
    if sig == SIGTRAP { fd = gFDtrap }
    else if sig == SIGSEGV { fd = gFDsegv }
    else if sig == SIGABRT { fd = gFDabrt }
    else if sig == SIGBUS { fd = gFDbus }
    if fd >= 0 {
        var byte: UInt8 = 0x31
        _ = withUnsafePointer(to: &byte) { write(fd, $0, 1) }
        // 栈也写进同一个文件（backtrace_symbols_fd 是异步信号安全的）
        if let frames = gFrames {
            let n = backtrace(frames, Int32(64))
            backtrace_symbols_fd(frames, n, fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
