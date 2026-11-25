import Foundation

// MARK: - 封面兜底
//
// 兜底顺序（2026-11-26 起：**酷我封面整条路废掉**）：
//   ① 用「同歌名 + 同歌手」去 QQ 搜一次，严格匹配才取
//   ② 都取不到：iTunes（华语必须带店，见 `ITunesCover`）
//   ③ 仍取不到：返回 nil，让 UI 落占位图
//
// 为什么废酷我（老板 2026-11-26 拍板，只废封面、音频照用）：
//   本机 225 张普查（`tools/probes/cover_census.py`）——酷我搜索的 MVPIC 是**曲图**
//   （`img1.kuwo.cn/wmvpic/`），45/45 全是 324×182 横图（影视剧照/综艺片花/带字幕的 MV 截图）；
//   而 QQ 60/60、酷狗 60/60、网易 59/60 都是方形官方专辑图。
//   同时废掉 `rid_pic`（`artistpicserver.kuwo.cn`）——那也是酷我的封面 API，
//   留着它等于"picURL 空了又回去问酷我要图"，绕一圈还是同一批图。
//
// 为什么必须严格：模糊匹配会把别的版本的封面贴上来（翻唱 / 同名不同歌），比没有封面更糟。
// 另外两类别"软失败"的图一律当没有：酷狗旧版 `imgessl`（CDN 回固定黑胶占位图）、
// 酷狗 `singerimg/…/softhead/`（**歌手头像**，贴到歌曲行上就是张冠李戴）。
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
            // 依次尝试：① QQ 严格匹配 → ② iTunes（公共兜底）。
            // 每一级都跳过"已知加载不出来的地址"（见 `markDead`）。
            // 2026-11-26：酷我 `rid_pic` 这一级已删（老板拍板废酷我封面 API）。
            var url: String?
            if let cand = await Self.lookupQQCover(song: song, limit: limit, timeout: timeout),
               await !self.isDead(cand, key: key) {
                url = cand
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

    // MARK: 酷我同平台封面（rid_pic）—— 2026-11-26 整条删除
    //
    // 老板拍板：「只废掉酷我的封面 API，封面还是用其他平台的 API」。
    // 这一级原本是 `artistpicserver.kuwo.cn/pic.web?type=rid_pic`（酷我自己的封面服务），
    // 和搜索里的 wmvpic 是同一个坑（把非专辑图当封面），所以一起下线，
    // 让兜底直接落到 QQ 严格匹配 → iTunes。
    //
    // 保留这段注释是为了下一个读到这里的人知道：**不是忘了写，是故意没有**。

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

    /// 这些封面一律当"没有"：
    ///   · 酷狗旧版 `imgessl`：CDN 软失败（HTTP 200 + 固定黑胶图）；
    ///   · 酷狗 `singerimg/…/softhead/`：**歌手头像/歌手上传图**，不是专辑封面，贴到歌曲行上是张冠李戴。
    ///     2026-11-26 实测：搜《断了的弦》5 条候选里有 2 条封面指向 softhead。
    static func isLegacyDeadCover(_ song: Song) -> Bool {
        guard song.platform == .kugou, let pic = song.picURL else { return false }
        let low = pic.lowercased()
        return low.contains("imgessl") || low.contains("singerimg") || low.contains("/softhead")
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
