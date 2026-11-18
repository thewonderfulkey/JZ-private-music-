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

    /// 一页 100 首（服务端上限）
    static let pageSize = 100

    /// 酷我这一族接口带自家 Referer 最稳（与 `KuwoChart` 同一口径）
    static let headers = ["Referer": "https://www.kuwo.cn/"]

    static var today: Int { DiscoverRules.today }

    // MARK: URL

    static func url(pid: String, page: Int = 0, rn: Int = pageSize) -> String {
        "https://wapi.kuwo.cn/api/www/playlist/playListInfo"
            + "?pid=\(pid)&pn=\(page)&rn=\(rn)&httpsStatus=1"
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

    // MARK: 解析（纯函数，CI 断言直接喂字典进来）

    /// 解析 `playListInfo` 的响应。`musicList` 空 / 全被丢掉时返回 nil —— 让上层走失败态，
    /// 而不是显示一个 0 首的"正常"页面。
    static func parse(_ json: [String: Any]) -> [Release]? {
        if let code = number(json["code"]), code != 200 { return nil }
        guard let data = json["data"] as? [String: Any] else { return nil }

        // 有的镜像把列表放在 data.musicList，个别老响应在顶层 musiclist；两种都认
        let list = (data["musicList"] as? [[String: Any]])
            ?? (json["musiclist"] as? [[String: Any]])
            ?? []
        let releases = list.compactMap(release(from:))
        guard !releases.isEmpty else { return nil }
        return ordered(releases)
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
