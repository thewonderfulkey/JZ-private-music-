import Foundation
import Observation

// MARK: - 心动模式：编排层
//
// 纯算法在 `HeartbeatRules`（CI 有断言）；这里只负责"什么时候算、跟谁要候选、把哪首预取下来"。
//
// 与播放器的分工（很重要，改这里之前先读 `PlayerEngine` 的 headTrackFinished / goTo）：
//   · `PlayerEngine` 负责"放"：切歌、解析、进度、歌词、锁屏；
//   · 本类负责"选"：画像、召回、排序、预取、把下一首交给播放器。
// 播放器永远不自己算歌，引擎也永远不碰 AVPlayer。
//
// 一次心动的时间线（老板 2026-11-19 口径："播放过程中算下一首并缓存"）：
//   t=0        起播 → 记播放事件 → 2 秒后开始规划（避开本曲取流）
//   t≈2s       画像 → 召回 → 排序 → 选出 n1、n2；n1 解析 + 整首下载到本地
//   t=曲末     播放器取 n1（本地文件优先）→ 起播 → 再规划新的 n1
//   用户切歌   记为负反馈（<30 秒）→ 立刻用已预取的 n1 顶上 → 再规划

@MainActor
@Observable
final class HeartbeatEngine {

    // MARK: 对外状态（播放页/设置页读）

    /// 当前这首为什么被选中（"你下载过 X 的歌" / "和《Y》同风格"）
    private(set) var reason: String = ""
    /// 一次性状态（例："暂无新歌，先按列表继续"）。播放页的理由条优先显示它，下次选到歌自动清掉。
    private(set) var notice: String?
    /// 正在算下一首（播放页转个小圈）
    private(set) var isPlanning = false
    /// 已算好、等着播的歌（最多 2 首；只有第一首会整首预取）
    private(set) var upcoming: [Pick] = []

    var hasUpcoming: Bool { !upcoming.isEmpty }

    /// 心动模式是否已经开着（播放器首次起播时用它决定要不要 activate）
    var isActive: Bool { active }

    /// 「不感兴趣」的歌数（设置页展示 + 一键恢复）
    var dislikedCount: Int { dislikedKeys.count }

    // MARK: 数据

    struct Pick {
        let song: Song
        let reason: String
        var localURL: URL?
        var streamURL: String?
    }

    private struct Prefetched {
        let localURL: URL?
        let streamURL: String?
    }

    private let defaults = UserDefaults.standard
    private static let keyDisliked = "heartbeat_disliked_keys"
    private static let keyDislikedArtists = "heartbeat_disliked_artists"
    static let eventsFile = "heartbeat_events.json"

    /// 最近 600 次播放（够画像用，也够"7 天内听过"判定；再多就是白占空间）
    static let maxEvents = 600

    // MARK: 热门兜底的口径（写在这里，别散落在调用点）
    //
    // **"大家都在听" = 酷我官方「热歌榜」的排名**（`KuwoChart.Chart.hot`，平台按热度每日更新）。
    //   · 不自己造播放量：接口给的 play 数不可信、经常缺失；
    //   · 不拿"多平台都能搜到"当热度：那会偏向老歌（经典曲库四平台全有），榜单名次才反映"当下"；
    //   · 取前 `hotSourceSize` 首 → 只留原版（去 Live/翻唱/伴奏）→ 同歌手 ≤2 → 前 `hotPoolLimit` 首；
    //   · 7 天内听过的、不感兴趣的剔除（放"没听过的热门"，不是"把榜单从头再放一遍"）。
    // 两个阈值在 `HeartbeatRules`（纯逻辑，CI 有断言）。

    private var events: [HeartbeatPlayEvent] = []
    private var dislikedKeys: Set<String> = []
    private var dislikedArtists: Set<String> = []

    /// 热歌榜池（进程内缓存；跨进程由 `KuwoChart` 自己的按日缓存兜）
    private var hotPool: [Song] = []
    private var hotPoolDay = -1

    // MARK: 会话状态

    /// 心动模式是否开启（只影响"算不算下一首"，播放事件无论什么模式都记）
    private var active = false
    private var seed: Song?
    private var sessionKeys: [String] = []
    private var artistWindow: [String] = []
    private var recentSongs: [Song] = []
    private var plannedCount = 0
    private var openEvent: HeartbeatPlayEvent?
    private var planTask: Task<Void, Never>?
    private var planning = false

