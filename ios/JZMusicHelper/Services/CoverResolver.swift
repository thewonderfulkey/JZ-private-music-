import Foundation

// MARK: - 封面兜底
//
// 与 Android `CoverResolver.kt` 同口径：**只兜没有封面的歌**，用「同歌名 + 同歌手」去 QQ 搜一次，
// 严格匹配（歌名完全相等 + 歌手任一片段相等）才取这张封面；匹配不上就返回 nil，让 UI 落占位图。
//
// 为什么必须严格：模糊匹配会把别的版本的封面贴上来（翻唱 / 同名不同歌），比没有封面更糟。
// 为什么需要兜底：实测（2026-11-16）酷我搜索结果里约两成没有 MVPIC 字段；
// 另外酷狗旧版 `imgessl` 封面已被 CDN 软失败（HTTP 200 但固定返回黑胶占位图），也当作没有。
//
// 三条约束（照搬 Android，都是为了首屏不炸）：
//   · 全局并发上限 3：首屏几十行同时没封面也不会打出请求风暴
//   · 同一首歌进行中去重：只发一次 QQ 搜索
//   · 结果进内存 + UserDefaults（最多 300 条），跨会话免重复请求
actor CoverResolver {

    static let shared = CoverResolver()

    private let cacheKey = "cover_qq_cache"
    private let cacheLimit = 300
    private let maxConcurrent = 3
    private let timeout: TimeInterval = 5
    private let searchLimit = 10

    private var memory: [String: String] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loaded = false

    private init() {
        permits = 3
        // 缓存懒加载见 loadIfNeeded（首次取封面时才读 UserDefaults）
    }

    // MARK: 对外

    /// 返回可展示的封面 URL：有封面直接用（旧的 imgessl 除外），没有才去 QQ 兜底
    func coverURL(for song: Song) async -> String? {
        loadIfNeeded()
        if let pic = song.picURL, !pic.isEmpty, !Self.isLegacyDeadCover(song) {
            return pic
        }
        return await resolveIgnoringPic(song)
    }

    /// 忽略原 URL，强制走兜底（原图加载失败时用）
    func coverURLIgnoringOriginal(for song: Song) async -> String? {
        loadIfNeeded()
        return await resolveIgnoringPic(song)
    }

    // MARK: 内部

    private func resolveIgnoringPic(_ song: Song) async -> String? {
        let key = Self.cacheKeyFor(song)
        if let hit = memory[key] { return hit }
        if let running = inFlight[key] { return await running.value }

        // 常量先取出来：Task 闭包不保证在 actor 上下文里，别在里面直接读隔离属性
        let limit = searchLimit
        let timeout = self.timeout
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquire()
            let url = await Self.lookupQQCover(song: song, limit: limit, timeout: timeout)
            await self.release()
            if let url {
                await self.store(url, for: key)
            }
            return url
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// QQ 搜「歌名 歌手」→ 严格匹配（歌名完全相等 + 歌手任一片段相等 + 有封面）
    static func lookupQQCover(song: Song, limit: Int = 10,
                              timeout: TimeInterval = 5) async -> String? {
        let keyword = "\(song.name) \(song.singer)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return nil }
        let candidates = await withTimeoutOrNil(timeout) {
            try await QQSearchAdapter().search(keyword: keyword, limit: limit)
        } ?? []
        for candidate in candidates {
            guard let pic = candidate.picURL, !pic.isEmpty else { continue }
            if isStrictMatch(name: song.name, singer: song.singer,
                             candidateName: candidate.name, candidateSinger: candidate.singer) {
                return pic
            }
        }
        return nil
    }

    /// 严格匹配规则（纯函数，CI 里有断言）：
    /// 歌名去首尾空白后**完全相等**（忽略大小写），且歌手至少有一个片段相等（忽略大小写）。
    /// 注意这是"严格"——带 (Live)/(纯音乐) 后缀的候选不算同一条，宁可没封面也不张冠李戴。
    static func isStrictMatch(name: String, singer: String,
                              candidateName: String, candidateSinger: String) -> Bool {
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candName = candidateName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !targetName.isEmpty, targetName == candName else { return false }
        let targetSingers = Set(singerParts(singer))
        guard !targetSingers.isEmpty else { return true }
        return !singerParts(candidateSinger).filter { targetSingers.contains($0) }.isEmpty
    }

    /// 歌手串拆片段（按 / 分），与 Android `song.singer.split('/')` 一致
    static func singerParts(_ singer: String) -> [String] {
        singer.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// 酷狗旧版 imgessl 封面已被 CDN 软失败（HTTP 200 + 固定黑胶图），一律当没有封面
    static func isLegacyDeadCover(_ song: Song) -> Bool {
        guard song.platform == .kugou, let pic = song.picURL else { return false }
        return pic.lowercased().contains("imgessl")
    }

    static func cacheKeyFor(_ song: Song) -> String {
        "\(song.name)|\(song.singer)"
    }

    // MARK: 状态

    private func store(_ url: String, for key: String) {
        memory[key] = url
        persist()
    }

    private func persist() {
        let entries = memory.suffix(cacheLimit).map { ["k": $0.key, "v": $0.value] }
        UserDefaults.standard.set(entries, forKey: cacheKey)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let raw = UserDefaults.standard.array(forKey: cacheKey) as? [[String: String]] else { return }
        for entry in raw {
            if let k = entry["k"], let v = entry["v"], !k.isEmpty, !v.isEmpty {
                memory[k] = v
            }
        }
    }

    /// 并发闸门：最多 maxConcurrent 个 QQ 搜索同时进行，其余排队
    private func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            permits = min(permits + 1, maxConcurrent)
        }
    }
}
