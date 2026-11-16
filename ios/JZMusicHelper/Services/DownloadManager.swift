import Foundation
import UIKit
import UserNotifications

// MARK: - 下载管理器
/// 管理下载任务：前台 URLSession（实时进度）+ 后台 URLSession（App 退后台继续下载）。
/// 文件保存到 App 沙盒 Documents/Music/ 目录（已开启 UIFileSharingEnabled，
/// 在"文件"App → 我的 iPhone → JZ 音乐 中可见）。
final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()

    /// 主线程发布：下载列表
    @Published var items: [DownloadItem] = []
    @Published var backgroundTaskCount: Int = 0

    private let musicDirName = "Music"
    private let backgroundID = "com.jz.musichelper.downloads"

    private var foregroundSession: URLSession!
    private var backgroundSession: URLSession!
    /// taskIdentifier -> 条目 id（进度回调用）
    private var taskMap: [Int: UUID] = [:]
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

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")

        let session: URLSession = useBackground ? backgroundSession : foregroundSession
        let task = session.downloadTask(with: request)
        item.status = .downloading
        appendOrUpdate(item)
        taskMap[task.taskIdentifier] = id
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

    /// 取消下载
    func cancel(itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = items[idx]
        // 找到对应 task 取消
        if let tid = taskMap.first(where: { $0.value == itemID })?.key {
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
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        let session: URLSession = useBackground ? backgroundSession : foregroundSession
        let task = session.downloadTask(with: request)
        newItem.status = .downloading
        appendOrUpdate(newItem)
        taskMap[task.taskIdentifier] = itemID
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

// MARK: - URLSessionDownloadDelegate
extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = taskMap[downloadTask.taskIdentifier] else { return }
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
        guard let id = taskMap[downloadTask.taskIdentifier] else { return }
        taskMap[downloadTask.taskIdentifier] = nil
        var destURL: URL?
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            var item = self.items[idx]
            do {
                let dir = self.musicDirectory
                destURL = dir.appendingPathComponent(item.fileName)
                if FileManager.default.fileExists(atPath: destURL!.path) {
                    try? FileManager.default.removeItem(at: destURL!)
                }
                try FileManager.default.moveItem(at: location, to: destURL!)
                item.localPath = destURL!.path
                var actual: Int64 = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL!.path),
                   let size = attrs[.size] as? Int64 {
                    actual = size
                    item.totalBytes = size
                }
                // 95% 体积防线：取流时探到的体积与实际落盘体积对不上，宁可删掉重下，
                // 也不要把半截文件留在库里伪装成"下载完成"（Android 同口径）。
                let expected = item.expectedBytes ?? 0
                if DownloadGuard.isComplete(actual: actual, expected: expected) {
                    item.status = .completed
                    item.progress = 1.0
                    item.finishedAt = Date()
                    item.errorMessage = nil
                } else {
                    try? FileManager.default.removeItem(at: destURL!)
                    item.localPath = nil
                    item.status = .failed
                    item.progress = 0
                    item.errorMessage = "文件不完整（\(DownloadGuard.sizeText(actual)) / 预期 \(DownloadGuard.sizeText(expected))），已删除"
                }
            } catch {
                item.status = .failed
                item.errorMessage = error.localizedDescription
            }
            self.items[idx] = item
            self.persist()
            self.notifyCompletion(item)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskMap[task.taskIdentifier] else { return }
        if let error = error {
            taskMap[task.taskIdentifier] = nil
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                var item = self.items[idx]
                if item.status != .cancelled {
                    item.status = .failed
                    item.errorMessage = error.localizedDescription
                }
                self.items[idx] = item
                self.persist()
            }
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
