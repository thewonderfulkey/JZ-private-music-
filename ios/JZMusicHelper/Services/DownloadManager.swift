import AVFoundation
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
    @Published var items: [DownloadItem] = []
    @Published var backgroundTaskCount: Int = 0

    private let musicDirName = "Music"
    private let backgroundID = "com.jz.musichelper.downloads"

    private var foregroundSession: URLSession!
    private var backgroundSession: URLSession!

    // taskIdentifier 相关状态：delegate 队列与主线程都会碰，统一加锁
    private let taskLock = NSLock()
    private var taskMap: [Int: UUID] = [:]
    private var taskFileNames: [Int: String] = [:]

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
    }

    // MARK: - 目录

    var musicDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent(musicDirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
    func localFileURL(for song: Song) -> URL? {
        guard let item = items.first(where: { $0.song.id == song.id && $0.status == .completed }),
              let path = item.localPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
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
        if deleteFile, let path = item.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        items.remove(at: idx)
        persist()
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

    // MARK: - 持久化

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: recordsURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }
        items = saved
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: recordsURL, options: .atomic)
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
        // 上一次是被用户上滑强杀的：系统不给 willTerminate，灵动岛/锁屏活动会留在那儿。
        // 启动时按类型扫一遍，全部收掉（正常启动时这里是空集合，没有副作用）。
        LiveActivityController.endAllActivities()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 用户/系统正在收掉 App：把"音乐软件留在系统里的东西"一次性清干净。
        // `assumeIsolated`：UIKit 一定在主线程调 willTerminate，而这里要碰的
        // NowPlayingCenter / LiveActivityController 都是 @MainActor —— 同步执行，不排进队列
        // （排进队列的话进程可能已经没了，清理根本不会跑）。
        MainActor.assumeIsolated {
            LiveActivityController.shared.resetForTermination()
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

    /// 由 DownloadManager.urlSessionDidFinishEvents 调用，执行系统要求的收尾回调。
    static func completeBackgroundSession(for identifier: String) {
        backgroundCompletionHandlers[identifier]?()
        backgroundCompletionHandlers[identifier] = nil
    }
}
