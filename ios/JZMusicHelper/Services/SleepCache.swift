import Foundation

// MARK: - 助眠声音的本地缓存
//
// 为什么不纯流式：一条 2 分钟、3 MB 的音效如果直接循环 URL，会**每圈重新请求一次**。
// 8 层开一夜 ≈ 5 GB 流量，绝对不能这么干。所以第一次拉下来就落盘，之后全走本地文件。
//
// 两个必须注意的点：
//   · Moodist 的服务器把**所有 404 改写成 200 + 首页 HTML**（Caddy handle_errors），
//     所以不能只看状态码，必须校验 Content-Type 是 audio/*，否则会把 HTML 当音频存下来。
//   · 缓存上限 200 MB，超出按最久未用清理（播放前会 touch 修改时间）。
actor SleepCache {

    static let shared = SleepCache()

    private let dir: URL
    private let maxBytes: Int64 = 200 * 1024 * 1024
    private var inFlight: [String: Task<URL, Error>] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("SleepSounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cachedURL(for id: String) -> URL {
        dir.appendingPathComponent("\(id).mp3")
    }

    /// 取本地文件；没有就下。并发调用同一个 id 会复用同一个下载任务。
    func file(for sound: SleepSound) async throws -> URL {
        let dest = cachedURL(for: sound.id)
        if FileManager.default.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }
        if let task = inFlight[sound.id] { return try await task.value }
        guard let url = sound.url else { throw SleepCacheError.badURL }

        let task = Task<URL, Error> { [dir] in
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            let (tmp, response) = try await URLSession.shared.download(for: req)

            if let http = response as? HTTPURLResponse {
                let mime = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                guard http.statusCode == 200, mime.hasPrefix("audio/") else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw SleepCacheError.notAudio(status: http.statusCode, mime: mime)
                }
            }
            let target = dir.appendingPathComponent("\(sound.id).mp3")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            return target
        }
        inFlight[sound.id] = task
        defer { inFlight[sound.id] = nil }
        let url = try await task.value
        trimIfNeeded()
        return url
    }

    /// 超出上限就按最久未用删
    func trimIfNeeded() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
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
        guard total > maxBytes else { return }
        for (u, _, size) in files.sorted(by: { $0.1 < $1.1 }) {
            try? fm.removeItem(at: u)
            total -= size
            if total <= maxBytes { break }
        }
    }

    func clearAll() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}

enum SleepCacheError: LocalizedError {
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
