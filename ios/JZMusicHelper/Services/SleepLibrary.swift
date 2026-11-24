import Foundation
import Observation

// MARK: - 助眠声音的本地库
//
// 两层，语义不同：
//
//  ① **播放缓存**（`Caches/SleepSounds`，200 MB LRU）
//     点一下就能响，靠它。第一次播放时自动拉，之后本地循环。
//     ——为什么要缓存：纯流式循环会每圈重新请求一次（2 分钟 3 MB 的文件，
//     8 层开一夜 ≈ 5 GB 流量）。
//
//  ② **用户下载**（`Application Support/SleepSounds`，永不自动清理）
//     老板要的「自行下载内置」：下过之后**完全不发请求**，飞行模式也能听。
//     播放优先级：用户下载 > 播放缓存 > 网络。
//
// 一个必须注意的坑：Moodist 的服务器把**所有 404 改写成 200 + 首页 HTML**
// （Caddy `handle_errors`），所以不能只看状态码，必须校验 `Content-Type` 是 `audio/*`，
// 否则会把 HTML 当音频存下来，后面 AVAudioFile 打不开。
@MainActor
@Observable
final class SleepLibrary {

    static let shared = SleepLibrary()

    /// 用户已下载（永久保留）
    private(set) var downloaded: Set<String> = []
    /// 正在下载
    private(set) var downloading: Set<String> = []
    /// 最近一次失败原因（UI 顶部提示）
    private(set) var lastError: String?

    private(set) var cacheBytes: Int64 = 0
    private(set) var libraryBytes: Int64 = 0

    private let cacheDir: URL
    private let libraryDir: URL
    private let maxCacheBytes: Int64 = 200 * 1024 * 1024
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var errorTask: Task<Void, Never>?

    private init() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("SleepSounds", isDirectory: true)
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: true))
            ?? caches
        libraryDir = support.appendingPathComponent("SleepSounds", isDirectory: true)
        for d in [cacheDir, libraryDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // 别让 84 条音频跟着 iCloud 备份跑
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = libraryDir
        try? dir.setResourceValues(values)
        reload()
    }

    // MARK: 查询

    func isDownloaded(_ id: String) -> Bool { downloaded.contains(id) }

    func libraryURL(_ sound: SleepSound) -> URL {
        libraryDir.appendingPathComponent("\(sound.id).\(sound.fileExtension)")
    }

    func cacheURL(_ sound: SleepSound) -> URL {
        cacheDir.appendingPathComponent("\(sound.id).\(sound.fileExtension)")
    }

    /// 播放时优先拿哪个文件：用户下载 > 播放缓存 > nil（需要联网）
    func localFile(for sound: SleepSound) -> URL? {
        let lib = libraryURL(sound)
        if FileManager.default.fileExists(atPath: lib.path) {
            touch(lib)
            return lib
        }
        let cache = cacheURL(sound)
        if FileManager.default.fileExists(atPath: cache.path) {
            touch(cache)
            return cache
        }
        return nil
    }

    // MARK: 播放前准备（没有就下到缓存）

    func playableFile(for sound: SleepSound) async throws -> URL {
        if let local = localFile(for: sound) { return local }
        if let task = inFlight[sound.id] { return try await task.value }
        guard let url = sound.url else { throw SleepLibraryError.badURL }
        let task = Task<URL, Error> { [cacheDir] in
            let tmp = try await Self.fetch(sound: sound, from: url)
            let dest = cacheDir.appendingPathComponent("\(sound.id).\(sound.fileExtension)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        }
        inFlight[sound.id] = task
        defer { inFlight[sound.id] = nil }
        let file = try await task.value
        trimCache()
        reload()
        return file
    }

    // MARK: 用户显式下载（永久保留）

    func download(_ sound: SleepSound) async {
        guard !isDownloaded(sound.id), !downloading.contains(sound.id) else { return }
        guard let url = sound.url else { setError("声音地址无效"); return }
        downloading.insert(sound.id)
        defer { downloading.remove(sound.id) }
        do {
            let tmp = try await Self.fetch(sound: sound, from: url)
            let dest = libraryURL(sound)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            // 下到库里之后，播放缓存那份就没用了
            try? FileManager.default.removeItem(at: cacheURL(sound))
            reload()
        } catch {
            setError("「\(sound.name)」下载失败：\(error.localizedDescription)")
        }
    }

    func download(category: String) async {
        for s in SleepSound.inCategory(category) where !isDownloaded(s.id) {
            await download(s)
        }
    }

    func removeDownload(_ sound: SleepSound) {
        try? FileManager.default.removeItem(at: libraryURL(sound))
        reload()
    }

    func removeAllDownloads() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
        reload()
    }

    func clearCache() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
        reload()
    }

    func clearError() { lastError = nil }

    /// 报错只停 4 秒，不常显
    private func setError(_ text: String) {
        lastError = text
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lastError = nil }
        }
    }

    // MARK: 内部

    private static func fetch(sound: SleepSound, from url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                     forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse {
            let mime = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard http.statusCode == 200, mime.hasPrefix("audio/") else {
                try? FileManager.default.removeItem(at: tmp)
                throw SleepLibraryError.notAudio(status: http.statusCode, mime: mime)
            }
        }
        return tmp
    }

    private func reload() {
        let fm = FileManager.default
        func scan(_ dir: URL) -> (Set<String>, Int64) {
            var ids = Set<String>()
            var total: Int64 = 0
            guard let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                          options: .skipsHiddenFiles) else { return (ids, total) }
            for u in items where ["mp3", "wav"].contains(u.pathExtension.lowercased()) {
                ids.insert(u.deletingPathExtension().lastPathComponent)
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return (ids, total)
        }
        let (libIDs, libBytes) = scan(libraryDir)
        let (_, cacheBytesValue) = scan(cacheDir)
        downloaded = libIDs
        libraryBytes = libBytes
        cacheBytes = cacheBytesValue
    }

    private func trimCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                      options: .skipsHiddenFiles) else { return }
        var total: Int64 = 0
        var files: [(URL, Date, Int64)] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(v?.fileSize ?? 0)
            total += size
            files.append((u, v?.contentModificationDate ?? .distantPast, size))
        }
        guard total > maxCacheBytes else { return }
        for (u, _, size) in files.sorted(by: { $0.1 < $1.1 }) {
            try? fm.removeItem(at: u)
            total -= size
            if total <= maxCacheBytes { break }
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}

enum SleepLibraryError: LocalizedError {
    case badURL
    case notAudio(status: Int, mime: String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "声音地址无效"
        case .notAudio(let status, let mime):
            return "服务器没给音频（HTTP \(status) · \(mime.isEmpty ? "无类型" : mime)）"
        }
    }
}