    /// 预取目录（Caches/Heartbeat，系统空间紧张时会被回收，正好）
    private let cacheDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Heartbeat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir
        loadEvents()
        dislikedKeys = Set(defaults.stringArray(forKey: Self.keyDisliked) ?? [])
        dislikedArtists = Set(defaults.stringArray(forKey: Self.keyDislikedArtists) ?? [])
    }

    // MARK: 模式进出

    /// 切到心动模式：以当前这首为种子，立刻排第一首
    func activate(seed song: Song?) {
        active = true
        if let song { seed = song }
        sessionKeys = recentSongs.prefix(50).map { $0.id }
        artistWindow = recentSongs.prefix(6)
            .map { HeartbeatRules.primarySinger($0) }
            .filter { !$0.isEmpty }
        plannedCount = 0
        upcoming.removeAll()
        reason = song.map { "以《\($0.name)》为种子" } ?? "根据你的口味为你选歌"
        schedulePlan(delay: 1.5)
    }

    /// 切出心动模式：停规划、清待播（缓存文件留着，下次切回来可能还用得上）
    func deactivate() {
        active = false
        planTask?.cancel()
        planTask = nil
        planning = false
        isPlanning = false
        upcoming.removeAll()
    }

    /// 用户手点了别的歌：种子跟随（网易云同款行为），待播重排
    func adoptSeed(_ song: Song) {
        seed = song
        reason = "以《\(song.name)》为种子"
        if active {
            upcoming.removeAll()
            schedulePlan(delay: 1.5)
        }
    }

    // MARK: 播放事件（所有模式都记，画像才准）

    func trackStarted(_ song: Song) {
        if let open = openEvent, open.key == song.id { return }
        closeEvent(listened: 0, completed: false)

        openEvent = HeartbeatPlayEvent(song: song, startedAt: Date())
        sessionKeys.append(song.id)
        if sessionKeys.count > 200 { sessionKeys.removeFirst(sessionKeys.count - 200) }
        recentSongs.append(song)
        if recentSongs.count > 20 { recentSongs.removeFirst(recentSongs.count - 20) }
        let singer = HeartbeatRules.primarySinger(song)
        if !singer.isEmpty {
            artistWindow.append(singer)
            if artistWindow.count > 12 { artistWindow.removeFirst(artistWindow.count - 12) }
        }
        if active {
            if seed == nil { seed = song }
            schedulePlan(delay: 2.0)
        }
    }

    func trackEnded(listened: Double, completed: Bool) {
        closeEvent(listened: listened, completed: completed)
    }

    private func closeEvent(listened: Double, completed: Bool) {
        guard var e = openEvent else { return }
        openEvent = nil
        e.listenedSec = max(0, listened)
        e.completed = completed
        events.append(e)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        saveEvents()
    }

    // MARK: 取下一首

    /// 播放器拿下一首（队列里没歌时才调用）。nil = 现在没有可播的。
    func takeNext() -> Pick? {
        guard !upcoming.isEmpty else { return nil }
        let pick = upcoming.removeFirst()
        reason = pick.reason
        notice = nil
        return pick
    }

    /// 播放页理由条的临时提示（"暂无新歌，先按列表继续"）
    func setNotice(_ text: String?) {
        notice = text
    }

    /// 播放器"上一首/下一首"按到空队列时的兜底：现场算一首（最多等一次解析）。
    ///
    /// 这条路径**不等整首下载**：只解析出流地址就交给播放器立刻起播。
    /// 用户是按了"下一首"才走到这里的，多等 10 秒下载没法接受。
    func planOneNow() async -> Pick? {
        guard active else { return nil }
        guard !planning else { return nil }
        planning = true
        defer { planning = false }
        let pick = await makePick(position: plannedCount + 1, prefetchLocal: false)
        if let pick {
            plannedCount += 1
            reason = pick.reason
        }
        return pick
    }

    /// 用户从"即将播放"里点走某一首（播放列表弹层）
    func removeUpcoming(id: String) -> Pick? {
        guard let idx = upcoming.firstIndex(where: { $0.song.id == id }) else { return nil }
        let pick = upcoming.remove(at: idx)
        if active { schedulePlan(delay: 0.5) }
        return pick
    }

    // MARK: 规划

    private func schedulePlan(delay: TimeInterval) {
        planTask?.cancel()
        planTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.ensureLookahead(2)
        }
    }

    private func ensureLookahead(_ target: Int) async {
        guard active, !planning else { return }
        planning = true
        isPlanning = true
        let deadline = Date().addingTimeInterval(25)
        defer {
            planning = false
            isPlanning = false
        }

        var attempts = 0
        while upcoming.count < target, attempts < 4, !Task.isCancelled,
              Date() < deadline {
            attempts += 1
            let position = plannedCount + 1
            guard let pick = await makePick(position: position) else { break }
            guard !Task.isCancelled, active else { return }
            plannedCount += 1
            upcoming.append(pick)
            prunePrefetch()
        }
    }

    /// 选一首：先定"这次该出新歌还是旧爱"，再召回 → 打分 → 挑选 → 预取。
    ///
    /// - Parameter prefetchLocal: true 时把整首下到本地（正常路径）；false 时只解析出流地址
    ///   （播完才发现没预取的兜底路径，不能让用户干等下载）。
    ///
    /// 选歌是**四级梯子**，一级空/一级取不到流就往下一级走（详见 IOS-HEARTBEAT.md §2.6）：
    ///   ① 个性化（新歌 / 旧爱，冷启动时先试种子歌手）
    ///   ② 热歌榜（"大家都在听"）
    ///   ③ 放宽的自家资料库（允许重播——宁可重播，也别停）
    ///   ④ 内置精选池（榜单与搜索都不稳时，人工池兜底）
    /// 四级全空才返回 nil，播放器那边还有"退回队列顺序"的最后一手。
    private func makePick(position: Int, prefetchLocal: Bool = true) async -> Pick? {
        let profile = currentProfile()
        let exclude = Set(sessionKeys + upcoming.map { $0.song.id })
        // 梯子要有时间上限：每级最多试 3 首，整体不超过 20 秒（否则"选歌"会变成"卡住"）
        let deadline = Date().addingTimeInterval(prefetchLocal ? 20 : 12)

        // ① 个性化
        var primary: [HeartbeatScored]
        if profile.isEmpty {
            // 冷启动：先试「种子歌手」——用户是从某一首点进来的，同歌手最相关
            primary = await recall(profile: profile, exclude: exclude)
        } else {
            let wantOld = HeartbeatRules.wantsOld(
                position: position,
                oldShare: SettingsStore.shared.heartbeatOldShare)
            if wantOld {
                primary = oldCandidates(profile: profile, exclude: exclude)
            } else {
                primary = await recall(profile: profile, exclude: exclude)
            }
            // 新歌池空了（没网/搜不到）就退到旧爱池，反之亦然
            if primary.isEmpty {
                primary = wantOld
                    ? await recall(profile: profile, exclude: exclude)
                    : oldCandidates(profile: profile, exclude: exclude)
            }
        }
        if let pick = await pickFrom(primary, prefetchLocal: prefetchLocal, deadline: deadline) {
            return pick
        }

        // ② 热歌榜
        let hot = await hotCandidates(profile: profile, exclude: exclude)
        if let pick = await pickFrom(hot, prefetchLocal: prefetchLocal, deadline: deadline) {
            return pick
        }

        // ③ 自家资料库（放宽：允许重播，只排除当前这首与不感兴趣）
        if let pick = await pickFrom(libraryCandidates(profile: profile),
                                     prefetchLocal: prefetchLocal, deadline: deadline) {
            return pick
        }

        // ④ 内置精选池（人工兜底，最后一级）
        let catalog = await catalogCandidates()
        return await pickFrom(catalog, prefetchLocal: prefetchLocal, deadline: deadline)
    }

    /// 从一批候选里挑：MMR → 逐个尝试解析/预取，第一个成功的就是它。
    ///
    /// 每级只试 3 首：4 级 × 3 首 × 单首最长 8 秒会拖成分钟级，必须夹住。
    private func pickFrom(_ candidates: [HeartbeatScored],
                          prefetchLocal: Bool,
                          deadline: Date) async -> Pick? {
        guard !candidates.isEmpty else { return nil }
        let shortlist = HeartbeatRules.diversify(
            Array(candidates.prefix(14)),
            limit: 3,
            recent: recentSongs)

        for scored in shortlist {
            guard !Task.isCancelled, Date() < deadline else { return nil }
            if prefetchLocal {
                guard let fetched = await prefetch(scored.song) else { continue }
                return Pick(song: scored.song,
                            reason: HeartbeatRules.reasonText(scored.reason, detail: scored.detail),
                            localURL: fetched.localURL,
                            streamURL: fetched.streamURL)
            }
            guard let source = await resolveSource(scored.song) else { continue }
            return Pick(song: scored.song,
                        reason: HeartbeatRules.reasonText(scored.reason, detail: scored.detail),
                        localURL: nil,
                        streamURL: source.url)
        }
        return nil
    }

    // MARK: 画像

    private func currentProfile() -> HeartbeatProfile {
        let library = LibraryStore.shared
        let downloads = downloadSongs()
        let now = Date()

        let favDates = library.favoriteDates
        let favoritePairs = library.favorites.map { song -> (song: Song, at: Date) in
            (song: song, at: favDates[song.id] ?? now.addingTimeInterval(-30 * 86_400))
        }
        let downloadPairs = downloads.map { song -> (song: Song, at: Date) in
            let at = DownloadManager.shared.items
                .first(where: { $0.song.id == song.id })?.createdAt
                ?? now.addingTimeInterval(-30 * 86_400)
            return (song: song, at: at)
        }
        let searchDates = library.searchDates
        let searchPairs = library.searchHistory.map { keyword -> (keyword: String, at: Date) in
            (keyword: keyword, at: searchDates[keyword] ?? now.addingTimeInterval(-7 * 86_400))
        }

        return HeartbeatRules.buildProfile(downloads: downloadPairs,
                                           favorites: favoritePairs,
                                           searches: searchPairs,
                                           plays: events,
                                           now: now)
    }

    private func downloadSongs() -> [Song] {
        DownloadManager.shared.items
            .filter { $0.status == .completed }
            .map(\.song)
    }

    // MARK: 召回

    /// 新歌通道：种子歌手 + 画像 top 歌手 + 一条搜索关键词，并发搜索后择优。
    private func recall(profile: HeartbeatProfile, exclude: Set<String>) async -> [HeartbeatScored] {
        var queries: [String] = []
        if let seed {
            let singer = HeartbeatRules.primarySinger(seed)
            if !singer.isEmpty { queries.append(singer) }
        }
        queries.append(contentsOf: profile.topArtists)
        if let hint = LibraryStore.shared.searchHistory.first(where: { kw in
            let n = kw.trimmingCharacters(in: .whitespacesAndNewlines).count
            return n >= 2 && n <= 12 && !kw.contains(" ")
        }) {
            queries.append(hint)
        }

        var unique: [String] = []
        for q in queries {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !unique.contains(t) else { continue }
            unique.append(t)
        }
        let picked = Array(unique.prefix(3))
        guard !picked.isEmpty else { return [] }

        var pool: [Song] = []
        // 并发搜（3 个词最坏 3×8s，串行会把"切歌后 2 秒内开始规划"这条时序拖垮）
        await withTaskGroup(of: [Song].self) { group in
            for q in picked {
                group.addTask {
                    let result = await SearchService.shared.searchRanked(keyword: q, limit: 20)
                    return result.songs
                }
            }
            for await songs in group {
                pool.append(contentsOf: songs)
            }
        }
        guard !pool.isEmpty else { return [] }

        // 原版优选（去 Live/翻唱/伴奏）+ 同歌手 ≤2：直接复用发现页的口径
        let originals = DiscoverRules.pick(pool, limit: 40)
        let base = originals.isEmpty ? SearchRanker.dedupe(pool) : originals

        return scoreAll(base, profile: profile, exclude: exclude)
    }

    /// 旧爱通道：收藏 + 下载，优先"很久没听"的；48 小时内听过的不算怀旧。
    private func oldCandidates(profile: HeartbeatProfile, exclude: Set<String>) -> [HeartbeatScored] {
        let library = LibraryStore.shared
        let downloads = downloadSongs()
        let downloadIDs = Set(downloads.map(\.id))
        let favoriteIDs = Set(library.favorites.map(\.id))
        let now = Date()

        var seen = Set<String>()
        var pool: [Song] = []
        for song in library.favorites + downloads {
            guard seen.insert(song.id).inserted else { continue }
            guard !exclude.contains(song.id) else { continue }
            guard HeartbeatRules.isPlayableCandidate(song) else { continue }
            if let last = profile.lastPlayed[song.id],
               now.timeIntervalSince(last) < HeartbeatRules.oldChannelFreshnessHours * 3600 {
                continue
            }
            pool.append(song)
        }
        guard !pool.isEmpty else { return [] }

        var scored: [HeartbeatScored] = []
        for song in pool {
            let base = HeartbeatRules.score(song: song,
                                            profile: profile,
                                            seed: seed,
                                            downloaded: downloadIDs.contains(song.id),
                                            favorited: favoriteIDs.contains(song.id),
                                            priorIndex: 0,
                                            now: now)
            let bonus = HeartbeatRules.stalenessBonus(lastPlayed: profile.lastPlayed[song.id], now: now)
            scored.append(HeartbeatScored(song: base.song,
                                          score: base.score + bonus,
                                          reason: base.reason,
                                          detail: base.detail))
        }
        return scored.sorted { $0.score > $1.score }
    }

    private func scoreAll(_ songs: [Song],
                          profile: HeartbeatProfile,
                          exclude: Set<String>) -> [HeartbeatScored] {
        let downloaded = Set(downloadSongs().map(\.id))
        let favorited = Set(LibraryStore.shared.favorites.map(\.id))
        let recentTags = recentSongs.suffix(5).reduce(into: Set<String>()) { acc, song in
            acc.formUnion(HeartbeatRules.tags(song))
        }

        var out: [HeartbeatScored] = []
        for (idx, song) in songs.enumerated() {
            guard !exclude.contains(song.id) else { continue }
            guard HeartbeatRules.isPlayableCandidate(song) else { continue }
            let base = HeartbeatRules.score(song: song,
                                            profile: profile,
                                            seed: seed,
                                            downloaded: downloaded.contains(song.id),
                                            favorited: favorited.contains(song.id),
                                            priorIndex: idx)
            let factor = HeartbeatRules.penalty(song: song,
                                                sessionKeys: Set(sessionKeys),
                                                seen7d: profile.seen7d,
                                                recentSongs: recentSongs,
                                                recentArtists: artistWindow,
                                                recentTags: recentTags,
                                                dislikedKeys: dislikedKeys,
                                                dislikedArtists: dislikedArtists)
            guard factor > 0 else { continue }
            out.append(HeartbeatScored(song: base.song,
                                       score: base.score * factor,
                                       reason: base.reason,
                                       detail: base.detail))
        }
        return out.sorted { $0.score > $1.score }
    }

    // MARK: 热门兜底（冷启动 / 两个池子都空）

    /// 候选 = 平台官方热歌榜。名次越前越大众，所以直接按名次给分（100 递减）。
    ///
    /// 剔除三类：本轮已经算进来的、本会话听过的、7 天内听过的；以及「不感兴趣」。
    /// 冷启动想要的是"没听过的热门"，不是"把榜单从头再放一遍"。
    private func hotCandidates(profile: HeartbeatProfile,
                               exclude: Set<String>) async -> [HeartbeatScored] {
        let songs = await loadHotPool()
        guard !songs.isEmpty else { return [] }

        let session = Set(recentSongs.map { $0.id })
        let now = Date()
        var out: [HeartbeatScored] = []
        for (idx, song) in songs.enumerated() {
            guard !exclude.contains(song.id), !session.contains(song.id) else { continue }
            guard !dislikedKeys.contains(song.id) else { continue }
            guard HeartbeatRules.isPlayableCandidate(song) else { continue }
            if let last = profile.lastPlayed[song.id],
               now.timeIntervalSince(last) < 7 * 86_400 {
                continue
            }
            out.append(HeartbeatScored(song: song,
                                       score: 100 - Double(idx),
                                       reason: .hot,
                                       detail: "\(idx + 1)"))
        }
        return out
    }

    /// 榜单池：本进程缓存 → 酷我自己的按日缓存（零请求）→ 真拉一次。
    private func loadHotPool() async -> [Song] {
        let today = DiscoverRules.today
        if hotPoolDay == today, !hotPool.isEmpty { return hotPool }

        if let cached = KuwoChart.cachedPageAnyDay(.hot), !cached.songs.isEmpty {
            hotPool = DiscoverRules.pick(Array(cached.songs.prefix(HeartbeatRules.hotSourceSize)),
                                         limit: HeartbeatRules.hotPoolLimit)
            if !hotPool.isEmpty {
                hotPoolDay = today
                return hotPool
            }
        }

        if let page = try? await KuwoChart.fetchPage(.hot), !page.songs.isEmpty {
            hotPool = DiscoverRules.pick(Array(page.songs.prefix(HeartbeatRules.hotSourceSize)),
                                         limit: HeartbeatRules.hotPoolLimit)
            if !hotPool.isEmpty {
                hotPoolDay = today
                return hotPool
            }
        }
        return []
    }

    // MARK: 第三 / 第四级兜底

    /// 放宽的自家资料库：收藏 + 下载 + 最近播放，**允许重播**。
    ///
    /// 只在"个性化 + 热歌榜都出不来"时用。这时"筛掉听过的"已经没有意义——
    /// 宁可重播用户自己喜欢的老歌，也不要让心动模式停在那里。
    /// 仍排除：当前这首（刚放完又放一遍最出戏）、不感兴趣、不可播条目。
    private func libraryCandidates(profile: HeartbeatProfile) -> [HeartbeatScored] {
        let library = LibraryStore.shared
        let downloads = downloadSongs()
        let downloadIDs = Set(downloads.map(\.id))
        let favoriteIDs = Set(library.favorites.map(\.id))
        let currentID = openEvent?.key ?? recentSongs.last?.id

        var seen = Set<String>()
        var songs: [Song] = []
        for song in library.favorites + downloads + library.recentSongs {
            guard seen.insert(song.id).inserted else { continue }
            guard song.id != currentID, !dislikedKeys.contains(song.id) else { continue }
            guard HeartbeatRules.isPlayableCandidate(song) else { continue }
            songs.append(song)
        }
        guard !songs.isEmpty else { return [] }

        // 最久没听的排前面（"好久没听"比"刚放过"更值得重播）
        let ordered = songs.sorted { a, b in
            let la = profile.lastPlayed[a.id] ?? .distantPast
            let lb = profile.lastPlayed[b.id] ?? .distantPast
            return la < lb
        }
        return ordered.enumerated().map { idx, song in
            let reason: HeartbeatReason = downloadIDs.contains(song.id)
                ? .download
                : (favoriteIDs.contains(song.id) ? .favorite : .explore)
            return HeartbeatScored(song: song,
                                   score: 90 - Double(idx) * 0.5,
                                   reason: reason,
                                   detail: HeartbeatRules.primarySinger(song))
        }
    }

    /// 第四级：内置精选池（`DiscoverCatalog.hotSeedWords`）→ 搜真实歌曲。
    ///
    /// 与发现页「热门音乐」的兜底同一条思路：榜单接口挂了、但搜索还能用，就还能出声。
    /// 按当天序号错开两个词，不总是从"晴天 周杰伦"开始。
    private func catalogCandidates() async -> [HeartbeatScored] {
        let words = DiscoverCatalog.hotSeedWords
        guard !words.isEmpty else { return [] }
        let day = DiscoverRules.today
        let queries = (0..<2).map { words[((day + $0) % words.count + words.count) % words.count] }

        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for q in queries {
                group.addTask {
                    let result = await SearchService.shared.searchRanked(keyword: q, limit: 8)
                    return result.songs
                }
            }
            for await songs in group {
                pool.append(contentsOf: songs)
            }
        }
        guard !pool.isEmpty else { return [] }

        let originals = DiscoverRules.pick(pool, limit: 10)
        let base = originals.isEmpty ? SearchRanker.dedupe(pool) : originals
        var out: [HeartbeatScored] = []
        for (idx, song) in base.enumerated() {
            guard !dislikedKeys.contains(song.id) else { continue }
            guard HeartbeatRules.isPlayableCandidate(song) else { continue }
            out.append(HeartbeatScored(song: song,
                                       score: 80 - Double(idx),
                                       reason: .hot,
                                       detail: ""))
        }
        return out
    }

    // MARK: 预取（解析 + 整首落盘）

    /// 320k 而不是无损：预取要在几十秒内落完，而且只用于"切歌那一秒"，
    /// 起播后 `PlayerEngine` 的后台升档仍会把音质抬回无损（与在线起播同一条链）。
    private func prefetch(_ song: Song) async -> Prefetched? {
        guard let source = await resolveSource(song) else { return nil }
        let local = await downloadToCache(urlString: source.url, format: source.format, song: song)
        return Prefetched(localURL: local, streamURL: source.url)
    }

    /// 只解析出可播的流地址（不下载）。「先粗后精」与播放链同口径：快速窗口优先，失败再等完整排名。
    private func resolveSource(_ song: Song) async -> StreamSource? {
        if let quick = await DownloadResolver.quickPick(song: song, want: .high) {
            return quick.source
        }
        let plan = await DownloadResolver.plan(song: song, want: .high, deadline: 8)
        return plan.picked?.source
    }

    private func downloadToCache(urlString: String, format: String, song: Song) async -> URL? {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        do {
            let (tmp, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 50_000, size < 80 * 1_024 * 1_024 else { return nil }
            let dest = cacheDir.appendingPathComponent("\(cachedFilePrefix(for: song)).\(audioExtension(format: format, url: urlString))")
            removeCachedFiles(prefix: cachedFilePrefix(for: song))
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 缓存文件名前缀：同一首歌只留一份（换源/换档时旧文件先删）
    private func cachedFilePrefix(for song: Song) -> String {
        "hb_" + sanitized(song.id)
    }

    private func sanitized(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        for c in raw where allowed.contains(c) { out.append(c) }
        let trimmed = String(out.prefix(48))
        return trimmed.isEmpty ? "song" : trimmed
    }

    /// 取流的容器（flac/mp3/m4a…）——本地文件靠扩展名判类型，不能一律 .mp3
    private func audioExtension(format: String, url: String) -> String {
        let known: Set<String> = ["flac", "mp3", "m4a", "aac", "ogg", "wav"]
        let fmt = format.lowercased()
        if known.contains(fmt) { return fmt }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return known.contains(ext) ? ext : "mp3"
    }

    private func removeCachedFiles(prefix: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix + ".") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 只留"当前 + 待播"的缓存文件（最多 6 个），其余删掉——预取目录不该无限长
    private func prunePrefetch() {
        let keepPrefixes = upcoming.map { cachedFilePrefix(for: $0.song) }
            + [openEvent.map { cachedFilePrefix(for: $0.song) }].compactMap { $0 }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        for file in files {
            let name = file.lastPathComponent
            if keepPrefixes.contains(where: { name.hasPrefix($0 + ".") }) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: 不感兴趣

    func dislike(_ song: Song) {
        dislikedKeys.insert(song.id)
        let singer = HeartbeatRules.primarySinger(song)
        if !singer.isEmpty { dislikedArtists.insert(singer) }
        persistDislikes()
        upcoming.removeAll { $0.song.id == song.id }
        if active { schedulePlan(delay: 0.5) }
    }

    func clearDislikes() {
        dislikedKeys.removeAll()
        dislikedArtists.removeAll()
        persistDislikes()
        if active { schedulePlan(delay: 0.2) }
    }

    func isDisliked(_ song: Song) -> Bool { dislikedKeys.contains(song.id) }

    private func persistDislikes() {
        defaults.set(Array(dislikedKeys), forKey: Self.keyDisliked)
        defaults.set(Array(dislikedArtists), forKey: Self.keyDislikedArtists)
    }

    // MARK: 事件持久化

    private var eventsURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(Self.eventsFile)
    }

    private func loadEvents() {
        guard let data = try? Data(contentsOf: eventsURL),
              let list = try? JSONDecoder().decode([HeartbeatPlayEvent].self, from: data) else {
            return
        }
        events = Array(list.suffix(Self.maxEvents))
    }

    /// 落盘放到后台队列：每切一首都会写一次（最多 600 条 ≈ 180KB），
    /// 放在主线程做 JSON 编码 + 写文件会在切歌那一帧掉帧。
    private func saveEvents() {
        let snapshot = events
        let url = eventsURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
