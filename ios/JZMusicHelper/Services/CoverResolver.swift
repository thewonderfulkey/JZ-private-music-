import Foundation

// MARK: - 封面兜底
//
// 兜底顺序（2026-11-17 起，iOS 比 Android 多出第 ① 步）：
//   ① 酷我歌曲：按 **rid 同平台取专辑图**（`artistpicserver` 的 `rid_pic`）——同曲目必然同专辑图
//   ② 其余平台 / ① 取不到：用「同歌名 + 同歌手」去 QQ 搜一次，严格匹配才取
//   ③ 都取不到：返回 nil，让 UI 落占位图
//
// 为什么加 ①：实测（2026-11-16）酷我搜索结果里约两成没有 MVPIC 字段，
// 以前这 20% 全靠 QQ 跨平台兜底——跨平台本质上是猜（同名不同专辑就会贴错图）。
// 而榜单曲（`KuwoChart`）**一个封面字段都没有**，100 行全靠兜底，所以同平台取图是刚需。
//
// 为什么必须严格：模糊匹配会把别的版本的封面贴上来（翻唱 / 同名不同歌），比没有封面更糟。
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
    /// 已知**加载不出来**的地址：key（歌名|歌手）→ url。
    /// 用来避免"同一首歌每次都先试同一个坏地址"（酷我 rid_pic 有些地址就是 404）。
    private var deadURLs: [String: String] = [:]
    private static let deadCacheKey = "cover_dead_urls_v1"
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loaded = false

    private init() {
        permits = 3
        // 缓存懒加载见 loadIfNeeded（首次取封面时才读 UserDefaults）
    }

    // MARK: 对外

    /// 返回可展示的封面 URL：有封面直接用（旧的 imgessl 除外），没有才走兜底
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
            // 依次尝试：① 酷我按 rid 同平台取图 → ② QQ 严格匹配 → ③ iTunes（公共兜底）。
            // 每一级都跳过"已知加载不出来的地址"（见 `markDead`）——
            // 之前把 rid_pic 返回的**404 地址**直接写进缓存，于是固定那几首歌永远没有封面。
            var url: String?
            if let rid = Self.kuwoRid(song) {
                if let cand = await Self.lookupKuwoRidCover(rid: rid, timeout: timeout),
                   await !self.isDead(cand, key: key) {
                    url = cand
                }
            }
            if url == nil {
                if let cand = await Self.lookupQQCover(song: song, limit: limit, timeout: timeout),
                   await !self.isDead(cand, key: key) {
                    url = cand
                }
            }
            if url == nil {
                if let cand = await ITunesCover.fetch(song: song, timeout: timeout),
                   await !self.isDead(cand, key: key) {
                    url = cand
                }
            }
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

    // MARK: 酷我同平台封面（rid_pic）

    /// 只有酷我歌曲、且 `platformID` 是纯数字 rid 时才走这条路。
    /// 酷我搜索给的是 `DC_TARGETID`（数字），榜单给的是 `id`（数字）——都不是数字的说明不是 rid，不猜。
    static func kuwoRid(_ song: Song) -> String? {
        guard song.platform == .kuwo else { return nil }
        let rid = song.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rid.isEmpty, rid.allSatisfy({ $0.isNumber }) else { return nil }
        return rid
    }

    /// 按 rid 取酷我专辑图 URL。
    ///
    /// `artistpicserver` 的响应是**一段裸 URL 文本**（不是 JSON），而且给的地址有三个坑：
    ///   · 协议是 `http`：iOS 已开 ATS 严格（`NSAllowsArbitraryLoads` 已移除），http 会被系统直接拦掉；
    ///   · 域名常是 `img1.kwcdn.kuwo.cn`：这台机器实测该域**根本不提供 https**（TLS 直接失败），
    ///     也就是说"图补上了但永远加载不出来"；
    ///   · 同一路径在 `img1/2/4.kuwo.cn` 上 https 200 且字节一致（三张图实测同上同大小）。
    ///
    /// 所以统一做「升 https + `.kwcdn.kuwo.cn` → `.kuwo.cn`」。
    /// 另外**拒收歌手头像**：`/starheads/` 是歌手图，贴到歌曲行上就是张冠李戴，比没图更糟
    /// （实测有个别 rid 会返回 starheads）。纯函数，CI 有断言。
    static func ridPicURL(fromBody body: String) -> String? {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        var url = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
        guard !url.lowercased().contains("/starheads/") else { return nil }
        if url.hasPrefix("http://") {
            url = "https://" + url.dropFirst("http://".count)
        }
        if url.contains(".kwcdn.kuwo.cn") {
            url = url.replacingOccurrences(of: ".kwcdn.kuwo.cn", with: ".kuwo.cn")
        }
        guard url.count <= 2048 else { return nil }
        return url
    }

    static func lookupKuwoRidCover(rid: String, timeout: TimeInterval = 5) async -> String? {
        let url = "https://artistpicserver.kuwo.cn/pic.web"
            + "?type=rid_pic&pictype=url&content=list&size=320&rid=\(rid)"
        guard let body = try? await APIClient.shared.getString(
            url, headers: ["Referer": "https://www.kuwo.cn/"], timeout: timeout) else {
            return nil
        }
        return ridPicURL(fromBody: body)
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

    // MARK: 坏地址（加载失败）黑名单

    /// 这个地址对这首歌是不是已知加载不出来
    func isDead(_ url: String, key: String) -> Bool {
        deadURLs[key] == url
    }

    /// 调用方确认这张图**加载失败**时调用：拉黑地址并清掉缓存里的同名记录，
    /// 下一次解析会降到下一级兜底（QQ → iTunes），而不是把坏地址又发一遍。
    func markDead(_ url: String, for song: Song) {
        let key = Self.cacheKeyFor(song)
        if deadURLs[key] != url {
            deadURLs[key] = url
            persistDead()
        }
        if memory[key] == url {
            memory[key] = nil
            persist()
        }
    }

    private func persistDead() {
        UserDefaults.standard.set(deadURLs, forKey: Self.deadCacheKey)
    }

    private func loadDeadIfNeeded() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.deadCacheKey) as? [String: String] else {
            return
        }
        deadURLs = saved
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
        loadDeadIfNeeded()
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
