import Foundation

// MARK: - 酷我歌单（发现页「最新单曲」的数据源）
//
// 端点（2026-11-18 实测：匿名、无签名、无 cookie，https 直连即通）：
//   GET https://wapi.kuwo.cn/api/www/playlist/playListInfo?pid=1082685104&pn=0&rn=100&httpsStatus=1
//
// 实测数字（本机，Referer=https://www.kuwo.cn/ + 移动端 UA）：
//   · 官方歌单 1082685104 =「每日最新单曲推荐」（酷小编），total 653 首；
//   · rn 上限就是 100（给 300 也只回 100），往后要更多得翻 pn（0 起）；
//   · 每条都带 rid / name / artist / album / duration（秒）/ songTimeMinutes /
//     pic（https 封面）/ releaseDate / artistid —— 所以卡片上的"收录于《专辑》"有真数据。
//   · duration 与 songTimeMinutes 在这 100 条里 **100/100 一致**（±3s），不像 `ksong.s`
//     那样把曲长塞在 `song_duration`（见 KuwoChart 文件头坑 ②）；但解析仍保留 mm:ss 兜底。
//
// 为什么不用榜单那套 `kbangserver/ksong.s`：那是"榜"（名次 + 每日换榜），这里是
// "编辑每天往里加新歌"的歌单——有封面、有发行日，正好撑起「最新单曲」的卡片。
//
// ⚠️ 排序：歌单顺序**不是**严格按发行日（实测第 7 首是 10-11、第 12 首是 2025-08-24），
// 而模块叫「最新单曲」，所以 `ordered` 按 releaseDate 倒序重排，同日保持歌单原序。
// 这条是纯函数、有 CI 断言，不要在调用点再排一次。
enum KuwoPlaylist {

    /// 一个歌单的标识。以后「歌单广场」接进来时，这里会长出更多 `Playlist`，
    /// 所以现在就把 pid 收进类型里，而不是散在 URL 拼串里。
    struct Playlist: Hashable {
        let pid: String
        let name: String

        /// 发现页「最新单曲」用的那个官方歌单（653 首，每天加新歌）
        static let newSongs = Playlist(pid: "1082685104", name: "每日最新单曲推荐")
    }

    /// 一条"新歌"：歌曲本体 + 发行日（接口给的 `yyyy-MM-dd`，可能为空）
    struct Release: Identifiable, Codable, Hashable {
        let song: Song
        let releaseDate: String

        var id: String { song.id }

        /// 卡片/列表上的短日期（`2026-11-18` → `11-18`）；没有日期就返回空串，UI 不显示
        var shortDate: String {
            let parts = releaseDate.split(separator: "-")
            guard parts.count == 3 else { return releaseDate }
            return "\(parts[1])-\(parts[2])"
        }

        /// 卡片底行（对齐网易云「艺人新动向」的「收录于《专辑》」）；专辑为空就返回空串，
        /// 不写"收录于《》"这种一眼假的占位。
        var albumLine: String {
            song.album.isEmpty ? "" : "收录于《\(song.album)》"
        }
    }

    /// 发现页模块露几张卡：一屏约 2.5 张，12 张 ≈ 5 屏，够滑但不会把首屏拖长。
    /// 整页（「查看全部」）是接口一页的 100 首。
    static let moduleCards = 12

    // MARK: 歌单广场（第二十轮之后新增：getRcmPlayList）

    /// 广场里的一张歌单（比 `playListInfo` 轻，只有列表页需要的字段）。
    struct Summary: Identifiable, Codable, Hashable {
        let id: String
        let name: String
        let cover: String
        let creator: String
        let songCount: Int
        let playCount: Int
    }

    /// 一页广场歌单：`total` 是接口给的总数（热门 1754 / 最新 9086），用来写"还有多少"。
    struct SquarePage: Codable, Hashable {
        let total: Int
        let items: [Summary]
    }

    /// 歌单详情：歌单元信息 + 按歌单原顺序的歌
    ///
    /// `Codable` 是为了第二批的详情缓存（`Caches/playlist-details/<pid>.json`，2026-11-20 老板定稿）。
    struct Detail: Codable {
        let summary: Summary
        let releases: [Release]
    }

    /// 歌单广场排序：`hot` = 按播放量（1754 张），`new` = 最新上架（9086 张）
    enum Sort: String, CaseIterable, Identifiable {
        case hot
        case new

        var id: String { rawValue }
        var title: String { self == .hot ? "热门" : "最新" }
    }

    /// 一页 100 首（服务端上限）
    static let pageSize = 100

    /// 广场 / 歌手列表一页 30 条（一屏 2 列约 6 张、3 列约 9 位，30 够滚两屏）
    static let squarePageSize = 30

    /// 酷我这一族接口带自家 Referer 最稳（与 `KuwoChart` 同一口径）
    static let headers = ["Referer": "https://www.kuwo.cn/"]

    static var today: Int { DiscoverRules.today }

    // MARK: URL

    static func url(pid: String, page: Int = 0, rn: Int = pageSize) -> String {
        "https://wapi.kuwo.cn/api/www/playlist/playListInfo"
            + "?pid=\(pid)&pn=\(page)&rn=\(rn)&httpsStatus=1"
    }

    /// 歌单广场列表（`pn` 从 1 起，和详情接口的 0 起不一样——实测踩过）
    static func squareURL(sort: Sort, page: Int = 1, rn: Int = squarePageSize) -> String {
        "https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList"
            + "?pn=\(page)&rn=\(rn)&order=\(sort.rawValue)&pay=0&pow=0&kbps=0"
    }

    // MARK: 拉取

    /// 拉一页。失败抛错，由调用方显示失败态 + 重试（不放假数据糊页面）。
    /// 成功时顺手写当天缓存：歌单一天才长几首，冷启动/再进页面直接读缓存。
    static func fetch(_ playlist: Playlist,
                      page: Int = 0,
                      rn: Int = pageSize,
                      day: Int = KuwoPlaylist.today) async throws -> [Release] {
        let json = try await APIClient.shared.getJSON(
            url(pid: playlist.pid, page: page, rn: rn),
            headers: headers,
            timeout: 20
        )
        guard let releases = parse(json) else {
            throw APIError.parse("歌单解析失败（\(playlist.name)）")
        }
        save(releases, for: playlist, day: day)
        return releases
    }

    /// 拉广场一页（热门 / 最新）。成功时**第一页**写当天缓存；第 2 页起只在内存。
    static func fetchSquare(sort: Sort,
                            page: Int = 1,
                            rn: Int = squarePageSize,
                            day: Int = KuwoPlaylist.today) async throws -> SquarePage {
        let json = try await APIClient.shared.getJSON(
            squareURL(sort: sort, page: page, rn: rn),
            headers: headers,
            timeout: 20
        )
        guard let result = parseSquare(json) else {
            throw APIError.parse("歌单广场解析失败（\(sort.title)）")
        }
        if page == 1 { saveSquare(result, sort: sort, day: day) }
        return result
    }

    /// 只有"当前最新一张歌单的 id"——`rn=1` 约 1KB，用来判断当天有没有新歌单上架。
    /// 老板要的是"新上架的立刻能看到"，所以只比 id，不拉整页。
    static func latestNewPlaylistID() async -> String? {
        guard let json = try? await APIClient.shared.getJSON(
            squareURL(sort: .new, page: 1, rn: 1),
            headers: headers, timeout: 12),
            let page = parseSquare(json),
            let first = page.items.first else { return nil }
        return first.id
    }

    /// 拉歌单详情（元信息 + 第一页歌）。歌单自己的顺序不做二次排序。
    /// 这里只管拿；落盘/命中判定在 `cachedDetail` / `saveDetail`（`PlaylistDetailView` 调用）。
    static func fetchDetail(pid: String,
                            page: Int = 0,
                            rn: Int = pageSize) async throws -> Detail {
        detailNetworkCalls += 1
        let json = try await APIClient.shared.getJSON(
            url(pid: pid, page: page, rn: rn),
            headers: headers,
            timeout: 20
        )
        guard let detail = parseDetail(json) else {
            throw APIError.parse("歌单详情解析失败")
        }
        return detail
    }

    // MARK: 解析（纯函数，CI 断言直接喂字典进来）

    /// 解析 `playListInfo` 的响应。`musicList` 空 / 全被丢掉时返回 nil —— 让上层走失败态，
    /// 而不是显示一个 0 首的"正常"页面。
    static func parse(_ json: [String: Any]) -> [Release]? {
        guard let releases = rawReleases(json) else { return nil }
        return ordered(releases)
    }

    /// 按接口原顺序解析（**不排序**）：歌单详情要保留歌单自己的排法，
    /// 只有「最新单曲」才按发行日重排。
    static func rawReleases(_ json: [String: Any]) -> [Release]? {
        if let code = number(json["code"]), code != 200 { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }

        // 有的镜像把列表放在 data.musicList，个别老响应在顶层 musiclist；两种都认
        let list = (data["musicList"] as? [[String: Any]])
            ?? (json["musiclist"] as? [[String: Any]])
            ?? []
        let releases = list.compactMap(release(from:))
        guard !releases.isEmpty else { return nil }
        return releases
    }

    // MARK: 广场 / 详情解析（纯函数，CI 断言直接喂字典进来）

    static func parseSquare(_ json: [String: Any]) -> SquarePage? {
        if let code = number(json["code"]), code != 200 { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }
        let list = data["data"] as? [[String: Any]] ?? []
        let items = list.compactMap(summary(from:))
        guard !items.isEmpty else { return nil }
        return SquarePage(total: number(data["total"]) ?? items.count, items: items)
    }

    static func summary(from item: [String: Any]) -> Summary? {
        guard let id = text(item["id"]), !id.isEmpty else { return nil }
        guard let name = text(item["name"]), !name.isEmpty else { return nil }
        return Summary(
            id: id,
            name: TextClean.text(name),
            cover: https(text(item["img"]) ?? text(item["img1"]) ?? ""),
            creator: TextClean.text(text(item["uname"]) ?? ""),
            songCount: number(item["total"]) ?? 0,
            playCount: number(item["listencnt"]) ?? 0
        )
    }

    static func parseDetail(_ json: [String: Any]) -> Detail? {
        // 详情页要歌单自己的顺序，所以走 rawReleases（不按发行日重排）
        guard let releases = rawReleases(json) else { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }
        let summary = Summary(
            id: text(data["id"]) ?? "",
            name: TextClean.text(text(data["name"]) ?? ""),
            cover: https(text(data["img"]) ?? ""),
            // `uname` 有时是登录名（kw+数字），`userName` 才是显示名
            creator: TextClean.text(text(data["userName"]) ?? text(data["uname"]) ?? ""),
            songCount: number(data["total"]) ?? releases.count,
            playCount: number(data["listencnt"]) ?? 0
        )
        return Detail(summary: summary, releases: releases)
    }

    /// 接口偶尔给 `http://`（封面、歌手头像都有）。ATS 严格，统一升 https。
    static func https(_ url: String) -> String {
        guard url.hasPrefix("http://") else { return url }
        return "https://" + url.dropFirst("http://".count)
    }

    static func release(from item: [String: Any]) -> Release? {
        // rid 是这一条的身份证：没有它就没法播放、也没法按 rid 取封面，直接丢掉
        guard let rid = text(item["rid"]), !rid.isEmpty, rid != "0" else { return nil }
        guard let rawName = text(item["name"]), !rawName.isEmpty else { return nil }

        let pic = text(item["pic"]) ?? text(item["albumpic"]) ?? text(item["pic120"])
        let seconds = number(item["duration"])
        let duration = durationSec(seconds: seconds, minutes: text(item["songTimeMinutes"]))

        let song = Song(
            platform: .kuwo,
            platformID: rid,
            name: TextClean.text(rawName),
            singer: TextClean.text(text(item["artist"]) ?? ""),
            album: TextClean.text(text(item["album"]) ?? ""),
            duration: TimeInterval(duration),
            picURL: pic
        )
        return Release(song: song, releaseDate: text(item["releaseDate"]) ?? "")
    }

    /// 曲长：`songTimeMinutes`（`03:29`）与人读口径一致，`duration`（秒）是机器口径。
    /// 两者都有时只在差得明显（>5s）时才采用 mm:ss —— 既挡住了历史上出现过的
    /// "duration=4" 这种脏值，也不会被 1s 的取整差把正常值改掉。
    static func durationSec(seconds: Int?, minutes: String?) -> Int {
        let bySeconds = max(0, seconds ?? 0)
        let byMinutes = parseMMSS(minutes)
        if bySeconds <= 0 { return byMinutes }
        if byMinutes > 0 && abs(bySeconds - byMinutes) > 5 { return byMinutes }
        return bySeconds
    }

    static func parseMMSS(_ text: String?) -> Int {
        guard let text else { return 0 }
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0]), let s = Int(parts[1]), m >= 0, s >= 0, s < 60 else { return 0 }
        return m * 60 + s
    }

    /// 去重（同一 rid 只留第一次出现）+ 按发行日倒序（没有日期的排最后，同日保持歌单原序）。
    ///
    /// 为什么去重按 `song.id` 而不是歌名：歌单里同名不同版本（Live / 伴奏）是两条合法内容，
    /// 而同一个 rid 重复出现只可能是接口脏数据。
    static func ordered(_ releases: [Release]) -> [Release] {
        var seen = Set<String>()
        let unique = releases.filter { seen.insert($0.song.id).inserted }
        return unique.enumerated().sorted { a, b in
            let da = a.element.releaseDate
            let db = b.element.releaseDate
            if da != db {
                if da.isEmpty { return false }
                if db.isEmpty { return true }
                return da > db          // yyyy-MM-dd 字符串直接比就是日期序
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: 缓存（UserDefaults，JSON）

    private static func cacheKey(_ playlist: Playlist) -> String {
        "kw_playlist_cache_v1_\(playlist.pid)"
    }

    private struct CachedReleases: Codable {
        let day: Int
        let releases: [Release]
    }

    /// 缓存里的整页（不问日期）——调用方先拿它铺满界面，再决定要不要按天重取
    static func cachedAnyDay(_ playlist: Playlist) -> [Release]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(playlist)),
              let cached = try? JSONDecoder().decode(CachedReleases.self, from: data),
              !cached.releases.isEmpty else { return nil }
        return cached.releases
    }

    /// 只有"缓存里的本地日就是今天"才算命中（老板：加载一次当天不再加载，除非第二天）
    static func cached(_ playlist: Playlist, day: Int = KuwoPlaylist.today) -> [Release]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(playlist)),
              let cached = try? JSONDecoder().decode(CachedReleases.self, from: data),
              cached.day == day,
              !cached.releases.isEmpty else { return nil }
        return cached.releases
    }

    static func save(_ releases: [Release], for playlist: Playlist, day: Int = KuwoPlaylist.today) {
        let cached = CachedReleases(day: day, releases: releases)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(playlist))
    }

    // MARK: 广场缓存（UserDefaults，JSON）

    private static func squareCacheKey(_ sort: Sort) -> String {
        "kw_square_v1_\(sort.rawValue)"
    }

    private struct CachedSquare: Codable {
        let day: Int
        let page: SquarePage
    }

    /// 当天缓存（热门 / 最新各一份，只存第一页）
    static func cachedSquare(_ sort: Sort, day: Int = KuwoPlaylist.today) -> SquarePage? {
        guard let data = UserDefaults.standard.data(forKey: squareCacheKey(sort)),
              let cached = try? JSONDecoder().decode(CachedSquare.self, from: data),
              cached.day == day, !cached.page.items.isEmpty else { return nil }
        return cached.page
    }

    /// 不问日期（跨天冷启动先铺旧内容，再核对要不要换）
    static func cachedSquareAnyDay(_ sort: Sort) -> SquarePage? {
        guard let data = UserDefaults.standard.data(forKey: squareCacheKey(sort)),
              let cached = try? JSONDecoder().decode(CachedSquare.self, from: data),
              !cached.page.items.isEmpty else { return nil }
        return cached.page
    }

    static func saveSquare(_ page: SquarePage, sort: Sort, day: Int = KuwoPlaylist.today) {
        let cached = CachedSquare(day: day, page: page)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: squareCacheKey(sort))
    }

    // MARK: "有没有新歌单"的探测锚点

    private static let newestIDKey = "kw_square_newest_id_v1"

    static func storedNewestID() -> String? {
        UserDefaults.standard.string(forKey: newestIDKey)
    }

    static func storeNewestID(_ id: String) {
        UserDefaults.standard.set(id, forKey: newestIDKey)
    }

    // MARK: 广场歌单详情缓存（Caches/playlist-details/<pid>.json，TTL 24h）
    //
    // 老板 2026-11-20 定稿（第二批）：广场歌单详情**加载一次就不再加载**——
    //   读取顺序 内存 → 磁盘 → 网络；TTL 24h；**回前台不自动刷新**；只有下拉刷新才手动更新。
    //
    // 为什么不用 UserDefaults（广场列表用的是它）：详情是一页 100 首 ≈ 20~40KB，
    // 几十个歌单就是 MB 级，塞 UserDefaults 会拖慢启动；`Caches` 目录系统空间紧张时还能自己清。
    // 内存层是**进程级**的：底部 Tab 保活，同一个歌单反复进出不该再解码一次 JSON。

    /// 详情缓存有效期：24 小时（老板口径）
    static let detailTTL: TimeInterval = 24 * 3600

    /// 详情接口**真正发出去**的请求数（诊断用）。
    /// 验收口径就靠它：缓存命中时这个数不涨 → "退出后台再进来 0 请求"是可直接看到的证据。
    static private(set) var detailNetworkCalls = 0

    /// 进程内缓存（跨页面实例保留；App 被杀就没了，那时正好读磁盘）
    private final class DetailMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (detail: Detail, savedAt: Date)] = [:]

        func get(_ pid: String) -> (Detail, Date)? {
            lock.lock()
            defer { lock.unlock() }
            guard let hit = map[pid] else { return nil }
            return (hit.detail, hit.savedAt)
        }

        func set(_ pid: String, _ detail: Detail, _ savedAt: Date) {
            lock.lock()
            defer { lock.unlock() }
            map[pid] = (detail, savedAt)
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            map.removeAll()
        }
    }

    private static let detailMemo = DetailMemo()

    private struct CachedDetailFile: Codable {
        let savedAt: Date
        let detail: Detail
    }

    private static var detailDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("playlist-details", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 文件名用 pid 的十六进制：歌单号里有 gcid_xxx 这种形态，别让路径分隔符之类的东西进来
    private static func detailFileURL(_ pid: String) -> URL? {
        let safe = pid.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
        return detailDirectory?.appendingPathComponent("\(safe).json")
    }

    /// 详情：内存 → 磁盘 → nil（TTL 内才算命中；过期返回 nil 让上层去联网）
    static func cachedDetail(pid: String, maxAge: TimeInterval = detailTTL) -> Detail? {
        if let hit = detailMemo.get(pid), Date().timeIntervalSince(hit.1) <= maxAge {
            return hit.0
        }
        guard let file = detailFileURL(pid),
              let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(CachedDetailFile.self, from: data),
              Date().timeIntervalSince(cached.savedAt) <= maxAge,
              !cached.detail.releases.isEmpty else { return nil }
        detailMemo.set(pid, cached.detail, cached.savedAt)
        return cached.detail
    }

    /// 缓存里的保存时间（界面上写「x 分钟前更新」）
    static func detailSavedAt(pid: String) -> Date? {
        if let hit = detailMemo.get(pid) { return hit.1 }
        guard let file = detailFileURL(pid),
              let data = try? Data(contentsOf: file),
              let cached = try? JSONDecoder().decode(CachedDetailFile.self, from: data) else { return nil }
        return cached.savedAt
    }

    /// 写缓存（内存 + 磁盘）
    static func saveDetail(_ detail: Detail, pid: String, at date: Date = Date()) {
        detailMemo.set(pid, detail, date)
        guard let file = detailFileURL(pid),
              let data = try? JSONEncoder().encode(CachedDetailFile(savedAt: date, detail: detail)) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// 清空详情缓存（设置页「清空数据」/ 诊断用）
    static func clearDetailCache() {
        detailMemo.removeAll()
        guard let dir = detailDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: 字段取值（接口里同一字段常常有时是字符串有时是数字）

    private static func text(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(trimmed) { return n }
            if let d = Double(trimmed) { return Int(d) }
        }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
